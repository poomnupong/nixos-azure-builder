# core_pulse.nix
#
# This is your primary NixOS customization module.
# Fork this repository and edit this file to tailor the image to your needs:
#   - Add system packages under `environment.systemPackages`
#   - Define user accounts under `users.users`
#   - Inject SSH public keys under `users.users.<name>.openssh.authorizedKeys.keys`
#
# After editing, push to `main` and the weekly_forge workflow will
# automatically build and publish a fresh Azure VHD release.

{ pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Dynamic linker compatibility (nix-ld)
  #
  # NixOS lacks the standard /lib64/ld-linux-x86-64.so.2 dynamic linker.
  # Azure VM extensions (e.g. RunCommandLinux, installed by `az vm run-command
  # invoke`) are dynamically-linked ELF binaries that expect it. Without
  # nix-ld, these extensions fail with exit code 127.
  #
  # Baking nix-ld into the image ensures `az vm run-command` works from
  # first boot — no nixos-rebuild required. This unblocks CI/CD pipelines
  # (like poomlab-azure) that use run-command to push configuration to VMs.
  # ---------------------------------------------------------------------------
  programs.nix-ld.enable = true;

  # ---------------------------------------------------------------------------
  # System packages
  # Add any tools you want present in the image.
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    htop
    vim
  ];

  # ---------------------------------------------------------------------------
  # User accounts
  # Replace or extend the example user below with your own accounts.
  # ---------------------------------------------------------------------------
  users.users.nixos = {
    isNormalUser = true;
    description = "Default NixOS user";
    extraGroups = [ "wheel" "networkmanager" ];

    # Add your SSH public keys here so you can log in after deployment.
    # Example:
    #   openssh.authorizedKeys.keys = [
    #     "ssh-ed25519 AAAA... you@yourhost"
    #   ];
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... your-key-here"
    ];
  };

  # Azure provisioning user.
  # az vm create --admin-username azureuser injects an SSH key during first
  # boot via cloud-init (the provisioning agent on NixOS Azure images).
  # The user must exist at boot so cloud-init only needs to write the key
  # to ~/.ssh/authorized_keys (which sshd reads via AuthorizedKeysFile).
  # Do NOT set openssh.authorizedKeys.keys here — let cloud-init manage it.
  users.users.azureuser = {
    isNormalUser = true;
    description = "Azure admin user";
    extraGroups = [ "wheel" ];
  };

  # ---------------------------------------------------------------------------
  # cloud-init: wire azureuser as the default user
  #
  # The NixOS cloud-init module defaults to `users: ["root"]`, which tells
  # cloud-init to only manage root.  Azure IMDS provides the admin username
  # and SSH public key, but cloud-init ignores them unless a matching
  # "default_user" is configured.  Setting `users: ["default"]` plus
  # `system_info.default_user.name = "azureuser"` causes cloud-init to
  # inject the Azure-provided SSH key into ~azureuser/.ssh/authorized_keys.
  # ---------------------------------------------------------------------------
  services.cloud-init.settings = {
    # Tell cloud-init to use the Azure data source directly.  Without
    # this, cloud-init auto-detects by probing every compiled-in data
    # source in priority order, which can add minutes to first-boot
    # provisioning and push v7-series VMs past Azure's 20-minute
    # OSProvisioningTimedOut window.
    datasource_list = [ "Azure" ];

    users = [ "default" ];
    system_info = {
      distro = "nixos";
      network.renderers = [ "networkd" ];
      # Note: this intentionally mirrors users.users.azureuser above.
      # The NixOS declaration creates the OS user; this block tells
      # cloud-init which account receives Azure-provided SSH keys.
      default_user = {
        name = "azureuser";
        lock_passwd = true;
        gecos = "Azure Admin User";
        groups = [ "wheel" ];
        sudo = [ "ALL=(ALL) NOPASSWD:ALL" ];
        shell = "/run/current-system/sw/bin/bash";
      };
    };
  };

  # Allow the default user to use sudo without a password (handy for CI/CD).
  security.sudo.wheelNeedsPassword = false;

  # ---------------------------------------------------------------------------
  # SSH daemon
  # ---------------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = lib.mkForce "no";
    };
  };

  # ---------------------------------------------------------------------------
  # Locale / timezone – adjust as needed
  # ---------------------------------------------------------------------------
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Required by nixos-generators; do not remove.
  system.stateVersion = "24.11";

  # Set an explicit disk size to prevent the nixpkgs azure-image.nix postVM
  # script from running `truncate` on the already-converted VHD file.
  # When diskSize is "auto" (the default), that script appends 512 MB of zeros
  # after the VHD footer, which causes Azure to reject the image with:
  #   "Disk is expected to have cookie value 'conectix'."
  virtualisation.diskSize = 8192; # 8 GiB

  # ---------------------------------------------------------------------------
  # VM Generation
  #
  # Build a Generation 2 (UEFI/GPT) VHD. The smoke test and weekly_forge
  # both upload the VHD with `--hyper-v-generation V2`, so the image must
  # be built with GPT partitioning and an ESP (EFI System Partition).
  # The azure-image.nix default is "v1" (MBR/BIOS); deploying a Gen1 VHD
  # as a Gen2 disk causes the VM to fail UEFI boot — waagent/cloud-init
  # never run, and Azure reports OSProvisioningTimedOut.
  virtualisation.azureImage.vmGeneration = "v2";

  # ---------------------------------------------------------------------------
  # Disk controller + network driver support (SCSI + NVMe, netvsc + MANA)
  #
  # Azure VM families differ in which remote-disk controller they expose to
  # the guest:
  #   * Older series (Dasv5/Easv5 and earlier): Hyper-V SCSI only
  #     (root appears as /dev/sda).
  #   * v6 series (Dasv6/Easv6): NVMe-only (SCSI boot fails — see PR #50).
  #   * v7 series (Dasv7/Easv7): NVMe-only (root appears as /dev/nvme0n1).
  #
  # Network adapters also vary:
  #   * v5 and earlier: Mellanox SR-IOV accelerated NIC + hv_netvsc fallback.
  #   * v6: Mellanox SR-IOV accelerated NIC + hv_netvsc fallback.
  #   * v7+: MANA (Microsoft Azure Network Adapter) — requires the `mana`
  #     kernel module.  Without it, cloud-init cannot reach the Azure
  #     wireserver (168.63.129.16), causing OSProvisioningTimedOut.
  #
  # Root is identified by label (set by the azure profile), so the
  # difference between /dev/sda and /dev/nvme0n1 is irrelevant once the
  # driver is loaded.
  #
  # The upstream azure-common.nix already force-loads the Hyper-V stack
  # (hv_vmbus, hv_netvsc, hv_utils, hv_storvsc) via kernelModules.
  # We add NVMe modules to kernelModules (force-loaded) rather than
  # availableKernelModules (udev-triggered) because Azure's emulated
  # NVMe controller is not reliably detected by udev during initramfs
  # coldplug — leaving the root device invisible and causing a panic →
  # reboot loop → OSProvisioningTimedOut.
  #
  # Critically, Azure NVMe sits behind a Hyper-V virtual PCI bridge:
  #   hv_vmbus → pci_hyperv (virtual PCI bus) → nvme (PCIe NVMe device)
  # Without pci_hyperv, the virtual PCI bus never initializes and the
  # NVMe controller is invisible to the guest kernel. SCSI bypasses
  # PCI entirely (it goes through hv_storvsc over VMBus), which is why
  # SCSI boots worked without this module.
  #
  # MANA is also force-loaded: Azure VMs need networking available
  # early so cloud-init can reach the wireserver (168.63.129.16)
  # and report provisioning status within Azure's 20-min timeout.
  boot.initrd.kernelModules = [
    "pci_hyperv"
    "nvme"
    "nvme_core"
    "mana"
  ];
}
