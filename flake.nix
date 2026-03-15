{
  description = "A simulator for the GA144 multi-computer";

  inputs.nixpkgs.url = "nixpkgs/nixos-25.11";
  inputs.zig.url = "github:mitchellh/zig-overlay";

  outputs = {
    nixpkgs,
    zig,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [zig.overlays.default];
          };
        in {
          devShells.${system}.default = pkgs.mkShell {
            packages = with pkgs;
              [
                zigpkgs.master
              ]
              ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [elfkickers kcov]);
          };

          formatter.${system} = pkgs.alejandra;

          packages.${system}.default = pkgs.callPackage ./package.nix {zig = pkgs.zigpkgs.master;};
        }
      )
      systems
    );
}
