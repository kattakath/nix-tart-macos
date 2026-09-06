# tart.githubRunners.<name> — N ephemeral GitHub Actions runner controllers on
# one host, each an isolated Tart-VM-per-job loop (see packages/tart-runner.nix
# for the engine + provenance). Instances share the hard Apple Virtualization
# budget of TWO concurrent macOS guests via the slot semaphore (options in
# modules/slots.nix, shared with the GitLab lane); the module asserts the
# configured ceiling never exceeds it. `tart.runners` is a renamed-option
# alias from before the GitLab lane made the name ambiguous.
#
# Secret delivery is the CONSUMER's job: `privateKeyPath` points at a file the
# host materializes (agenix, manual install, …) — no key material transits Nix.
# LaunchAgents run in the GUI login user's session — a Virtualization.framework
# requirement (guest boot needs the user's unlocked data-protection keychain),
# so there is deliberately no daemon-user mode.
#
# Which is also why nix-darwin's own services.github-runners is declined, not
# missed: the option exists (modules/services/github-runner/options.nix:10,
# with `ephemeral` at :209), but it renders a launchd DAEMON under a
# `_github-runner` service user (service.nix:77 and :172) running the runner
# straight ON THE HOST — no VM-per-job dimension at all, which is the whole of
# what this module is for. It also hard-asserts `nix.enable` (service.nix:18),
# which Determinate Nix sets false.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.tart;
  engine = pkgs.callPackage ../packages/tart-runner.nix { };

  runnerType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this runner instance" // {
          default = true;
        };
        scope = lib.mkOption {
          type = lib.types.submodule {
            options = {
              type = lib.mkOption {
                type = lib.types.enum [
                  "org"
                  "repo"
                ];
                description = "Register at org level or repo level.";
              };
              value = lib.mkOption {
                type = lib.types.str;
                description = ''Org login ("kattakath") or "owner/repo" for repo scope.'';
              };
            };
          };
        };
        appId = lib.mkOption { type = lib.types.ints.positive; };
        installationId = lib.mkOption {
          type = lib.types.ints.positive;
          description = "The App's installation id ON THIS scope's account.";
        };
        privateKeyPath = lib.mkOption {
          type = lib.types.str;
          description = "Path to the GitHub App PEM at runtime (agenix output, etc.).";
        };
        # LABEL VOCABULARY — capability, not identity.
        #
        # `--no-default-labels` is passed (packages/tart-runner.nix), so GitHub
        # adds NOTHING server-side: this list is the runner's entire label set,
        # and the first three re-declare what GitHub would otherwise have
        # assigned on its own ({self-hosted, macOS, ARM64} — matching is
        # case-insensitive, so `arm64` here answers a job asking for `ARM64`).
        #
        # `tart` is the toolchain discriminator: a job that lands here runs in a
        # stock Cirrus guest, NOT on the host, so it sees no nix, no cachix and
        # no host postgres. The counterpart bare-metal lane
        # (nix-config `services.macosGithubRunner`) carries `nix` for the same
        # reason. Keep BOTH sides positive: a set that is merely "the other one
        # minus `tart`" is unmatchable, because GitHub has no negative selector
        # and this list is a strict superset of the bare-metal one.
        #
        # `name` is per-instance and stays for now. It is a MATCHING key today,
        # so removing it is a NARROW, not a cleanup — scope (org/repo) already
        # partitions these, and no workflow should be keying on it.
        #
        # FLIP ORDER for any narrowing change (dropping a label here, or
        # editing a consumer's `runs-on:`): labels are additive and free, but
        # `runs-on:` is a hard AND-match, so a not-yet-live label queues every
        # job forever instead of failing.
        #   1. WIDEN here first, activate, and confirm the label is live on an
        #      ONLINE runner for that exact scope
        #      (`gh api /orgs/<org>/actions/runners`). An ephemeral Tart
        #      registration only exists while a guest holds a slot, so "not
        #      listed" can mean "idle", not "misconfigured".
        #   2. FLIP consumers ONE repo at a time, watching the first run pick up
        #      a runner rather than queue.
        #   3. NARROW last, once nothing references the old label.
        labels = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          default = [
            "self-hosted"
            "macOS"
            "arm64"
            "tart"
            name
          ];
          description = ''
            The runner's COMPLETE label set — registered with
            `--no-default-labels`, so nothing is added server-side. Carries the
            fleet's canonical vocabulary ({self-hosted, macOS, arm64} + the
            `tart` toolchain discriminator) plus the instance name.
          '';
        };
        runnerGroup = lib.mkOption {
          type = lib.types.str;
          default = "Default";
        };
        image = lib.mkOption {
          type = lib.types.submodule {
            options = {
              oci = lib.mkOption {
                type = lib.types.str;
                example = "ghcr.io/cirruslabs/macos-runner:tahoe";
              };
              digest = lib.mkOption {
                type = lib.types.strMatching "sha256:[0-9a-f]{64}";
                description = "Mandatory digest pin — moving tags are refused.";
              };
            };
          };
        };
        cpu = lib.mkOption {
          type = lib.types.ints.positive;
          default = 4;
        };
        memoryMB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 8192;
        };
        runnerDirInGuest = lib.mkOption {
          type = lib.types.str;
          default = "/Users/admin/actions-runner";
          description = "Where the guest image ships actions-runner (Cirrus runner images).";
        };
      };
    }
  );

  enabled = lib.filterAttrs (_: r: r.enable) cfg.githubRunners;

  # One base image + host-key pin per DISTINCT image (instances share them).
  # BOTH are content-keyed by sha256(oci@digest), so a digest bump renames
  # BOTH — that is the correct invalidation story (a new image genuinely has a
  # new host key, and a fixed pin path would let a stale pin authenticate a
  # new guest), but it means the controller must be able to re-create them.
  imageKey = r: builtins.hashString "sha256" "${r.image.oci}@${r.image.digest}";
  baseNameFor = r: "tr-base-${lib.substring 0 12 (imageKey r)}";
  pinPathFor = r: "${cfg.runnerStateDir}/pins/${lib.substring 0 12 (imageKey r)}.known_hosts";

  # Re-pin/pull ownership, elected AT EVAL: exactly one instance per DISTINCT
  # image is the owner. lib.attrNames is sorted, so the choice is deterministic
  # and no runtime lock is needed — the lanes sharing one image can never race
  # to `tart pull` the same digest or write the same pin file.
  setupOwners = lib.mapAttrs (_: lib.head) (
    lib.groupBy (n: imageKey enabled.${n}) (lib.attrNames enabled)
  );
  isSetupOwner = name: setupOwners.${imageKey enabled.${name}} == name;

  # Every base image still wanted on this host — the owner GCs any other
  # tr-base-* (a bump would otherwise strand a whole superseded image — 222 GB
  # for macos-runner:tahoe, measured 2026-09-06 — and the operator's natural
  # remedy, deleting a base by hand, is exactly what leaves a pin with no base
  # behind it).
  liveBases = lib.concatStringsSep " " (lib.unique (lib.mapAttrsToList (_: baseNameFor) enabled));

  mkEnv = name: r: {
    TR_NAME = name;
    TR_SCOPE_TYPE = r.scope.type;
    TR_SCOPE = r.scope.value;
    TR_APP_ID = toString r.appId;
    TR_INSTALLATION_ID = toString r.installationId;
    TR_KEY_PATH = r.privateKeyPath;
    TR_LABELS = lib.concatStringsSep "," r.labels;
    TR_RUNNER_GROUP = r.runnerGroup;
    TR_BASE_IMAGE = baseNameFor r;
    TR_OCI_IMAGE = r.image.oci;
    TR_OCI_DIGEST = r.image.digest;
    TR_CPU = toString r.cpu;
    TR_MEMORY_MB = toString r.memoryMB;
    TR_KNOWN_HOSTS = pinPathFor r;
    TR_SETUP_OWNER = if isSetupOwner name then "1" else "0";
    TR_LIVE_BASES = liveBases;
    TR_SLOTS_DIR = "${cfg.runnerStateDir}/slots";
    TR_SLOTS_MAX = toString cfg.runnerSlots;
    TR_RUNNER_DIR = r.runnerDirInGuest;
  };

  envExports =
    env:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env);
in
{
  imports = [
    ./slots.nix
    (lib.mkRenamedOptionModule [ "tart" "runners" ] [ "tart" "githubRunners" ])
  ];

  options.tart = {
    githubRunners = lib.mkOption {
      type = lib.types.attrsOf runnerType;
      default = { };
      description = "Ephemeral Tart-VM GitHub Actions runner instances.";
    };
  };

  config = lib.mkIf (enabled != { }) {
    assertions = [
      {
        assertion = cfg.runnerSlots <= 2;
        message = "tart.runnerSlots must be <= 2: Apple's Virtualization framework refuses a third concurrent macOS guest.";
      }
    ];

    # Create the durable state dir as the LOGIN USER before launchd loads the
    # agents and opens StandardOutPath. Shape copied verbatim from nix-darwin
    # modules/system/launchd.nix, which does the same `sudo --user=` mkdir for
    # ~/Library/LaunchAgents; preActivation (not postActivation) because
    # nix-darwin's activation-scripts run userLaunchd BETWEEN the two.
    # `mkdir -p` is idempotent, so the GitLab lane declaring the same line is
    # harmless — and each lane must declare it itself, since this module is
    # the only one here that knows tart.githubRunners exists.
    system.activationScripts.preActivation.text = lib.mkAfter ''
      sudo --user=${config.system.primaryUser} -- /bin/mkdir -p ${lib.escapeShellArg cfg.runnerStateDir}
    '';

    # One GUI-session LaunchAgent per instance; arg0 is a nix-tart-runner-<name>
    # wrapper (BTM legibility + TCC read attribution — same rule the VM module
    # enforces mechanically in checks).
    launchd.user.agents = lib.mapAttrs' (
      name: r:
      lib.nameValuePair "tart-runner-${name}" {
        serviceConfig = {
          ProgramArguments = [
            "${pkgs.writeShellScriptBin "nix-tart-runner-${name}" ''
              ${envExports (mkEnv name r)}
              exec ${lib.getExe' engine.controller "tart-runner-controller"}
            ''}/bin/nix-tart-runner-${name}"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          ProcessType = "Background";
          # Follows the option like everything else — a hardcoded /tmp here
          # would leave the evidence for the next incident in the volatile
          # half while pins and slots sat somewhere durable.
          StandardOutPath = "${cfg.runnerStateDir}/${name}.log";
          StandardErrorPath = "${cfg.runnerStateDir}/${name}.log";
        };
      }
    ) enabled;

    # Per-instance setup helpers on PATH: tart-runner-setup-<name> does the
    # digest-pinned pull + base clone + host-key pin for that instance's image
    # (optional stage argument: `image`, `pin`, or `all` — the default). It is
    # no longer a mandatory one-shot: the elected owner's controller runs the
    # same engine itself whenever the base or the pin is missing. Keep it for
    # pre-warming a bump, and for diagnosing one by hand.
    environment.systemPackages = lib.mapAttrsToList (
      name: r:
      pkgs.writeShellScriptBin "tart-runner-setup-${name}" ''
        ${envExports (mkEnv name r)}
        exec ${lib.getExe' engine.setup "tart-runner-setup"} "$@"
      ''
    ) enabled;
  };
}
