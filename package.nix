{
  lib,
  stdenv,
  elfkickers,
  makeWrapper,
  runCommand,
  sdl3,
  zenity,
  zig,
  # gasim-gui too, beside gasim
  gui ? false,
}:
stdenv.mkDerivation (
  finalAttrs: {
    name =
      if gui
      then "gasim-gui"
      else "gasim";
    version = "0.2.0";
    src = lib.cleanSource ./.;

    # the build cannot fetch dependencies from its sandbox, so fetch them
    # ahead of time: those configuring the build asks for, lazy ones too, so
    # dvui only with -Dgui. Not `zig build --fetch=all`, which fetches dvui
    # anyway, and fails on Linux for a dependency of SDL's that is only for
    # Windows; and with the system's SDL3, as the build says, SDL's source is
    # not fetched, the same on every platform. Update the hashes whenever
    # build.zig.zon changes.
    deps =
      runCommand "${finalAttrs.name}-${finalAttrs.version}-zig-deps" {
        inherit (finalAttrs) src;
        nativeBuildInputs = [zig];
        outputHashMode = "recursive";
        outputHash =
          if gui
          then "sha256-sS40EmJPMhtCWZlLp4WMX9thyxYDJEmWKS/kFL+NKeU="
          else "sha256-1FlTbzfg1D8Ls9CaOdBny5DbOuYwthga8iA22RC67b4=";
      } ''
        export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
        runHook unpackPhase
        cd $sourceRoot
        zig build ${lib.concatStringsSep " " finalAttrs.guiFlags} --list-steps > /dev/null
        mv $ZIG_GLOBAL_CACHE_DIR/p $out
      '';

    nativeBuildInputs =
      [
        zig.hook
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [elfkickers]
      ++ lib.optionals (gui && stdenv.hostPlatform.isLinux) [makeWrapper];

    buildInputs = lib.optionals gui [sdl3];

    postConfigure = ''
      ln -s ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
    '';

    # gasim-gui, installed beside gasim, with the system's SDL3
    guiFlags = lib.optionals gui ["-Dgui" "-fsys=sdl3"];

    zigBuildFlags =
      [
        "-Doptimize=ReleaseSmall"
        "--color off"
      ]
      ++ finalAttrs.guiFlags;

    # the GUI's file dialogs are tinyfiledialogs, which runs whichever dialog
    # program it finds on PATH, or else asks in the terminal. Zenity goes
    # after PATH, so a desktop's own kdialog still comes first. macOS has
    # osascript.
    postFixup = lib.optionalString (gui && stdenv.hostPlatform.isLinux) ''
      wrapProgram $out/bin/gasim-gui --suffix PATH : ${lib.makeBinPath [zenity]}
    '';

    meta = {
      mainProgram = finalAttrs.name;
      license = lib.licenses.mit;
    };
  }
)
