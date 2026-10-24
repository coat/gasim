{
  description = "A simulator for the GA144 multi-computer";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = import nixpkgs {
            inherit system;
          };
        in {
          devShells.${system}.default = pkgs.mkShell {
            packages = with pkgs;
              [
                zig
              ]
              ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [elfkickers kcov]);
          };

          formatter.${system} = pkgs.alejandra;

          packages.${system}.default = pkgs.callPackage ./package.nix {};
        }
      )
      systems
    );
}
