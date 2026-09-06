{
  description = "Nix flake — declarative lifecycle + plug-and-play provisioning for Tart macOS guest VMs on Apple Silicon: create/pull/bake a generic image (digest-pinned registry clone, or a local Packer golden-image bake from an Apple IPSW), start/stop/ssh/doctor it, bootstrap it over SSH into YOUR machine (login user, Determinate Nix, your nix-darwin flake, key, rotated password), and manage running VMs declaratively via a nix-darwin module (tart.vms.<name>).";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
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
      imports = [ inputs.treefmt-nix.flakeModule ];

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
          inherit (inputs.nixpkgs) lib;

          # The nix-darwin option surface the runner modules write to or read
          # from — stubbed so the module checks smoke-eval without a nix-darwin
          # input. `system.primaryUser*` are here because modules/slots.nix
          # derives its durable default from primaryUserHome, and
          # `activationScripts` because both lanes mkdir that dir before
          # launchd opens their log paths.
          darwinStubs = {
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
            # mkRenamedOptionModule records its deprecation notice here — the
            # stub must declare it for the alias to eval.
            options.warnings = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            options.system.primaryUser = lib.mkOption {
              type = lib.types.str;
              default = "tester";
            };
            options.system.primaryUserHome = lib.mkOption {
              type = lib.types.str;
              default = "/Users/tester";
            };
            options.system.activationScripts = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options.text = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                  };
                }
              );
              default = { };
            };
          };

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
                eval = lib.evalModules {
                  modules = [
                    ./modules/github-runner.nix
                    darwinStubs
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
                eval = lib.evalModules {
                  modules = [
                    ./modules/gitlab-runner.nix
                    darwinStubs
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

            # The cross-lane state-dir contract, which nothing asserted before
            # 2026-09-05: BOTH lanes must derive slots, pins and logs from the
            # ONE tart.runnerStateDir. A base-dir move used to pass every check
            # whether or not it was internally consistent, and the /tmp literal
            # left behind in github-runner.nix's log paths went unnoticed for
            # as long as it existed.
            state-dir =
              let
                stateDir = "/Users/tester/.local/state/tart-runner";
                # Two instances, ONE image — so exactly one must be elected
                # the re-pin/pull owner.
                sharedRunner = {
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
                eval = lib.evalModules {
                  modules = [
                    ./modules/github-runner.nix
                    ./modules/gitlab-runner.nix
                    darwinStubs
                    {
                      _module.args.pkgs = pkgs;
                      tart.runnerStateDir = stateDir;
                      tart.githubRunners = {
                        alpha = sharedRunner;
                        beta = sharedRunner;
                      };
                      tart.gitlabRunner = {
                        enable = true;
                        runnerName = "smoke";
                        tokenFile = "/run/agenix/gitlab-runner-token";
                      };
                    }
                  ];
                };
                gh = n: eval.config.launchd.user.agents."tart-runner-${n}".serviceConfig;
                gl = eval.config.launchd.user.agents.gitlab-runner.serviceConfig;
                tartRunner = pkgs.callPackage ./packages/tart-runner.nix { };
              in
              pkgs.runCommand "state-dir-eval"
                {
                  inherit stateDir;
                  alphaArg0 = builtins.head (gh "alpha").ProgramArguments;
                  betaArg0 = builtins.head (gh "beta").ProgramArguments;
                  glArg0 = builtins.head gl.ProgramArguments;
                  logPaths = [
                    (gh "alpha").StandardOutPath
                    (gh "alpha").StandardErrorPath
                    (gh "beta").StandardOutPath
                    (gh "beta").StandardErrorPath
                    gl.StandardOutPath
                    gl.StandardErrorPath
                  ];
                  inherit (tartRunner) controller setup;
                  ghApi = tartRunner.api;
                  ghPoll = tartRunner.poll;
                  assertionsOk = if lib.all (a: a.assertion) eval.config.assertions then "1" else "0";
                }
                ''
                  fail() { echo "$*" >&2; exit 1; }

                  [ "$assertionsOk" = "1" ] || fail "the durable/whitespace state-dir assertions rejected their own default shape"

                  # (a)+(b) every agent log path follows the option.
                  for p in $logPaths; do
                    case "$p" in "$stateDir"/*) : ;; *) fail "log path escaped tart.runnerStateDir: $p" ;; esac
                  done

                  # (c) THE cross-lane invariant: one slots dir, or the
                  # two-guest semaphore silently stops being shared and a third
                  # guest fails inside Virtualization.framework mid-job.
                  for w in "$alphaArg0" "$betaArg0" "$glArg0"; do
                    grep -Eq "TR_SLOTS_DIR='?$stateDir/slots'?$" "$w" || fail "lane wrapper does not resolve $stateDir/slots: $w"
                  done

                  # (d) no volatile literal survives in any wrapper.
                  for w in "$alphaArg0" "$betaArg0" "$glArg0"; do
                    if grep -q "/tmp/" "$w"; then fail "wrapper still carries a /tmp literal: $w"; fi
                  done
                  for p in $logPaths; do
                    case "$p" in /tmp/* | /private/tmp/* | /var/tmp/*) fail "volatile log path: $p" ;; *) : ;; esac
                  done

                  # (e) no whitespace anywhere ssh will re-tokenize: it splits
                  # the -o UserKnownHostsFile argument on it.
                  case "$stateDir" in *[[:space:]]*) fail "state dir contains whitespace" ;; esac
                  grep -Eq "TR_KNOWN_HOSTS='?$stateDir/pins/[0-9a-f]{12}\.known_hosts'?$" "$alphaArg0" \
                    || fail "pin path is not a whitespace-free, digest-keyed path under $stateDir"

                  # (f) the controller's pre-flight gates on BOTH artifacts a
                  # digest bump renames, and runs OUTSIDE the job function.
                  ctl="$controller/bin/tart-runner-controller"
                  grep -q 'ensure_image || continue' "$ctl" || fail "controller main loop lost its pre-flight guard"
                  grep -q 'base_present && pin_present' "$ctl" || fail "pre-flight no longer gates on BOTH the base image and the host-key pin"

                  # (g) the digest-pinned reference must never carry a tag as
                  # well. `repo:tag@sha256:…` is rejected by tart's parser
                  # ("mismatched input '@'") before a byte is fetched, so every
                  # pull — manual or automatic — fails instantly and the host is
                  # left with no base image and no pin. That is what the
                  # 2026-09-05 digest bump actually did.
                  setupBin="$setup/bin/tart-runner-setup"
                  grep -q 'ociRef="\$TR_OCI_IMAGE"' "$setupBin" \
                    || fail "setup no longer strips the tag before appending the digest"
                  grep -q 'pull "\$pinnedRef"' "$setupBin" \
                    || fail "setup does not pull the tag-stripped, digest-pinned ref"
                  if grep -q 'pull "\$TR_OCI_IMAGE@\$TR_OCI_DIGEST"' "$setupBin"; then
                    fail "setup pulls tag+digest together — tart's parser rejects that ref"
                  fi

                  # (h) exactly one owner per distinct image.
                  owners=0
                  for w in "$alphaArg0" "$betaArg0"; do
                    if grep -Eq "TR_SETUP_OWNER='?1'?$" "$w"; then owners=$((owners + 1)); fi
                  done
                  [ "$owners" = 1 ] || fail "expected exactly 1 re-pin owner for one shared image, got $owners"

                  # (i) THE 2026-09-06 invariant: the controller must NOT wait
                  # for work inside a pre-booted guest. Before this, every lane
                  # cloned an 8 GB guest and ran `./run.sh` in it, so an idle
                  # lane held one of Apple's two guest slots indefinitely. The
                  # comments above say so; these greps are what actually stops
                  # a future edit from putting the long poll back in the guest.
                  apiBin="$ghApi/bin/tart-runner-api"
                  pollBin="$ghPoll/bin/tart-runner-poll"
                  test -x "$pollBin" || fail "no host-side queued-work poller is built"

                  # Invocation forms, not the bare words — the controller's own
                  # comments name both scripts to explain why they are gone.
                  if grep -q '\./config\.sh' "$ctl"; then
                    fail "controller still registers the runner with config.sh inside the guest"
                  fi
                  if grep -q '\./run\.sh' "$ctl"; then
                    fail "controller still drives the guest through run.sh (a restart loop, not a one-shot)"
                  fi
                  if grep -q 'registration-token' "$apiBin"; then
                    fail "the API helper still mints legacy runner registration tokens"
                  fi
                  grep -q 'generate-jitconfig' "$apiBin" \
                    || fail "the API helper no longer mints a JIT config"
                  grep -q 'ACTIONS_RUNNER_INPUT_JITCONFIG' "$ctl" \
                    || fail "controller no longer hands the guest a JIT config on stdin"
                  # The `run` subcommand is mandatory: without it Runner.Listener
                  # writes its config, prints usage and exits 0 — a supervisor
                  # reading exit 0 as success would spin launching no-op runners.
                  grep -q 'Runner\.Listener run' "$ctl" \
                    || fail "controller does not invoke Runner.Listener with the mandatory 'run' subcommand"
                  # Bearer tokens must reach curl through --config on stdin, never -H (argv is world-readable via ps).
                  if grep -q 'Authorization: Bearer' "$apiBin"; then
                    fail "the API helper puts a bearer token on a curl command line"
                  fi

                  # A guest is booted ONLY on the poll saying there is work.
                  grep -q 'tart-runner-poll' "$ctl" \
                    || fail "controller has no host-side queued-work poll"
                  # Assert the INVARIANT, not one line's shape: every CALL of
                  # run_one_job must sit inside the poll's `0)` arm. An earlier
                  # version pinned the literal `0) run_one_job ;;`, which broke
                  # the moment that arm legitimately grew a backoff — a test
                  # that fails on correct refactors teaches people to delete it.
                  grep -Eq '^[[:space:]]*0\)' "$ctl" \
                    || fail "controller lost the queued-work poll's result case arm"
                  awk '
                    /^[[:space:]]*0\)/ { inarm = 1 }
                    inarm && /^[[:space:]]*;;/ { inarm = 0 }
                    /run_one_job/ && !/run_one_job\(\)/ && !/^[[:space:]]*#/ {
                      if (!inarm) bad++
                    }
                    END { exit (bad ? 1 : 0) }
                  ' "$ctl" \
                    || fail "run_one_job is called outside the poll's 0) arm — an idle lane would boot a guest"
                  # And a runner is created at the forge only AFTER a slot is
                  # held: minting first would leave a registered runner behind
                  # on a slot-wait timeout, and GitHub would dispatch to it.
                  slotLine=$(grep -n 'if ! slot_acquire_pid; then' "$ctl" | head -n1 | cut -d: -f1)
                  jitLine=$(grep -n 'tart-runner-api jitconfig' "$ctl" | head -n1 | cut -d: -f1)
                  [ -n "$slotLine" ] && [ -n "$jitLine" ] \
                    || fail "cannot locate the slot acquire / JIT mint pair in the controller"
                  [ "$slotLine" -lt "$jitLine" ] \
                    || fail "the JIT config is minted before the guest slot is held"

                  # (j) the poll interval reaches the lane wrapper — a default
                  # baked only into the controller would silently ignore the option.
                  grep -Eq "TR_POLL_INTERVAL='?[0-9]+'?$" "$alphaArg0" \
                    || fail "lane wrapper does not carry a poll interval"

                  touch "$out"
                '';
          };

          # treefmt owns `nix fmt` and supplies its own `checks.treefmt` gate, so CI
          # needs no hand-rolled formatting step: `nix flake check` runs the formatter
          # from THIS flake's lock instead of the runner's ambient registry. Same tool
          # set as every other fleet flake — a bare `formatter = pkgs.nixfmt-rfc-style`
          # (what this was) formats but never LINTS, so statix anti-patterns and
          # deadnix's unused bindings went uncaught here while siblings caught them.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.deadnix.enable = true;
            programs.statix.enable = true;
          };
        };
    };
}
