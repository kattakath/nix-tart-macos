# tart.gitlabRunner — a declarative gitlab-runner (custom executor → ephemeral
# Tart VM per job, via packages/gitlab-tart.nix's slot shims) as a GUI-session
# LaunchAgent.
#
# Why not nix-darwin's own services.gitlab-runner (it exists —
# modules/services/gitlab-runner.nix): it runs a launchd DAEMON under a
# dedicated `gitlab-runner` service user, and Tart guests can only boot in the
# GUI login user's session (Virtualization.framework needs the unlocked
# data-protection keychain — same constraint as tart.runners); its `script =`
# also execs a bare-`sh` arg0, and its registration flow is the legacy
# REGISTRATION_TOKEN model, not the modern glrt- authentication token.
#
# Secret delivery is the CONSUMER's job, same contract as tart.githubRunners:
# `tokenFile` points at a runtime file holding ONLY the glrt- runner token
# (agenix output, manual install, …) — no token material transits Nix. The
# config.toml is rendered AT AGENT START into ~/.config/nix-gitlab-runner/
# (0700/0600 via umask), so the token never touches the world-readable store.
# Registration itself (minting the glrt- token) stays a one-time manual act.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.tart.gitlabRunner;
  tartCfg = config.tart;
  gitlabTart = pkgs.callPackage ../packages/gitlab-tart.nix { };

  runner = pkgs.writeShellApplication {
    name = "nix-gitlab-runner";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
    ];
    text = ''
      umask 077

      # Slot-semaphore knobs for the nix-gitlab-tart-* shims (inherited by the
      # custom-executor children); shared with the GitHub tart.runners lane.
      export TR_SLOTS_DIR=${lib.escapeShellArg "${tartCfg.runnerStateDir}/slots"}
      export TR_SLOTS_MAX=${toString tartCfg.runnerSlots}

      # EXISTENCE is already handled by launchd (KeepAlive.PathState below), so
      # there is no wait-for-the-file loop here. CONTENT is not something
      # PathState can see: an EMPTY /run/agenix secret satisfies it and then
      # yields a launchd-healthy agent that logs "Runner token is empty or
      # whitespace; this runner will be skipped during job polling" once and
      # then polls nothing, forever. So fail CLOSED on empty.
      token=""
      until [ -n "$token" ]; do
        token="$(tr -d '[:space:]' < ${lib.escapeShellArg cfg.tokenFile} 2>/dev/null || true)"
        if [ -z "$token" ]; then
          echo "nix-gitlab-runner: waiting for a NON-EMPTY token in ${cfg.tokenFile}" >&2
          sleep 5
        fi
      done

      confDir="''${HOME}/.config/nix-gitlab-runner"
      mkdir -p "$confDir"
      cat > "$confDir/config.toml" <<EOF
      concurrent = ${toString cfg.concurrent}
      check_interval = 0
      shutdown_timeout = 0

      [[runners]]
        name = ${builtins.toJSON cfg.runnerName}
        url = ${builtins.toJSON cfg.url}
        token = "$token"
      ${lib.optionalString (cfg.runnerId != null) "  id = ${toString cfg.runnerId}"}
        executor = "custom"
        [runners.feature_flags]
          FF_RESOLVE_FULL_TLS_CHAIN = false
        [runners.custom]
          config_exec = "${gitlabTart.configShim}/bin/nix-gitlab-tart-config"
          prepare_exec = "${gitlabTart.prepare}/bin/nix-gitlab-tart-prepare"
          run_exec = "${gitlabTart.run}/bin/nix-gitlab-tart-run"
          cleanup_exec = "${gitlabTart.cleanup}/bin/nix-gitlab-tart-cleanup"
      EOF

      exec gitlab-runner run --config "$confDir/config.toml" --working-directory "$HOME"
    '';
  };
in
{
  # Shares tart.runnerSlots / tart.runnerStateDir with the GitHub lane (the
  # module system dedupes the double import when a consumer lists both lanes).
  imports = [ ./slots.nix ];

  options.tart.gitlabRunner = {
    enable = lib.mkEnableOption "declarative gitlab-runner with the Tart custom executor";
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://gitlab.com/";
      description = "GitLab instance URL.";
    };
    runnerName = lib.mkOption {
      type = lib.types.str;
      description = "The runner's registered name (cosmetic; identity is the token).";
    };
    runnerId = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "The runner id GitLab assigned at registration (optional metadata).";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime path to a file holding ONLY the glrt- runner authentication token.";
    };
    concurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Global job concurrency; may exceed the VM budget — the slot shims serialize.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.gitlab-runner;
      defaultText = "pkgs.gitlab-runner";
    };
  };

  config = lib.mkIf cfg.enable {
    # CLI on PATH for verify/status against the SAME rendered config.
    environment.systemPackages = [ cfg.package ];

    # Same durable-state mkdir as the GitHub lane, declared here too because
    # neither module may read the other's options (this one never declares
    # tart.githubRunners). `mkdir -p` is idempotent and preActivation.text is
    # a lines option, so both declaring it merges cleanly. preActivation, not
    # postActivation: nix-darwin runs userLaunchd — which loads this agent and
    # opens StandardOutPath below — between the two.
    system.activationScripts.preActivation.text = lib.mkAfter ''
      sudo --user=${config.system.primaryUser} -- /bin/mkdir -p ${lib.escapeShellArg tartCfg.runnerStateDir}
    '';

    launchd.user.agents.gitlab-runner = {
      serviceConfig = {
        ProgramArguments = [ "${runner}/bin/nix-gitlab-runner" ];
        RunAtLoad = true;
        # TWO GATES, because they catch different failures and neither covers
        # the other.
        #
        # Waiting for the runtime token file is launchd's job, not a shell
        # poll's: upstream option
        # nix-darwin.launchd.user.agents.<name>.serviceConfig.KeepAlive.PathState
        # exists (modules/launchd/launchd.nix:190 — attrsOf bool, "the job will
        # be kept alive as long as the path exists ... the intent of this
        # feature is that two or more jobs may create semaphores in the
        # file-system namespace") → using it. Before the consumer materializes
        # the token the agent simply stays down; the moment it lands launchd
        # starts us. Restart-on-crash is unchanged — the path outlives any one
        # `gitlab-runner run`.
        #
        # CONTENT is not something PathState can see: an EMPTY /run/agenix
        # secret satisfies PathState and then yields a launchd-healthy agent
        # that logs "Runner token is empty or whitespace; this runner will be
        # skipped during job polling" once and polls nothing, forever. That is
        # why the non-empty wait in `runner` above exists alongside this.
        KeepAlive.PathState = {
          "${cfg.tokenFile}" = true;
        };
        ProcessType = "Background";
        StandardOutPath = "${tartCfg.runnerStateDir}/gitlab-runner.log";
        StandardErrorPath = "${tartCfg.runnerStateDir}/gitlab-runner.log";
      };
    };
  };
}
