# nixos-azimage-builder

[![Weekly Forge](https://github.com/poomnupong/nixos-azimage-builder/actions/workflows/weekly_forge.yml/badge.svg)](https://github.com/poomnupong/nixos-azimage-builder/actions/workflows/weekly_forge.yml)
[![Azure Smoke Test](https://github.com/poomnupong/nixos-azimage-builder/actions/workflows/azure-smoke-test.yml/badge.svg)](https://github.com/poomnupong/nixos-azimage-builder/actions/workflows/azure-smoke-test.yml)

> **Non-Profit / Reference Use.**  
> This repository is provided as a reference implementation for building
> customised NixOS VHD images for Microsoft Azure.  It is intended for
> educational, non-commercial, and personal use.  You are free to fork it and
> adapt it to your own needs under the terms of the [MIT License](LICENSE).

---

## What this does

The **Weekly Forge** pipeline uses [Nix Flakes](https://nixos.wiki/wiki/Flakes)
and [nixos-generators](https://github.com/nix-community/nixos-generators) to
build a ready-to-deploy NixOS `.vhd` image every Saturday at 00:00 US Central
Standard Time (06:00 UTC).  The resulting image is uploaded as a GitHub Release
tagged with the version string (`nixos-<channel>-YYYYMMDD-HHMM`, e.g.
`nixos-25.11-20260429-0600`).

```
nixos-azimage-builder/
├── flake.nix                        # Nix Flake entry-point — defines the azureImage output
├── core_pulse.nix                   # ← YOUR customisation module (packages, users, SSH keys)
├── get_version.sh                   # Generates the nixos-<channel>-YYYYMMDD-HHMM version / release tag
├── scripts/
│   ├── bootstrap-azure-ci.sh        # One-time Azure + GitHub OIDC bootstrap (run locally)
│   └── azure/
│       └── empty-rg.json            # Empty ARM template used to empty a run RG
├── docs/
│   └── ci-azure.md                  # Azure CI architecture & operations guide
├── .github/
│   └── workflows/
│       ├── weekly_forge.yml         # Weekly VHD build + GitHub Release
│       ├── azure-smoke-test.yml     # Deploys the VHD to Azure and tears the RG down
│       └── azure-janitor.yml        # Daily cleanup safety net for stuck run RGs
├── LICENSE                          # MIT
└── README.md                        # This file
```

---

## How to customise the image

1. **Fork** this repository.
2. **Edit `core_pulse.nix`** — this is the only file you normally need to
   touch:

   ```nix
   # core_pulse.nix
   { pkgs, ... }:
   {
     environment.systemPackages = with pkgs; [
       git curl wget htop vim
       # Add your tools here ↓
       tmux python3 awscli2
     ];

     # Your own user — add your SSH key so you can log in directly.
     users.users.alice = {
       isNormalUser = true;
       extraGroups = [ "wheel" ];
       openssh.authorizedKeys.keys = [
         "ssh-ed25519 AAAA... alice@myhost"
       ];
     };

     # Azure provisioning user — must exist so the Azure provisioning
     # agent (waagent/cloud-init) only writes the SSH key.  Do NOT set
     # openssh.authorizedKeys.keys here; the key is injected at
     # deployment time by az vm create.
     users.users.azureuser = {
       isNormalUser = true;
       extraGroups = [ "wheel" ];
     };
   }
   ```

3. **Push to `main`**.  The workflow will pick it up, build a fresh image, and
   publish a GitHub Release automatically.

---

## Building locally

You need [Nix](https://nixos.org/download) with flakes enabled.

```bash
# Build the Azure VHD
nix build .#azureImage

# The image will be available at ./result/
ls result/
```

---

## Deploying to Azure

The published asset is a **fixed-format VHD** (gzip-compressed in the
GitHub Release). The recommended path — the same one the weekly smoke
test exercises end-to-end — uses a **direct-upload managed disk** so no
customer-owned Storage Account is on the data path:

1. Download the `.vhd.gz` from the GitHub Release and `gunzip` it.
2. Provision an empty managed disk in the target resource group with
   `az disk create --upload-type Upload --upload-size-bytes <stat -c %s>`,
   request a short-lived write SAS via `az disk grant-access`, stream
   the VHD into it with `azcopy copy ... --blob-type PageBlob`, then
   seal the disk with `az disk revoke-access`.
3. Stamp `diskControllerTypes` on the sealed disk via the ARM REST API
   (the Azure CLI has no flag for this — verified on `azure-cli` 2.85.0):

   ```bash
   az rest --method PATCH \
     --url "${DISK_ID}?api-version=2024-03-02" \
     --body '{"properties":{"supportedCapabilities":{"diskControllerTypes":"SCSI, NVMe"}}}'
   ```

4. Create a **Managed Image** from the sealed disk with
   `az image create --source <disk-id>`.
5. Launch a VM from that image.

This avoids tenant policies that forbid `publicNetworkAccess=Enabled`
on Storage Accounts — there is no Storage Account involved.

If you prefer (or your tooling requires) the classic flow, you can
still upload the `.vhd` to an **Azure Storage Account** as a fixed-VHD
**page blob** and point `az image create --source` at the blob URI;
both paths produce equivalent Managed Images.

### User provisioning (NixOS vs traditional Linux)

On a traditional distribution like Ubuntu, `az vm create --admin-username`
tells the Azure provisioning agent (cloud-init on most marketplace images,
with waagent handling low-level Azure integration) to create the admin user
imperatively at first boot using `useradd`.  On NixOS this is **unreliable**
— the agent's imperative `useradd` can fail silently on NixOS's non-standard
filesystem layout (e.g. `/etc/passwd` is a symlink into `/etc/static`),
leaving the account partially created and SSH unusable.

The NixOS-idiomatic fix is to **declare the admin user in `core_pulse.nix`**
so it exists in `/etc/passwd` and has a proper home directory before the VM
ever boots:

```nix
users.users.azureuser = {
  isNormalUser = true;
  description  = "Azure admin user";
  extraGroups  = [ "wheel" ];
  # Do NOT set openssh.authorizedKeys.keys here.
};
```

| What | Where it comes from | Managed by |
|------|---------------------|------------|
| User account (`azureuser`) | `core_pulse.nix` | NixOS (declarative, baked into the VHD) |
| SSH public key | `az vm create --ssh-key-values` | Azure provisioning agent (writes `~/.ssh/authorized_keys` at first boot) |
| Password | Not applicable | `PasswordAuthentication = false` in sshd config |

`openssh.authorizedKeys.keys` is **intentionally omitted** from the Nix
declaration.  If you set it, NixOS writes the key to
`/etc/ssh/authorized_keys.d/azureuser` — that file is managed by Nix and
would be overwritten on every `nixos-rebuild`, conflicting with the
deployment-time key Azure injects.  By leaving it unset, the only
authorised key is the one the Azure provisioning agent writes to
`~azureuser/.ssh/authorized_keys`, which sshd reads via the default
`AuthorizedKeysFile` path.

> **This is not a hack — it is cleaner than the Ubuntu model.**  
> The user's *existence* is version-controlled and reproducible; the
> *credential* is injected at deployment time through the standard Azure
> provisioning path.  On Ubuntu the user's existence is invisible,
> depending entirely on cloud-init's runtime behaviour.

The default `core_pulse.nix` also disables password authentication; make
sure you have added your SSH public key before deploying.

### Disk controller compatibility (SCSI vs NVMe)

Azure VM families differ in which remote-disk controller they boot with:
older series (e.g. Dasv5, Easv5) are **SCSI-only**; v6 series
(e.g. `Standard_E8-2as_v6`, `Standard_D2as_v6`) support **both SCSI and
NVMe** (defaulting to NVMe but allowing SCSI when the OS image declares
it); and v7 series (e.g. `Standard_D16ads_v7`) are **NVMe-only** and
require the source disk to declare NVMe support via
`supportedCapabilities.diskControllerTypes`.

The shipped initrd loads both NVMe (`nvme`, `nvme_core`) and Hyper-V
SCSI (`hv_storvsc`, `hv_vmbus`, `hv_netvsc`) drivers, so stage-1 finds
the root filesystem regardless of which controller Azure exposes.

To use v7 NVMe-only SKUs, stamp `diskControllerTypes` on the managed
disk via the ARM REST API after `az disk revoke-access` (the Azure CLI
has no flag for this — verified on `azure-cli` 2.85.0):

```bash
az rest --method PATCH \
  --url "${DISK_ID}?api-version=2024-03-02" \
  --body '{"properties":{"supportedCapabilities":{"diskControllerTypes":"SCSI, NVMe"}}}'
```

Then create the image and VM as usual:

```bash
az image create -g "$RG" -n "$IMG" \
  --os-type Linux \
  --hyper-v-generation V2 \
  --source "$SOURCE"
```

* v5 SKUs: `az vm create --disk-controller-type SCSI`
* v6 SKUs: `az vm create --disk-controller-type SCSI` or `--disk-controller-type NVMe`
  (after the PATCH above)
* v7 NVMe-only SKUs: `az vm create --disk-controller-type NVMe`
  (after the PATCH above; validated by the smoke test)

`$SOURCE` is whatever `az image create --source` accepts for your
flow: a **managed disk resource ID** (the recommended path used by the
smoke-test workflow and the *Deploying to Azure* steps above, after
direct-upload via `az disk create --upload-type Upload`) or a **VHD page-blob
URI** (`https://<account>.blob.core.windows.net/<container>/<name>.vhd`)
if you chose the alternative storage-account flow.

---

## Azure CI setup (one-time bootstrap)

The weekly build always runs in GitHub Actions, but the **smoke-test** and
**janitor** workflows need to talk to Azure. To keep client secrets out of the
repo, authentication is done via **GitHub OIDC federation** to a Microsoft
Entra ID (formerly Azure AD) service principal. The `scripts/bootstrap-azure-ci.sh` helper provisions
everything in Azure and prints the values you need to paste into GitHub.

> Run this **once, locally**, as a user with **Owner** on the target
> subscription. Do not run it from CI — CI's own service principal must not be
> able to grant itself new permissions.

### Prerequisites

* An Azure subscription you own (or have `Owner` on).
* [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed
  and logged in: `az login`.
* Your GitHub repository (fork) already pushed to `github.com`.
* `bash` (the script is POSIX-ish `bash`, tested on Linux and macOS).

### Preparing the parameters

Gather these values before running the script — they are what wire up the
OIDC trust between GitHub and Azure:

| Flag | What it is | How to get it |
|------|------------|---------------|
| `--subscription` | The Azure subscription ID the RGs will live in. | `az account show --query id -o tsv` |
| `--location` | Azure region for the resource groups (e.g. `southeastasia`, `eastus`). | Pick any region close to you; it only affects the RG metadata and where the smoke-test VM will run. |
| `--github-repo` | Your GitHub repo in `owner/name` form. **Must match exactly** — it becomes the `sub` claim the OIDC token is validated against. | e.g. `poomnupong/nixos-azimage-builder` (or `yourname/your-fork`). |
| `--budget-email` | Email address for the Layer-4 budget alert (80% of monthly spend). | Any mailbox you check. |
| `--run-rg-count` *(optional)* | How many run resource groups to create (default `2`). | Two is enough; increase only if smoke tests overlap. |
| `--control-rg` *(optional)* | Name of the shared control RG (default `rg-nixos-ci-control`). | |
| `--run-rg-prefix` *(optional)* | Prefix for the run RG names (default `rg-nixos-ci-run`, yielding `rg-nixos-ci-run-01`, `-02`, …). | |
| `--sp-name` *(optional)* | Display name of the service principal (default `sp-nixos-azimage-builder-ci`). | |
| `--budget-amount` *(optional)* | Monthly budget in USD (default `10`). | |

The script is **idempotent** — re-running it reconciles state instead of
creating duplicates.

### Running the bootstrap

```bash
./scripts/bootstrap-azure-ci.sh \
  --subscription <sub-id> \
  --location southeastasia \
  --github-repo <your-gh-user>/nixos-azimage-builder \
  --budget-email you@example.com
```

What it does:

1. Creates the control RG and `N` run RGs.
2. Creates a Microsoft Entra ID application + service principal with **federated
   credentials** trusting tokens from GitHub Actions for:
   * `ref:refs/heads/main` (weekly build + smoke test on production)
   * `ref:refs/heads/copilot/smoke-dev` (long-lived dev branch used by
     the Copilot agent to iterate on the smoke test against Azure
     end-to-end — same RBAC and RG pool as `main`, treat as privileged)
   * `environment:azure-janitor` (daily janitor)
3. Grants the SP `Contributor` on each run RG and `Reader` on the control RG.
   Contributor on the run RG is sufficient for the smoke test's per-run
   managed-disk staging (`az disk create --upload-type Upload` + `az disk
   grant-access`); no shared storage account or extra data-plane RBAC
   is needed.
4. Creates a monthly subscription budget with an email notification (Layer 4
   backstop).
5. Prints the GitHub Secrets / Variables you need to configure.

### Wiring the output into GitHub

After the script finishes, configure these under **Settings → Secrets and
variables → Actions** in your repo:

**Secrets**

* `AZURE_CLIENT_ID` — the app registration's `appId` (printed by the script).
* `AZURE_TENANT_ID` — your Microsoft Entra ID tenant ID (printed by the script).
* `AZURE_SUBSCRIPTION_ID` — the subscription ID you passed in.

**Variables**

* `AZURE_LOCATION` — e.g. `southeastasia`.
* `AZURE_CONTROL_RG` — e.g. `rg-nixos-ci-control`.
* `AZURE_RUN_RGS` — space-separated list, e.g. `rg-nixos-ci-run-01 rg-nixos-ci-run-02`.

**Environment**

Create an Actions environment named **`azure-janitor`** (Settings →
Environments → New environment). Its name appears in the federated credential
subject the janitor workflow uses to obtain an OIDC token, so the name must
match exactly.

For deeper architectural details (why RBAC survives run-RG teardown, the four
cleanup layers, what to do when an RG is stuck) see
[`docs/ci-azure.md`](docs/ci-azure.md).

---

## Version format

Releases are tagged `nixos-<channel>-YYYYMMDD-HHMM` (UTC), e.g.
`nixos-25.11-20260429-0600`.  The NixOS base version (`<channel>`) is
extracted from the `nixpkgs` input URL in `flake.nix` so that anyone
looking at a release tag immediately knows which NixOS channel the image
was built from.  The tag is generated by `get_version.sh`:

```bash
./get_version.sh   # → nixos-25.11-20260429-0426
```

---

## License

[MIT](LICENSE) © 2026 Poom Nupong
