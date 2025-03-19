{
  description = "A simulator for the GA144 multi-computer";

  inputs = {
    # We want to stay as up to date as possible but need to be careful that the
    # glibc versions used by our dependencies from Nix are compatible with the
    # system glibc that the user is building for.
    nixpkgs.url = "github:nixos/nixpkgs/release-24.11";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    gitignore.url = "github:hercules-ci/gitignore.nix";
    gitignore.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    nixpkgs,
    zig-overlay,
    gitignore,
    ...
  }:
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = zig-overlay.packages.${system}."0.14.0";
          gitignoreSource = gitignore.lib.gitignoreSource;
          target = builtins.replaceStrings ["darwin"] ["macos"] system;
        in {
          devShells.${system}.default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              kcov
              zig
            ];
          };

          formatter.${system} = pkgs.alejandra;

          packages.${system} = rec {
            default = gasim;
            gasim = pkgs.stdenvNoCC.mkDerivation {
              name = "gasim";
              version = "0.1.0";
              meta.mainProgram = "gasim";
              src = gitignoreSource ./.;
              nativeBuildInputs = [zig];
              dontConfigure = true;
              dontInstall = true;
              doCheck = true;
              buildPhase = ''
                NO_COLOR=1 # prevent escape codes from messing up the `nix log`
                zig build install --global-cache-dir $(pwd)/.cache -Dtarget=${target} -Doptimize=ReleaseSafe --prefix $out
              '';
              checkPhase = ''
                zig build test --global-cache-dir $(pwd)/.cache -Dtarget=${target}
              '';
            };
          };
        }
        # Our supported systems are the same supported systems as the Zig binaries.
      ) (builtins.attrNames zig-overlay.packages)
    );
}
