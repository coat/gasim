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

    # the build cannot fetch dependencies from its sandbox, so fetch them
    # ahead of time. Update the hash whenever build.zig.zon changes.
    deps = zig.fetchDeps {
      inherit (finalAttrs) src version;
      pname = finalAttrs.name;
      fetchAll = true;
      hash = "sha256-4pnOoQIVkcqpQbACJw8QC7G3QUz4rYGNZX3tDH0Jeek=";
    };

    nativeBuildInputs =
      [
        zig.hook
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [elfkickers];

    postConfigure = ''
      ln -s ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
    '';

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
