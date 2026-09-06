# GitLab side of the shared-slot CI story: cirruslabs' first-party
# gitlab-tart-executor (ephemeral Tart VM per GitLab CI job, custom-executor
# interface) packaged from its release binary — nixpkgs carries it nowhere —
# plus SLOT SHIMS that make its VMs share the host's two-macOS-guest budget
# with the GitHub tart.runners controllers (packages/tart-slots.nix is the
# single protocol; the executor itself knows nothing about slots).
#
# Shim contract (gitlab-runner config.toml [runners.custom] points at these):
#   nix-gitlab-tart-prepare  acquire a slot keyed vm=gitlab-<CI_JOB_ID>
#                            (the executor's own deterministic VM name:
#                            internal/gitlab/env.go `fmt.Sprintf("gitlab-%s",
#                            e.JobID)`), then exec the real prepare.
#   nix-gitlab-tart-run      passthrough.
#   nix-gitlab-tart-cleanup  real cleanup first (deletes the VM), then release
#                            the slot by vm name — gitlab-runner ALWAYS runs
#                            cleanup, even when prepare failed, so a slot can
#                            never leak past a job. Stale-slot reclaim (vm no
#                            longer in `tart list`) covers hard crashes.
#   nix-gitlab-tart-config   passthrough (executor's config stage).
# `tart-gitlab-print-config` prints the exact config.toml stanza with these
# store paths — config.toml itself stays imperative (it holds the glrt-…
# runner token; the fleet's no-secrets-in-nix boundary).
#
# macOS 15+ note (upstream README): the "Local Network" privacy gate can stall
# VM SSH; either run prepare/run via the executor's privileged
# localnetworkhelper or pre-allow RFC1918 in com.apple.network.local-network.
{
  lib,
  stdenvNoCC,
  fetchurl,
  writeShellApplication,
  writeText,
  coreutils,
  gnugrep,
  tart,
}:
let
  version = "1.28.0";

  executor = stdenvNoCC.mkDerivation {
    pname = "gitlab-tart-executor";
    inherit version;
    src = fetchurl {
      url = "https://github.com/cirruslabs/gitlab-tart-executor/releases/download/${version}/gitlab-tart-executor-darwin-arm64";
      hash = "sha256-+cqtblS83EuqNQkJ0cO7AvR5lFAS5znavVnbB0LoNGg=";
    };
    dontUnpack = true;
    installPhase = ''
      install -D -m 0755 "$src" "$out/bin/gitlab-tart-executor"
    '';
    meta = {
      description = "GitLab Runner custom executor running jobs in ephemeral Tart VMs";
      homepage = "https://github.com/cirruslabs/gitlab-tart-executor";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
      mainProgram = "gitlab-tart-executor";
    };
  };

  slotsLib = import ./tart-slots.nix { inherit writeText; };

  exe = lib.getExe executor;
  tartBin = lib.getExe tart;

  slotEnvDefaults = ''
    export TART="''${TART:-${tartBin}}"
    export TR_SLOTS_DIR="''${TR_SLOTS_DIR:-/tmp/tart-runner/slots}"
    export TR_SLOTS_MAX="''${TR_SLOTS_MAX:-2}"
    # shellcheck disable=SC1091
    source ${slotsLib}
  '';

  mkShim =
    stage: body:
    writeShellApplication {
      name = "nix-gitlab-tart-${stage}";
      runtimeInputs = [
        coreutils
        gnugrep
      ];
      text = body;
    };

  prepare = mkShim "prepare" ''
    ${slotEnvDefaults}
    vm="gitlab-''${CUSTOM_ENV_CI_JOB_ID:?}"
    echo "nix-gitlab-tart-prepare: waiting for a VM slot ($vm)" >&2
    slot_acquire_vm "$vm"
    echo "nix-gitlab-tart-prepare: slot acquired" >&2
    exec ${exe} prepare "$@"
  '';

  run = mkShim "run" ''
    exec ${exe} run "$@"
  '';

  cleanup = mkShim "cleanup" ''
    ${slotEnvDefaults}
    vm="gitlab-''${CUSTOM_ENV_CI_JOB_ID:?}"
    rc=0
    ${exe} cleanup "$@" || rc=$?
    slot_release_vm "$vm"
    exit "$rc"
  '';

  configShim = mkShim "config" ''
    exec ${exe} config "$@"
  '';

  printConfig = writeShellApplication {
    name = "tart-gitlab-print-config";
    text = ''
      cat <<EOF
      # Paste into ~/.gitlab-runner/config.toml under your [[runners]] entry
      # (executor = "custom"). concurrent at top-level may exceed 2 — the slot
      # shims serialize VM starts against the host's two-guest budget.
        executor = "custom"
        [runners.feature_flags]
          FF_RESOLVE_FULL_TLS_CHAIN = false
        [runners.custom]
          config_exec = "${configShim}/bin/nix-gitlab-tart-config"
          prepare_exec = "${prepare}/bin/nix-gitlab-tart-prepare"
          run_exec = "${run}/bin/nix-gitlab-tart-run"
          cleanup_exec = "${cleanup}/bin/nix-gitlab-tart-cleanup"
      EOF
    '';
  };
in
{
  inherit
    executor
    prepare
    run
    cleanup
    configShim
    printConfig
    ;
}
