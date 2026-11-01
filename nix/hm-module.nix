# Home Manager: gasim, and gasim-gui's fonts and colors in
# ~/.config/gasim/gui.json, from Stylix when it is on, or as given.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.gasim;
  stylix = config.stylix or {enable = false;};

  font = lib.types.submodule {
    options = {
      package = lib.mkOption {
        type = lib.types.package;
        description = "The package with the font's files.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        description = "The font's family name, as fontconfig knows it.";
      };
    };
  };

  # the files of a family's faces, as fontconfig finds them in its package
  # alone, without a bold or italic it only fakes
  faces = f: let
    fontsConf = pkgs.makeFontsConf {
      fontDirectories = [f.package];
      impureFontDirectories = [];
      includes = [];
    };
  in
    pkgs.runCommand "gasim-${lib.strings.sanitizeDerivationName f.name}-faces" {
      nativeBuildInputs = [pkgs.fontconfig pkgs.jq];
      FONTCONFIG_FILE = fontsConf;
    } ''
      export HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR
      face() { fc-match -f '%{file}' "${f.name}$1"; }
      regular=$(face "")
      other() { f=$(face "$1"); [ "$f" != "$regular" ] && echo "$f" || true; }
      jq -n --arg regular "$regular" --arg bold "$(other :bold)" \
        --arg italic "$(other :italic)" --arg bold_italic "$(other :bold:italic)" \
        '{$regular, $bold, $italic, $bold_italic} | with_entries(select(.value != ""))' > $out
    '';

  # gui.json: the size and colors as given, and each family's faces found
  guiJson = let
    families = lib.filterAttrs (_: f: f != null) {inherit (cfg.fonts) sans mono;};
    json = builtins.toJSON (lib.filterAttrs (_: v: v != null) {
      fonts = lib.filterAttrs (_: v: v != null) {inherit (cfg.fonts) size;};
      colors = lib.mapNullable (c: c // lib.optionalAttrs (cfg.dark != null) {inherit (cfg) dark;}) cfg.colors;
    });
  in
    pkgs.runCommand "gasim-gui.json" {
      nativeBuildInputs = [pkgs.jq];
      inherit json;
      passAsFile = ["json"];
    } ''
      jq '.fonts += {${lib.concatMapStringsSep ", " (n: "${n}: $" + n + "[0]") (lib.attrNames families)}}' $jsonPath \
        ${lib.concatStrings (lib.mapAttrsToList (n: f: "--slurpfile ${n} ${faces f} ") families)}> $out
    '';
in {
  options.programs.gasim = {
    enable = lib.mkEnableOption "gasim, the GA144 simulator";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.gui;
      defaultText = lib.literalExpression "gasim.packages.\${system}.gui";
      description = "gasim, with gasim-gui beside it.";
    };

    stylix.enable = lib.mkOption {
      type = lib.types.bool;
      default = stylix.enable;
      defaultText = lib.literalExpression "config.stylix.enable";
      description = "Whether to take gasim-gui's fonts and colors from Stylix.";
    };

    fonts = {
      sans = lib.mkOption {
        type = lib.types.nullOr font;
        default = null;
        example = lib.literalExpression ''{ package = pkgs.inter; name = "Inter"; }'';
        description = "The font for gasim-gui's text, or null for Vera Sans.";
      };
      mono = lib.mkOption {
        type = lib.types.nullOr font;
        default = null;
        example = lib.literalExpression ''{ package = pkgs.jetbrains-mono; name = "JetBrains Mono"; }'';
        description = "The font for code, stacks and RAM, or null for Vera Sans Mono.";
      };
      size = lib.mkOption {
        type = lib.types.nullOr lib.types.number;
        default = null;
        example = 11;
        description = "The text's size in points, or null for dvui's.";
      };
    };

    colors = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
      default = null;
      example = lib.literalExpression ''{ base00 = "#282828"; base01 = "#3c3836"; /* … */ base0F = "#d65d0e"; }'';
      description = ''
        A base16 scheme, base00 to base0F as hex, which gasim-gui's Auto
        theme shows in place of Adwaita's; null for Adwaita's.
      '';
    };

    dark = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether the colors are a dark scheme; null to tell from base00.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf cfg.stylix.enable {
      programs.gasim = {
        fonts = {
          sans = lib.mkDefault {inherit (stylix.fonts.sansSerif) package name;};
          mono = lib.mkDefault {inherit (stylix.fonts.monospace) package name;};
          size = lib.mkDefault stylix.fonts.sizes.applications;
        };
        colors = lib.mkDefault (lib.genAttrs
          (map (n: "base0${n}") ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "A" "B" "C" "D" "E" "F"])
          (n: config.lib.stylix.colors.withHashtag.${n}));
        dark = lib.mkIf (stylix.polarity != "either") (lib.mkDefault (stylix.polarity == "dark"));
      };
    })
    {
      home.packages = [cfg.package];
      xdg.configFile."gasim/gui.json" = lib.mkIf (cfg.fonts.sans != null || cfg.fonts.mono != null || cfg.fonts.size != null || cfg.colors != null) {
        source = guiJson;
      };
    }
  ]);
}
