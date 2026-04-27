# nixos-azimage-builder

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
tagged with the build timestamp (`YYYYMMDD-HHMM`).

```
nixos-azimage-builder/
├── flake.nix                        # Nix Flake entry-point — defines the azureImage output
├── core_pulse.nix                   # ← YOUR customisation module (packages, users, SSH keys)
├── get_version.sh                   # Generates the YYYYMMDD-HHMM version / release tag
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

     users.users.alice = {
       isNormalUser = true;
       extraGroups = [ "wheel" ];
       openssh.authorizedKeys.keys = [
         "ssh-ed25519 AAAA... alice@myhost"
       ];
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
   `az disk create --for-upload --upload-size-bytes <stat -c %s>`,
   request a short-lived write SAS via `az disk grant-access`, stream
   the VHD into it with `azcopy copy ... --blob-type PageBlob`, then
   seal the disk with `az disk revoke-access`.
3. Create a **Managed Image** from the sealed disk with
   `az image create --source <disk-id>`.
4. Launch a VM from that image.

This avoids tenant policies that forbid `publicNetworkAccess=Enabled`
on Storage Accounts — there is no Storage Account involved.

If you prefer (or your tooling requires) the classic flow, you can
still upload the `.vhd` to an **Azure Storage Account** as a fixed-VHD
**page blob** and point `az image create --source` at the blob URI;
both paths produce equivalent Managed Images.

The default `core_pulse.nix` disables password authentication; make sure you
have added your SSH public key before building.

### Disk controller compatibility (SCSI vs NVMe)

Azure VM families differ in which remote-disk controller they boot with:
older series (e.g. Dasv5, Easv5) are **SCSI-only**; v6 series
(e.g. `Standard_E8-2as_v6`, `Standard_D2as_v6`) support **both SCSI and
NVMe** (defaulting to NVMe but allowing SCSI when the OS image declares
it); and v7 series (e.g. `Standard_E8-2as_v7`) are **NVMe-only** and
will refuse to boot a managed image whose source disk does not declare
NVMe support with `InvalidParameter: storageProfile.diskControllerType`.

The image we publish supports **both SCSI and NVMe**:

* `core_pulse.nix` adds the NVMe (`nvme`, `nvme_core`) and Hyper-V
  SCSI (`hv_storvsc`, `hv_vmbus`, `hv_netvsc`) drivers to
  `boot.initrd.availableKernelModules`, so stage-1 finds the root
  filesystem regardless of which controller Azure exposes.
* The smoke-test workflow stages the VHD with
  `az disk create --for-upload --supported-disk-controller-types SCSI
  NVMe`, and the managed image inherits
  `supportedCapabilities.diskControllerTypes` from that source disk.
  (`az image create` itself does not expose this flag.)

`az vm create` still has to pick **one** controller per VM via
`--disk-controller-type`. The smoke test pins `SCSI` on a v6 SKU today
because that is the path validated end-to-end; v7 SKUs work with
`--disk-controller-type NVMe`.

```bash
az image create -g "$RG" -n "$IMG" \
  --os-type Linux \
  --hyper-v-generation V2 \
  --source "$SOURCE"
```

`$SOURCE` is whatever `az image create --source` accepts for your flow:
a **managed disk resource ID** (the recommended path used by the
smoke-test workflow and the *Deploying to Azure* steps above, after
direct-upload via `az disk create --for-upload`) or a **VHD page-blob URI**
(`https://<account>.blob.core.windows.net/<container>/<name>.vhd`) if you
chose the alternative storage-account flow instead. If you stage the
disk yourself, pass
`--supported-disk-controller-types SCSI NVMe` to `az disk create` so
that the resulting managed image is bootable on v7 NVMe-only SKUs as
well.

When booting your own VM from the published VHD, pass
`--disk-controller-type SCSI` on v6-class SKUs and
`--disk-controller-type NVMe` on v7 SKUs; both are supported by the
shipped initrd.

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
   * `ref:refs/heads/main` (weekly build + smoke test)
   * `environment:azure-janitor` (daily janitor)
3. Grants the SP `Contributor` on each run RG and `Reader` on the control RG.
   Contributor on the run RG is sufficient for the smoke test's per-run
   managed-disk staging (`az disk create --for-upload` + `az disk
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

Releases are tagged `YYYYMMDD-HHMM` (UTC), e.g. `20260324-0000`.  
The tag is generated by `get_version.sh`:

```bash
./get_version.sh   # → 20260324-0426
```

---

## License

[MIT](LICENSE) © 2026 Poom Nupong
