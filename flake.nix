{
  description = "NixOS Azure VHD image builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:
    let
      system = "x86_64-linux";
    in
    {
      packages.${system} = let
        azureImage = nixos-generators.nixosGenerate {
          inherit system;
          format = "azure";
          modules = [
            ./core_pulse.nix
          ];
        };
      in {
        inherit azureImage;
        # Convenience alias
        default = azureImage;
      };
    };
}
