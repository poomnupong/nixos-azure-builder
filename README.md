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

1. Upload the `.vhd` from the GitHub Release to an **Azure Storage Account**.
2. Create a **Managed Image** from the blob.
3. Launch a VM from that image.

The default `core_pulse.nix` disables password authentication; make sure you
have added your SSH public key before building.

### Disk controller compatibility (SCSI vs NVMe)

Azure VM families differ in which remote-disk controller they boot with:
older series (e.g. Dasv5, Easv5) are **SCSI-only**, while newer v6/v7 series
(e.g. `Standard_E8-2as_v7`) default to **NVMe** and only fall back to SCSI
if the OS image declares it.

To keep the published image portable across SKUs, the smoke-test workflow
creates the managed image with **both controllers** declared:

```bash
az image create -g "$RG" -n "$IMG" \
  --os-type Linux \
  --hyper-v-generation V2 \
  --supported-disk-controller-types SCSI,NVMe \
  --source "$DISK_ID"
```

`az vm create` still has to pick **one** controller per VM via
`--disk-controller-type`. The smoke test currently pins `SCSI` because that
is the path validated end-to-end against the NixOS initrd we ship; the
declaration above means a future SKU swap to an NVMe-default family only
requires flipping that single flag, not rebuilding the image.

If you build your own VM from the published VHD on a v6/v7-class SKU and
hit `InvalidParameter: vmSize ... disk controller types`, mirror the same
two flags (`--supported-disk-controller-types SCSI,NVMe` on the image,
`--disk-controller-type SCSI` on the VM).

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
