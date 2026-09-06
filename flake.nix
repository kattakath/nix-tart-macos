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
        # Exported as PATHS (not `import`ed functions): the module system
        # dedupes modules by path identity, and gitlab-runner.nix `imports`
        # tart-runner.nix — a consumer listing both must not get a duplicate
        # `tart.runners` option declaration.
        darwinModules.default = ./modules/darwin.nix;
        darwinModules.tart = ./modules/darwin.nix;
        # Ephemeral GitHub Actions runners in disposable VMs
        # (tart.githubRunners.*; tart.runners still works via a renamed-option
        # alias). `runner` is the pre-rename export name, kept for consumers.
        darwinModules.github-runner = ./modules/github-runner.nix;
        darwinModules.runner = ./modules/github-runner.nix;
        # Declarative gitlab-runner wired to the Tart custom executor
        # (tart.gitlabRunner.*); token stays a runtime file, never in-store.
        darwinModules.gitlab-runner = ./modules/gitlab-runner.nix;
      };

      perSystem =
        { pkgs, system, ... }:
        let
          packages = rec {
            packer-plugin-tart = pkgs.callPackage ./packages/packer-plugin-tart.nix { };
            tart-guest-agent = pkgs.callPackage ./packages/tart-guest-agent.nix { };
            tart-vm = pkgs.callPackage ./packages/tart-vm.nix { inherit packer-plugin-tart; };
            # GitLab: cirruslabs' executor + the slot-shim config printer
            # (the stanza it prints embeds the shim store paths).
            gitlab-tart-executor = (pkgs.callPackage ./packages/gitlab-tart.nix { }).executor;
            tart-gitlab-print-config = (pkgs.callPackage ./packages/gitlab-tart.nix { }).printConfig;
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

            tart-runner = (pkgs.callPackage ./packages/tart-runner.nix { }).controller;

            # GitLab side: executor package + the slot shims (building
            # printConfig pulls executor + all four shims transitively, so
            # shellcheck gates every shim and the fetchurl hash is exercised).
            gitlab-tart = (pkgs.callPackage ./packages/gitlab-tart.nix { }).printConfig;

            runner-module =
              let
                inherit (inputs.nixpkgs) lib;
                eval = lib.evalModules {
                  modules = [
                    ./modules/github-runner.nix
                    {
                      options.environment.systemPackages = lib.mkOption {
                        type = lib.types.listOf lib.types.package;
                        default = [ ];
                      };
                      options.launchd.user.agents = lib.mkOption {
                        type = lib.types.attrsOf lib.types.anything;
                        default = { };
                      };
                      options.assertions = lib.mkOption {
                        type = lib.types.listOf lib.types.anything;
                        default = [ ];
                      };
                      # mkRenamedOptionModule records its deprecation notice
                      # here — the stub must declare it for the alias to eval.
                      options.warnings = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [ ];
                      };
                    }
                    {
                      _module.args.pkgs = pkgs;
                      # Deliberately the OLD name — this check also proves the
                      # tart.runners → tart.githubRunners rename alias fires.
                      tart.runners.smoke = {
                        scope = {
                          type = "org";
                          value = "example-org";
                        };
                        appId = 1;
                        installationId = 1;
                        privateKeyPath = "/etc/github-runner/key.pem";
                        image = {
                          oci = "ghcr.io/cirruslabs/macos-runner:tahoe";
                          digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
                        };
                      };
                    }
                  ];
                };
                agent = eval.config.launchd.user.agents."tart-runner-smoke".serviceConfig;
                slotAssert = builtins.head eval.config.assertions;
              in
              pkgs.runCommand "runner-module-eval"
                {
                  arg0 = builtins.head agent.ProgramArguments;
                  slotsOk = if slotAssert.assertion then "1" else "0";
                }
                ''
                  # arg0 rule + the <=2-VM assertion, both asserted mechanically.
                  case "$(basename "$arg0")" in
                    nix-tart-runner-smoke) : ;;
                    *) echo "arg0 rule violated: $arg0" >&2; exit 1 ;;
                  esac
                  [ "$slotsOk" = "1" ] || { echo "default runnerSlots failed its own assertion" >&2; exit 1; }
                  test -x "$arg0"
                  touch "$out"
                '';
            gitlab-runner-module =
              let
                inherit (inputs.nixpkgs) lib;
                eval = lib.evalModules {
                  modules = [
                    ./modules/gitlab-runner.nix
                    {
                      options.environment.systemPackages = lib.mkOption {
                        type = lib.types.listOf lib.types.package;
                        default = [ ];
                      };
                      options.launchd.user.agents = lib.mkOption {
                        type = lib.types.attrsOf lib.types.anything;
                        default = { };
                      };
                      options.assertions = lib.mkOption {
                        type = lib.types.listOf lib.types.anything;
                        default = [ ];
                      };
                    }
                    {
                      _module.args.pkgs = pkgs;
                      tart.gitlabRunner = {
                        enable = true;
                        runnerName = "smoke";
                        tokenFile = "/run/agenix/gitlab-runner-token";
                      };
                    }
                  ];
                };
                agent = eval.config.launchd.user.agents.gitlab-runner.serviceConfig;
              in
              pkgs.runCommand "gitlab-runner-module-eval"
                {
                  arg0 = builtins.head agent.ProgramArguments;
                }
                ''
                  # arg0 rule asserted mechanically; the wrapper's shellcheck
                  # already gated it at build (writeShellApplication).
                  case "$(basename "$arg0")" in
                    nix-gitlab-runner) : ;;
                    *) echo "arg0 rule violated: $arg0" >&2; exit 1 ;;
                  esac
                  test -x "$arg0"
                  # The rendered-config template must reference all four shims.
                  for stage in config prepare run cleanup; do
                    grep -q "nix-gitlab-tart-$stage" "$arg0" || {
                      echo "wrapper lost the $stage shim reference" >&2; exit 1;
                    }
                  done
                  touch "$out"
                '';
          };

          formatter = pkgs.nixfmt-rfc-style;
        };
    };
}
