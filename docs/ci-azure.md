# Azure CI — architecture and operations

This document describes the Azure side of the **nixos-azimage-builder** CI:
the resource-group layout, why RBAC survives between runs, how teardown
failures are handled, and the one-time setup.

## Resource-group layout

We use **one control RG + a small pool of dedicated run RGs**:

```
subscription
├── rg-nixos-ci-control       ← perpetual; budget action group, etc.
├── rg-nixos-ci-run-01        ← perpetual *container*; emptied after each run
└── rg-nixos-ci-run-02        ← perpetual *container*; emptied after each run
```

The run RGs are **never deleted**. Each CI run picks one from the pool,
uses it, and then empties it. See "Why RBAC survives" below.

The smoke test stages each release VHD as a per-run **direct-upload
managed disk** in the selected run RG (sealed and reaped within the
same job), so no shared customer-owned storage account is required.

Using a small pool (not a single RG) means a slow teardown on one run
does not block the next run — the smoke-test workflow will pick a
different slot.

## Why RBAC survives between runs

Azure role assignments are child resources of the scope they target.
A `Contributor` role assignment on
`/subscriptions/<sub>/resourceGroups/rg-nixos-ci-run-01` lives *inside*
that RG's ARM scope.

* `az group delete rg-nixos-ci-run-01` deletes the RG **and every role
  assignment scoped to it**. Recreating the RG by the same name gives
  you an empty RG with no RBAC — the SP loses access.
* Emptying the RG (deleting its *contents* but leaving the RG itself)
  leaves the role assignments intact because their scope still exists.

So the CI workflow empties the RG with a **complete-mode ARM
deployment of an empty template** (`scripts/azure/empty-rg.json`).
ARM reads the template, sees "desired state = no resources", and
deletes everything currently in the RG — in the correct dependency
order (disks before the VM that references them, NICs before the VNet,
etc.). We don't have to order anything by hand.

## Four layers of cleanup safety

Teardown fails in roughly 20% of runs due to transient ARM errors,
dependency-ordering races, soft-delete protections, stray locks, etc.
The design handles that with four independent layers:

| Layer | Where | Catches |
|-------|-------|---------|
| 1. In-workflow retry | `azure-smoke-test.yml` | Transient ARM errors, throttling, brief ordering races. Up to 3 attempts, 60s backoff. |
| 2. Post-teardown verification | `azure-smoke-test.yml` | Anything still present after layer 1. Fails the job → GitHub notifies you by email. |
| 3. Daily janitor | `azure-janitor.yml` | Everything layer 2 missed, or cases where the smoke-test workflow itself didn't run. Re-attempts teardown on every run RG in the pool; opens/updates a GitHub issue labelled `azure-cleanup` when an RG stays stuck. |
| 4. Azure budget alert | Subscription, created by bootstrap | The ultimate backstop. If all three workflow layers fail silently (revoked token, disabled workflow, etc.), a forgotten VM will trip the budget within days and email you. |

Layer 3 runs on a different schedule than layer 1, so a scheduler
outage on Saturday doesn't prevent detection on Sunday.

## One-time setup

Run the bootstrap script **locally, once**, as a subscription Owner:

```bash
./scripts/bootstrap-azure-ci.sh \
  --subscription <sub-id> \
  --location southeastasia \
  --github-repo poomnupong/nixos-azimage-builder \
  --budget-email you@example.com
```

The script:

1. Creates the control RG and `N` run RGs (default 2).
2. Creates a service principal with **federated credentials** for
   GitHub OIDC — no client secrets ever land in the repo.
3. Grants the SP `Contributor` on each run RG and `Reader` on the
   control RG. Contributor on the run RG is sufficient for the smoke
   test's per-run managed-disk staging (`az disk create --upload-type Upload`
   + `az disk grant-access`); no shared storage account or extra
   data-plane RBAC is needed.
4. Creates a monthly subscription budget with an email action group
   (Layer 4).
5. Prints the GitHub secrets and variables you need to set.

### Required GitHub configuration

**Secrets** (Settings → Secrets and variables → Actions → Secrets):

* `AZURE_CLIENT_ID`
* `AZURE_TENANT_ID`
* `AZURE_SUBSCRIPTION_ID`

**Variables** (same page, Variables tab):

* `AZURE_LOCATION` — e.g. `southeastasia`
* `AZURE_CONTROL_RG` — e.g. `rg-nixos-ci-control`
* `AZURE_RUN_RGS` — space-separated list, e.g.
  `rg-nixos-ci-run-01 rg-nixos-ci-run-02`

**Environment**: create a GitHub Actions environment called
`azure-janitor`. Its subject is referenced by the SP's federated
credential, so the janitor workflow can obtain an OIDC token.

## Privileged refs

The bootstrap script registers federated credentials trusting GitHub
OIDC tokens issued for these subjects only:

| Subject | Used by | Notes |
|---------|---------|-------|
| `ref:refs/heads/main` | `azure-smoke-test.yml` (production) | Standard release validation. |
| `ref:refs/heads/copilot/smoke-dev` | `azure-smoke-test.yml` (agent iteration) | Long-lived dev branch. Lets the Copilot agent dispatch the smoke test against Azure end-to-end without merging unverified changes to `main`. Same RG pool, same RBAC, same blast radius as `main`. |
| `environment:azure-janitor` | `azure-janitor.yml` | Daily cleanup. |

Treat `copilot/smoke-dev` as a privileged ref (same protection
posture as `main`): pushes to it can talk to Azure with full
Contributor access on the run RGs. The smoke-test workflow
explicitly refuses to run from any other ref, so adding more
privileged branches requires both a new federated credential **and**
a workflow change.

The `azure-smoke-test.yml` workflow is the only one that uses the
`copilot/smoke-dev` federation; `weekly_forge.yml` does not touch
Azure, and the janitor authenticates via the `azure-janitor`
environment.

## What happens when an RG is stuck

1. The smoke-test workflow goes red — you get a notification from
   GitHub.
2. The next janitor run (within 24h) re-attempts teardown. If it
   also fails, it opens or updates an issue labelled `azure-cleanup`
   listing the stuck resources.
3. Investigate the resources listed in the issue (locks? leases?
   backup items with soft-delete?). Fix the underlying cause and
   close the issue. The janitor will re-open on the next failure.

## Smoke-test flow

The weekly smoke test exercises the full release pipeline end-to-end:

1. **Resolve latest release.** `gh release list/view` finds the most
   recent tag and the matching `nixos-azimage-<tag>.vhd.gz` asset.
2. **Stage VHD as a managed disk.** Download + decompress on the
   runner, then provision an empty managed disk in the selected run
   RG:

   ```sh
   az disk create -g "$RG" -n "$DISK_NAME" \
     --location "$LOCATION" \
     --upload-type Upload --upload-size-bytes "$(stat -c %s "$VHD")" \
     --hyper-v-generation V2 --os-type Linux
   ```

   ARM hands out a short-lived write SAS via `az disk grant-access`;
   AzCopy streams the VHD into it as a page blob; `az disk
   revoke-access` seals the disk. No customer-owned storage account
   is on the data path, so tenant policies that forbid
   `publicNetworkAccess=Enabled` on storage accounts are satisfied
   without networking exceptions. After sealing, an `az rest` PATCH
   stamps `supportedCapabilities.diskControllerTypes: "SCSI, NVMe"`
   on the disk via the ARM REST API (the Azure CLI has no flag for
   this — verified on `azure-cli` 2.85.0):

   ```sh
   az rest --method PATCH \
     --url "${disk_id}?api-version=2024-03-02" \
     --body '{"properties":{"supportedCapabilities":{"diskControllerTypes":"SCSI, NVMe"}}}'
   ```

3. **Create Compute Gallery image.** A per-run Azure Compute Gallery,
   image definition (with `DiskControllerTypes=SCSI` declared), and
   image version are created from the staged managed disk.
4. **Boot VM.** A `Standard_D4ads_v5` VM is created from the gallery
   image with `--disk-controller-type SCSI`, `--admin-username azureuser`,
   and an ephemeral ed25519 SSH key generated on the runner. Inbound SSH
   is restricted by NSG to the runner's egress IP only.

   The `azureuser` account is **pre-declared in `core_pulse.nix`** so it
   exists in the VHD at boot. The Azure provisioning agent (waagent/cloud-init)
   only needs to write the SSH public key to
   `~azureuser/.ssh/authorized_keys` — it does not need to create the user
   (which is unreliable on NixOS; see the README's "User provisioning"
   section for details). The SSH step makes up to 6 attempts with
   `ConnectTimeout=15`, sleeping 15 s between attempts, to allow the
   provisioning agent to finish writing the key after sshd is already
   listening.

5. **Assert.** SSH in as `azureuser`, run `cat /etc/os-release` and
   `nixos-version`, and require `ID=nixos` plus a non-empty version
   string.
6. **Teardown.** Existing complete-mode empty-template deployment
   wipes every resource (VM, disk, NIC, NSG, public IP, VNet,
   image, *and the per-run staging disk*) but leaves the run RG and
   its role assignments intact.

Cost per run: well under $0.10 — the VM lives <15 minutes and the
staging managed disk is deleted by teardown in the same job.
