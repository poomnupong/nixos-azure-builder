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
  # Disk controller support (SCSI + NVMe)
  #
  # Azure VM families differ in which remote-disk controller they expose to
  # the guest:
  #   * Older series (Dasv5/Easv5 and earlier): Hyper-V SCSI only
  #     (root appears as /dev/sda).
  #   * v6 series (Dasv6/Easv6): Hyper-V SCSI by default, or NVMe when
  #     deployed with `az vm create --disk-controller-type NVMe`.
  #   * v7 series (Dasv7/Easv7): NVMe-only (root appears as /dev/nvme0n1).
  # To make a single image bootable on all of them, the initramfs must contain
  # the drivers for both controllers; otherwise stage-1 cannot find the root
  # filesystem on whichever controller Azure picked. nixos-generators' azure
  # profile normally pulls these in, but we list them explicitly so the image
  # remains controller-agnostic even if the upstream profile changes.
  #
  # Root is identified by label/UUID (set by the azure profile), so the
  # difference between /dev/sda and /dev/nvme0n1 is irrelevant once the
  # driver is loaded.
  boot.initrd.availableKernelModules = [
    # NVMe (v7 SKUs, and v6 when --disk-controller-type NVMe)
    "nvme"
    "nvme_core"
    # Hyper-V SCSI / VMBus / netvsc (v5 and earlier, default path on v6)
    "hv_storvsc"
    "hv_vmbus"
    "hv_netvsc"
  ];
}
