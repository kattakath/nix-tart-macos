# nix-darwin module: declarative Tart VMs on the HOST Mac.
#
#   tart.vms.<name> = { cpu = 4; memory = 8192; headless = true; autoStart = true; };
#
# Each VM with autoStart = true gets a launchd user agent that runs
# `tart set` (cpu/memory) and then `tart run` with the declared shares.
#
# ARG0 RULE (deliberate, load-bearing): every launchd unit this module emits
# points ProgramArguments[0] at a `writeShellScriptBin "nix-tart-vm-<name>"`
# wrapper — NEVER at the bare `tart` binary (and never at `sh -c`).
# Two reasons:
#   1. BTM legibility — macOS's Background Task Manager (System Settings →
#      Login Items & Extensions) lists background agents by their executable
#      basename. A `nix-tart-vm-<name>` basename tags the agent as
#      Nix-managed at a glance; a bare `tart` (or worse, `sh`) is
#      indistinguishable from third-party or malicious persistence.
#   2. TCC file access — macOS attributes protected-folder access (Desktop/
#      Documents/Downloads) to the responsible process. Measured behavior on
#      macOS 26: an adhoc-signed /nix/store arg0 is allowed to read
#      ~/Downloads, while an attributable Apple interpreter like /bin/sh gets
#      a silent EPERM — so a shared-Downloads VM started via `sh -c` would
#      quietly lose its share. Undocumented by Apple; treat the wrapper as
#      mandatory hygiene, not a security boundary.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.tart;

  vmModule =
    { name, ... }:
    {
      options = {
        cpu = lib.mkOption {
          type = lib.types.ints.positive;
          default = 4;
          description = "Number of virtual CPUs (applied with `tart set` before each run).";
        };

        memory = lib.mkOption {
          type = lib.types.ints.positive;
          default = 8192;
          description = "Memory in MiB (applied with `tart set` before each run).";
        };

        headless = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Run without a VM window (`tart run --no-graphics`).";
        };

        dirs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "Downloads:/Users/me/Downloads" ];
          description = ''
            Host directories shared into the guest via VirtioFS, in tart's
            `NAME:PATH[:ro]` syntax (mounted under /Volumes/My Shared Files).
          '';
        };

        autoStart = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Start the VM at login via a launchd user agent (KeepAlive: it is
            restarted if it stops). Off by default: a VM you start by hand
            still benefits from the declared cpu/memory via `tart-vm start`.
          '';
        };

        extraRunArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "--vnc" ];
          description = "Extra arguments appended to `tart run`.";
        };

        logDir = lib.mkOption {
          type = lib.types.str;
          default = "/tmp";
          description = ''
            Directory for the agent's stdout/stderr log
            (tart-vm-<name>.log). Point it at ~/Library/Logs in practice;
            the default stays $HOME-free so the module evaluates without
            knowing the operator's home.
          '';
        };

        _name = lib.mkOption {
          type = lib.types.str;
          default = name;
          internal = true;
          readOnly = true;
          description = "The VM's tart name (the attribute name).";
        };
      };
    };

  # One nix-<kebab> wrapper per VM — see the ARG0 RULE header comment.
  mkRunner =
    name: vm:
    pkgs.writeShellScriptBin "nix-tart-vm-${name}" ''
      set -euo pipefail
      "${lib.getExe cfg.package}" set ${lib.escapeShellArg name} \
        --cpu ${toString vm.cpu} --memory ${toString vm.memory}
      exec "${lib.getExe cfg.package}" run \
        ${lib.optionalString vm.headless "--no-graphics"} \
        ${lib.concatMapStringsSep " " (d: "--dir=${lib.escapeShellArg d}") vm.dirs} \
        ${lib.escapeShellArgs vm.extraRunArgs} \
        ${lib.escapeShellArg name}
    '';

  autoStartVms = lib.filterAttrs (_: vm: vm.autoStart) cfg.vms;
in
{
  options.tart = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tart;
      defaultText = lib.literalExpression "pkgs.tart";
      description = "The tart package to manage VMs with (unfree — needs allowUnfree).";
    };

    vms = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule vmModule);
      default = { };
      description = ''
        Tart VMs to manage declaratively. The attribute name is the tart VM
        name. This module manages RUNTIME shape (cpu/memory/shares/autoStart);
        creating the VM itself is imperative by design (`tart-vm
        create|pull|bake`) because disks and IPSWs must never enter the Nix
        store.
      '';
    };
  };

  config = lib.mkIf (cfg.vms != { }) {
    environment.systemPackages = [ cfg.package ];

    launchd.user.agents = lib.mapAttrs' (
      name: vm:
      lib.nameValuePair "tart-vm-${name}" {
        serviceConfig = {
          Label = "org.nixos.tart-vm-${name}";
          # ProgramArguments[0] = the nix-tart-vm-<name> wrapper (ARG0 RULE above).
          ProgramArguments = [ (lib.getExe (mkRunner name vm)) ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${vm.logDir}/tart-vm-${name}.log";
          StandardErrorPath = "${vm.logDir}/tart-vm-${name}.log";
        };
      }
    ) autoStartVms;
  };
}
