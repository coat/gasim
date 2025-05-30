{
  description = "A simulator for the GA144 multi-computer";

  inputs = {
    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    nixpkgs.url = "github:nixos/nixpkgs/release-24.11";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls-pkg.url = "github:zigtools/zls?ref=0.14.0";
  };

  outputs = {
    nixpkgs,
    zig-overlay,
    zls-pkg,
    ...
  }:
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = zig-overlay.packages.${system}."0.14.0";
          zls = zls-pkg.packages.${system}.default;
        in {
          devShells.${system}.default = pkgs.mkShell {
            nativeBuildInputs = [
              zig
              zls
            ];
          };

          formatter.${system} = pkgs.alejandra;
        }
        # Our supported systems are the same supported systems as the Zig binaries.
      ) (builtins.attrNames zig-overlay.packages)
    );
}
