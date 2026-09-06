# tart.runnerSlots / tart.runnerStateDir — the host-wide concurrent-VM budget
# and the DURABLE state directory shared by BOTH CI lanes (github-runner.nix's
# controllers and gitlab-runner.nix's custom executor). Options only; each
# lane's module imports this file and the module system dedupes the shared
# path, so a consumer may list either lane or both.
{ config, lib, ... }:
let
  cfg = config.tart;

  # Volatile roots, refused outright. Two independent authors already do this:
  # nix-darwin modules/services/github-runner/service.nix:30 asserts a runner
  # workDir is not under /run or /private/var/run, and
  # a1678991/github-tart-runner carries a `dangerousDirs` guard rejecting /tmp
  # for the very artifact stored here (its host-key pin lives at a durable
  # /etc/github-runner/vm_known_hosts). /var/tmp is disqualified twice over —
  # purged AND world-writable, which is no place for a host-key pin.
  volatileRoots = [
    "/tmp"
    "/private/tmp"
    "/var/tmp"
    "/private/var/tmp"
    "/run"
    "/var/run"
    "/private/var/run"
  ];
  underVolatileRoot = p: lib.any (root: p == root || lib.hasPrefix "${root}/" p) volatileRoots;
in
{
  options.tart = {
    runnerSlots = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Host-wide concurrent-VM ceiling shared by ALL CI VM lanes.";
    };
    runnerStateDir = lib.mkOption {
      type = lib.types.str;
      # nix-darwin's own answer to "where does the login user live" —
      # modules/system/primary-user.nix. It is internal, but nix-darwin
      # consumes it itself (modules/nix/default.nix, modules/environment),
      # and modules/launchd/default.nix registers every launchd.user.agents
      # entry in system.requiresPrimaryUser, so a consumer of either lane
      # cannot leave system.primaryUser null without failing at eval.
      default = "${config.system.primaryUserHome}/.local/state/tart-runner";
      defaultText = lib.literalExpression ''"''${config.system.primaryUserHome}/.local/state/tart-runner"'';
      description = ''
        Durable state for BOTH CI lanes: the slot semaphore, the per-image SSH
        host-key pins, and both lanes' agent logs.

        Must be reboot-durable and writable by the GUI login user (these are
        `launchd.user.agents`, not daemons — /var/lib would need root). It must
        contain NO whitespace, and must not sit under a volatile root; both are
        asserted below.
      '';
    };
  };

  config.assertions = [
    {
      # 2026-09-05: the default was /tmp/tart-runner. macOS purged it, the
      # pins/ directory ceased to exist, and all three GitHub lanes
      # crash-looped every ~60s with 0 runners registered — silently, for a
      # day. An eval failure is the loudest signal available; take it.
      assertion = !(underVolatileRoot cfg.runnerStateDir);
      message = "tart.runnerStateDir must not be under a volatile root (${lib.concatStringsSep ", " volatileRoots}): it holds SSH host-key pins, the slot semaphore and both lanes' logs, and macOS purges those paths.";
    }
    {
      # Measured on OpenSSH_10.3p1: ssh re-tokenizes the argument to
      # `-o UserKnownHostsFile=…` on whitespace (it is a multi-file option),
      # AFTER the shell has handed it over as one argv element — so no amount
      # of quoting in packages/tart-runner.nix saves a path with a space in
      # it. Every guest connection would then fail under
      # StrictHostKeyChecking=yes, downstream of the slot acquire, starving
      # the other lane. Hence ~/.local/state and not ~/Library/Application
      # Support.
      assertion = builtins.match ".*[[:space:]].*" cfg.runnerStateDir == null;
      message = "tart.runnerStateDir must not contain whitespace: the host-key pin is passed as `ssh -o UserKnownHostsFile=<dir>/pins/…`, and ssh splits that option's argument on whitespace into multiple filenames.";
    }
  ];
}
