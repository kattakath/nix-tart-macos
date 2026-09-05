{
  description = "Nix flake — declarative lifecycle + plug-and-play provisioning for Tart macOS guest VMs on Apple Silicon: create/pull/bake a generic image (digest-pinned registry clone, or a local Packer golden-image bake from an Apple IPSW), start/stop/ssh/doctor it, bootstrap it over SSH into YOUR machine (login user, Determinate Nix, your nix-darwin flake, key, rotated password), and manage running VMs declaratively via a nix-darwin module (tart.vms.<name>).";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  nixConfig = {
    extra-substituters = [ "https://kattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "kattakath.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw="
    ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Tart drives Apple Virtualization.framework — this toolkit is
      # aarch64-darwin only, by nature (Tart supports Apple Silicon only).
      systems = [ "aarch64-darwin" ];

      flake = {
        # nix-darwin module for the HOST Mac: declarative tart.vms.<name>
        # (cpu/memory/headless/dirs/autoStart via launchd). Import it from a
        # consumer flake's darwinConfigurations modules list.
        darwinModules.default = import ./modules/darwin.nix;
        darwinModules.tart = import ./modules/darwin.nix;
      };

      perSystem =
        { pkgs, system, ... }:
        let
          packages = rec {
            packer-plugin-tart = pkgs.callPackage ./packages/packer-plugin-tart.nix { };
            tart-guest-agent = pkgs.callPackage ./packages/tart-guest-agent.nix { };
            tart-vm = pkgs.callPackage ./packages/tart-vm.nix { inherit packer-plugin-tart; };
            default = tart-vm;
          };
        in
        {
          # tart + packer carry non-OSI licenses (FSL / BUSL); allow exactly
          # those two, nothing blanket. tart-guest-agent's derivation sets its
          # own meta.license.free = false, hence its name in the list too.
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfreePredicate =
              pkg:
              builtins.elem (inputs.nixpkgs.lib.getName pkg) [
                "tart"
                "packer"
                "tart-guest-agent"
              ];
          };

          inherit packages;

          apps.default = {
            type = "app";
            program = "${packages.tart-vm}/bin/tart-vm";
          };
          apps.tart-vm = {
            type = "app";
            program = "${packages.tart-vm}/bin/tart-vm";
          };

          # `nix flake check` builds every package (writeShellApplication runs
          # shellcheck on the CLI), validates the vendored Packer template
          # against the pinned plugin offline, and smoke-evaluates the
          # nix-darwin module — including a mechanical arg0-rule assertion.
          checks = {
            inherit (packages) packer-plugin-tart tart-guest-agent tart-vm;

            packer-template =
              pkgs.runCommand "packer-template-validate"
                {
                  nativeBuildInputs = [ pkgs.packer ];
                }
                ''
                  export HOME="$TMPDIR"
                  export PACKER_NO_COLOR=1 CHECKPOINT_DISABLE=1
                  export PACKER_PLUGIN_PATH=${packages.packer-plugin-tart}/libexec/packer/plugins
                  packer validate ${./templates/vanilla-tahoe.pkr.hcl}
                  touch "$out"
                '';

            darwin-module =
              let
                inherit (inputs.nixpkgs) lib;
                eval = lib.evalModules {
                  modules = [
                    ./modules/darwin.nix
                    # Stub just the nix-darwin option surface the module writes
                    # to — enough for a smoke eval without a nix-darwin input.
                    {
                      options.environment.systemPackages = lib.mkOption {
                        type = lib.types.listOf lib.types.package;
                        default = [ ];
                      };
                      options.launchd.user.agents = lib.mkOption {
                        type = lib.types.attrsOf lib.types.anything;
                        default = { };
                      };
                    }
                    {
                      _module.args.pkgs = pkgs;
                      tart.vms.smoke = {
                        cpu = 2;
                        memory = 4096;
                        headless = true;
                        autoStart = true;
                        dirs = [ "Downloads:/tmp/downloads" ];
                      };
                    }
                  ];
                };
                agent = eval.config.launchd.user.agents."tart-vm-smoke".serviceConfig;
              in
              pkgs.runCommand "darwin-module-eval"
                {
                  arg0 = builtins.head agent.ProgramArguments;
                }
                ''
                  # The arg0 rule, asserted mechanically: BTM/TCC legibility
                  # requires a nix-<kebab> wrapper, never bare tart/sh.
                  case "$(basename "$arg0")" in
                    nix-tart-vm-smoke) : ;;
                    *)
                      echo "arg0 rule violated: $arg0" >&2
                      exit 1
                      ;;
                  esac
                  test -x "$arg0"
                  touch "$out"
                '';
          };

          formatter = pkgs.nixfmt-rfc-style;
        };
    };
}
