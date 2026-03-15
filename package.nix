{
  lib,
  stdenv,
  elfkickers,
  zig,
}:
stdenv.mkDerivation (
  finalAttrs: {
    name = "gasim";
    version = "0.0.1";
    src = lib.cleanSource ./.;
    nativeBuildInputs =
      [
        zig.hook
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [elfkickers];

    zigBuildFlags = [
      "-Doptimize=ReleaseSmall"
      "--color off"
    ];

    meta = {
      mainProgram = finalAttrs.name;
      license = lib.licenses.mit;
    };
  }
)
