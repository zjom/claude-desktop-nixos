{
  description = "Claude Desktop (official Linux beta) packaged for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f (pkgsFor system));
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          # Scoped to this flake's own package set; consumers' configs are unaffected.
          config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-desktop";
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        claude-desktop = pkgs.callPackage ./pkgs/claude-desktop { };
        claude-desktop-cowork = claude-desktop.override { withCowork = true; };
        default = claude-desktop;
        update = pkgs.writeShellApplication {
          name = "claude-desktop-update";
          runtimeInputs = with pkgs; [
            coreutils
            curl
            gawk
            git
            gnugrep
            gnupg
            jq
            nix
          ];
          text = builtins.readFile ./scripts/update.sh;
          runtimeEnv.KEYRING = ./keys/claude-desktop-archive-keyring.asc;
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop;
          meta.description = "Run Claude Desktop";
        };
        update = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.update;
          meta.description = "Bump pkgs/claude-desktop/sources.json to the latest upstream release";
        };
      });

      overlays.default = final: _prev: {
        claude-desktop = final.callPackage ./pkgs/claude-desktop { };
      };

      nixosModules.claude-desktop = import ./modules/nixos.nix self;
      nixosModules.default = self.nixosModules.claude-desktop;

      checks = forAllSystems (
        pkgs:
        let
          eval = lib.nixosSystem {
            system = pkgs.stdenv.hostPlatform.system;
            modules = [
              self.nixosModules.default
              {
                nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-desktop";
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "none";
                  fsType = "tmpfs";
                };
                system.stateVersion = "26.05";
                users.users.alice.isNormalUser = true;
                xdg.portal.config.common.default = "*";
                programs.claude-desktop = {
                  enable = true;
                  cowork.enable = true;
                  cowork.users = [ "alice" ];
                  keyring.enable = true;
                };
              }
            ];
          };
        in
        {
          # Evaluates the module down to the toplevel .drv; context is discarded so
          # neither the system closure nor its .drv inputs are realised.
          nixos-module = pkgs.writeText "nixos-module-eval" (
            builtins.unsafeDiscardStringContext eval.config.system.build.toplevel.drvPath
          );
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) claude-desktop;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
