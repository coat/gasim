{
  description = "A simulator for the GA144 multi-computer";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {
      # programs.gasim: gasim, and gasim-gui's fonts and colors, from Stylix
      # when it is on
      homeModules.default = import ./nix/hm-module.nix self;
    } (
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
                deno
                # the GUI's window, input and drawing, linked with -fsys=sdl3
                sdl3
                # zig build bench, where poop is not
                hyperfine
              ]
              ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [elfkickers kcov poop]);
          };

          formatter.${system} = pkgs.alejandra;

          packages.${system} = {
            default = pkgs.callPackage ./package.nix {};
            # gasim and gasim-gui; `nix run .#gui` runs the GUI
            gui = pkgs.callPackage ./package.nix {gui = true;};
          };
        }
      )
      systems
    );
}
