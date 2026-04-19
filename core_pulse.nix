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
}
