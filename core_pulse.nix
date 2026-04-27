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
