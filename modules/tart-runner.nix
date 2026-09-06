# tart.runners.<name> — N ephemeral GitHub Actions runner controllers on one
# host, each an isolated Tart-VM-per-job loop (see packages/tart-runner.nix
# for the engine + provenance). Instances share the hard Apple Virtualization
# budget of TWO concurrent macOS guests via the slot semaphore; the module
# asserts the configured ceiling never exceeds it.
#
# Secret delivery is the CONSUMER's job: `privateKeyPath` points at a file the
# host materializes (agenix, manual install, …) — no key material transits Nix.
# LaunchAgents run in the GUI login user's session — a Virtualization.framework
# requirement (guest boot needs the user's unlocked data-protection keychain),
# so there is deliberately no daemon-user mode.
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
        labels = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "self-hosted"
            "macOS"
            "arm64"
            "tart"
            name
          ];
          description = "Registered with --no-default-labels; instance name included by default.";
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

  enabled = lib.filterAttrs (_: r: r.enable) cfg.runners;

  # One base image + host-key pin per DISTINCT image (instances share them).
  imageKey = r: builtins.hashString "sha256" "${r.image.oci}@${r.image.digest}";
  baseNameFor = r: "tr-base-${lib.substring 0 12 (imageKey r)}";
  pinPathFor = r: "${cfg.runnerStateDir}/pins/${lib.substring 0 12 (imageKey r)}.known_hosts";

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
    TR_SLOTS_DIR = "${cfg.runnerStateDir}/slots";
    TR_SLOTS_MAX = toString cfg.runnerSlots;
    TR_RUNNER_DIR = r.runnerDirInGuest;
  };

  envExports =
    env:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env);
in
{
  options.tart = {
    runners = lib.mkOption {
      type = lib.types.attrsOf runnerType;
      default = { };
      description = "Ephemeral Tart-VM GitHub Actions runner instances.";
    };
    runnerSlots = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Host-wide concurrent-VM ceiling shared by ALL instances.";
    };
    runnerStateDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/tart-runner";
      description = "Slots + host-key pins. /tmp survives the GUI session fine; pins regenerate via setup.";
    };
  };

  config = lib.mkIf (enabled != { }) {
    assertions = [
      {
        assertion = cfg.runnerSlots <= 2;
        message = "tart.runnerSlots must be <= 2: Apple's Virtualization framework refuses a third concurrent macOS guest.";
      }
    ];

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
          StandardOutPath = "/tmp/tart-runner/${name}.log";
          StandardErrorPath = "/tmp/tart-runner/${name}.log";
        };
      }
    ) enabled;

    # Per-instance setup helpers on PATH: tart-runner-setup-<name> does the
    # digest-pinned pull + base clone + host-key pin for that instance's image.
    environment.systemPackages = lib.mapAttrsToList (
      name: r:
      pkgs.writeShellScriptBin "tart-runner-setup-${name}" ''
        ${envExports (mkEnv name r)}
        exec ${lib.getExe' engine.setup "tart-runner-setup"}
      ''
    ) enabled;
  };
}
