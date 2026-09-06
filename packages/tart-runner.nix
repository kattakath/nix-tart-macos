# tart-runner — ephemeral GitHub Actions runners in disposable Tart macOS VMs,
# multi-instance (N orgs/repos) with a host-wide VM-slot semaphore.
#
# Provenance: the controller's hardened bones (fail-closed host-key pin,
# stdin-only secret passing, orphan reaping, RETURN-trap VM teardown) are
# absorbed from a1678991/github-tart-runner (MIT, Copyright (c) 2026
# a1678991 — notice preserved per license). Three structural fixes make
# N instances real, which the original's singleton design forbade:
#   1. per-instance VM prefixes (run-<instance>-*) + a reaper SCOPED to its
#      own prefix — the original's global `run-*` reaper killed sibling VMs;
#   2. unique runner names (<instance>-<uuid>) with NO --replace — the
#      original's `tart-$(hostname)` + --replace made parallel runners evict
#      each other's registration (all clones share one hostname);
#   3. a host-wide slot semaphore (atomic mkdir, stale-PID reclaim) so any
#      mix of controllers shares the hard Apple Virtualization budget of
#      TWO concurrent macOS guests per host.
# Token mint follows this fleet's github-runner pattern: App key -> RS256
# JWT -> installation token -> registration token, supporting BOTH org scope
# (POST /orgs/{org}/...) and repo scope (POST /repos/{owner}/{repo}/...).
{
  lib,
  writeShellApplication,
  writeText,
  coreutils,
  gnugrep,
  gnused,
  jq,
  openssl,
  openssh,
  sshpass,
  curl,
  tart,
}:
let
  tartBin = lib.getExe tart;
  # The host-wide slot semaphore — SHARED with the GitLab executor shims
  # (packages/gitlab-tart.nix); packages/tart-slots.nix is the one protocol.
  slotsLib = import ./tart-slots.nix { inherit writeText; };

  # Env contract (set by the darwin module's per-instance wrapper):
  #   TR_NAME TR_SCOPE_TYPE(org|repo) TR_SCOPE TR_APP_ID TR_INSTALLATION_ID
  #   TR_KEY_PATH TR_LABELS TR_RUNNER_GROUP TR_BASE_IMAGE TR_OCI_IMAGE
  #   TR_OCI_DIGEST TR_CPU TR_MEMORY_MB TR_VM_USER TR_VM_PASS TR_KNOWN_HOSTS
  #   TR_SETUP_OWNER TR_LIVE_BASES TR_SLOTS_DIR TR_SLOTS_MAX TR_RUNNER_DIR
  #   TR_BOOT_TIMEOUT TR_PULL_TIMEOUT
  mint = writeShellApplication {
    name = "tart-runner-mint";
    runtimeInputs = [
      coreutils
      jq
      openssl
      curl
    ];
    text = ''
      # App private key -> 10-min RS256 JWT -> ~1h installation token ->
      # short-lived runner REGISTRATION token for the instance's scope.
      # Prints ONLY the registration token; everything else goes to stderr.
      : "''${TR_APP_ID:?}" "''${TR_INSTALLATION_ID:?}" "''${TR_KEY_PATH:?}"
      : "''${TR_SCOPE_TYPE:?}" "''${TR_SCOPE:?}"
      [ -r "$TR_KEY_PATH" ] || { echo "tart-runner-mint: key unreadable: $TR_KEY_PATH" >&2; exit 1; }

      b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
      now=$(date +%s)
      header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
      payload=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$((now - 60))" "$((now + 600))" "$TR_APP_ID" | b64url)
      sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$TR_KEY_PATH" | b64url)
      jwt="$header.$payload.$sig"

      inst_token=$(curl -fsS -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/$TR_INSTALLATION_ID/access_tokens" \
        | jq -r '.token')
      [ -n "$inst_token" ] && [ "$inst_token" != "null" ] || { echo "tart-runner-mint: installation token mint failed" >&2; exit 1; }

      case "$TR_SCOPE_TYPE" in
        org) url="https://api.github.com/orgs/$TR_SCOPE/actions/runners/registration-token" ;;
        repo) url="https://api.github.com/repos/$TR_SCOPE/actions/runners/registration-token" ;;
        *) echo "tart-runner-mint: bad TR_SCOPE_TYPE '$TR_SCOPE_TYPE'" >&2; exit 1 ;;
      esac
      curl -fsS -X POST \
        -H "Authorization: Bearer $inst_token" \
        -H "Accept: application/vnd.github+json" \
        "$url" | jq -r '.token'
    '';
  };

  controller = writeShellApplication {
    name = "tart-runner-controller";
    runtimeInputs = [
      coreutils
      gnugrep
      gnused
      jq
      openssh
      sshpass
      mint
      # The controller SELF-HEALS a missing base image / host-key pin by
      # running the same idempotent engine the operator would (see
      # ensure_image below), so `setup` must be on its PATH.
      setup
    ];
    # Deliberately NOT errexit for the loop body (one bad iteration must not
    # kill the agent); pipefail+nounset stay.
    excludeShellChecks = [ "SC2015" ];
    text = ''
      set +e
      set -uo pipefail
      : "''${TR_NAME:?}" "''${TR_SCOPE:?}" "''${TR_LABELS:?}" "''${TR_BASE_IMAGE:?}"
      : "''${TR_KNOWN_HOSTS:?}" "''${TR_SLOTS_DIR:?}" "''${TR_SLOTS_MAX:?}"
      TART=${tartBin}
      TR_CPU="''${TR_CPU:-4}"
      TR_MEMORY_MB="''${TR_MEMORY_MB:-8192}"
      TR_VM_USER="''${TR_VM_USER:-admin}"
      TR_VM_PASS="''${TR_VM_PASS:-admin}"
      TR_RUNNER_GROUP="''${TR_RUNNER_GROUP:-Default}"
      TR_RUNNER_DIR="''${TR_RUNNER_DIR:-/Users/admin/actions-runner}"
      TR_BOOT_TIMEOUT="''${TR_BOOT_TIMEOUT:-180}"
      # A first pull of a Cirrus macOS runner image is tens of GB — hours on a
      # home link, not the ~180s a pin boot costs. Bounded so a wedged pull
      # cannot hold the loop forever.
      TR_PULL_TIMEOUT="''${TR_PULL_TIMEOUT:-14400}"

      log() { echo "[$(date -u +%FT%TZ)] [$TR_NAME] $*" >&2; }

      # --- slot semaphore: the shared library (tart-slots.sh) — one protocol
      # with the GitLab shims. Blocks until a slot frees; GitHub simply queues
      # jobs while no runner is registered.
      # shellcheck disable=SC1091
      source ${slotsLib}

      # --- reaper: ONLY this instance's prefixes — never siblings'. pin-tmp-*
      # is in scope because the pin boot now runs from this KeepAlive
      # controller (ensure_image), so a restart mid-pin can strand a RUNNING
      # throwaway guest that carries no slot marker — invisible to
      # _slot_stale, and permanently one of Apple's two guests.
      reap_own_orphans() {
        local vm
        for vm in $("$TART" list --quiet 2>/dev/null | grep -e "^run-$TR_NAME-" -e "^pin-tmp-$TR_NAME-" || true); do
          log "reaping orphan $vm"
          "$TART" stop "$vm" >/dev/null 2>&1 || true
          "$TART" delete "$vm" >/dev/null 2>&1 || true
        done
      }

      # --- GC: a digest bump renames the base clone (both it and the pin are
      # keyed by sha256(oci@digest)), so superseded tr-base-* would accumulate
      # at tens of GB each. TR_LIVE_BASES is the set EVERY enabled instance on
      # this host still needs, computed in modules/github-runner.nix, so this
      # can never delete a sibling's base.
      #
      # ORDERING IS LOAD-BEARING: this runs ONLY from mark_ready(), i.e. only
      # once the CURRENT base and pin are both confirmed present — never at
      # startup. Deleting first and pulling second means a well-formed but
      # WRONG digest (a typo, or a tag deleted upstream) strands the host with
      # no base at all, and reverting hosts/macos.nix then costs a multi-hour,
      # tens-of-GB re-pull. Delete-after-successful-pull has no such hole.
      gc_superseded_bases() {
        local vm
        for vm in $("$TART" list --quiet 2>/dev/null | grep '^tr-base-' || true); do
          case " ''${TR_LIVE_BASES:-} " in *" $vm "*) continue ;; esac
          log "deleting superseded base image $vm"
          "$TART" delete "$vm" >/dev/null 2>&1 || log "WARNING: delete $vm failed"
        done
      }

      # --- pre-flight: a digest bump renames BOTH the base clone AND the pin,
      # so BOTH must be checked. 2026-09-05: only the pin was checked, and
      # from INSIDE the job function below the trap armed at its top — so a
      # missing pin logged "possible leaked clone" for a VM that was never
      # cloned, every ~60s, for a day, with 0 runners registered. Gating the
      # pin alone would merely move that loop downstream to `tart clone`.
      # Fail-closed throughout: never falls back to StrictHostKeyChecking=no.
      base_present() { "$TART" list --quiet 2>/dev/null | grep -qx "$TR_BASE_IMAGE"; }
      pin_present() { [ -s "$TR_KNOWN_HOSTS" ]; }

      heal_fails=0
      heal_wait=30
      gc_done=0
      # Single success path, so GC can never be reached with the current base
      # missing. Idempotent-once: TR_LIVE_BASES is fixed for this process, so a
      # second sweep would always be a no-op.
      mark_ready() {
        heal_fails=0
        heal_wait=30
        if [ "''${TR_SETUP_OWNER:-0}" = "1" ] && [ "$gc_done" = "0" ]; then
          gc_superseded_bases
          gc_done=1
        fi
      }
      ensure_image() {
        if base_present && pin_present; then
          mark_ready
          return 0
        fi
        if [ "''${TR_SETUP_OWNER:-0}" != "1" ]; then
          log "base/pin for $TR_OCI_DIGEST not ready — the owning lane for this image re-creates them; retry in ''${heal_wait}s"
        else
          if ! base_present; then
            log "base image $TR_BASE_IMAGE absent (digest $TR_OCI_DIGEST) — pulling; NO slot held, this can take hours on a first pull"
            timeout "$TR_PULL_TIMEOUT" tart-runner-setup image || log "image pull FAILED ($TR_OCI_IMAGE@$TR_OCI_DIGEST)"
          fi
          if base_present && ! pin_present; then
            # The pin boots a throwaway guest, so it must respect Apple's
            # host-wide 2-guest cap — the pull must not.
            log "host-key pin $TR_KNOWN_HOSTS absent — re-pinning in a slot (one guest boot, <=''${TR_BOOT_TIMEOUT}s)"
            slot_acquire_pid
            tart-runner-setup pin || log "re-pin FAILED ($TR_OCI_IMAGE@$TR_OCI_DIGEST)"
            slot_release
          fi
          if base_present && pin_present; then
            mark_ready
            return 0
          fi
        fi
        heal_fails=$((heal_fails + 1))
        if [ "$heal_fails" -ge 5 ]; then
          log "ESCALATION: $heal_fails consecutive failures preparing $TR_OCI_IMAGE@$TR_OCI_DIGEST (base=$TR_BASE_IMAGE pin=$TR_KNOWN_HOSTS); 0 runners registered for $TR_SCOPE — try tart-runner-setup-$TR_NAME by hand"
        fi
        sleep "$heal_wait"
        # Exponential backoff, capped: a genuinely broken digest must not
        # re-attempt a multi-GB pull every 30s forever.
        heal_wait=$((heal_wait * 2))
        [ "$heal_wait" -le 900 ] || heal_wait=900
        return 1
      }

      run_one_job() {
        local vm uuid run_pid="" rc=0 cloned=0
        uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
        vm="run-$TR_NAME-$uuid"
        # Tear down only what was actually created. The RETURN trap fires on
        # EVERY early return (mint failure, empty token), and an unconditional
        # `tart delete` on a never-cloned VM emits a bogus "possible leaked
        # clone" — the red herring that sat next to the real 2026-09-05 cause
        # in the log.
        cleanup() {
          if [ "$cloned" = 1 ]; then
            "$TART" stop "$vm" >/dev/null 2>&1 || true
          fi
          if [ -n "$run_pid" ]; then
            kill "$run_pid" >/dev/null 2>&1 || true
            wait "$run_pid" 2>/dev/null || true
          fi
          if [ "$cloned" = 1 ]; then
            "$TART" delete "$vm" >/dev/null 2>&1 || log "WARNING: delete $vm failed — possible leaked clone"
          fi
          slot_release
        }
        trap cleanup RETURN

        slot_acquire_pid
        log "slot acquired; minting registration token"
        local token
        token=$(tart-runner-mint) || { log "mint failed"; sleep 30; return 1; }
        [ -n "$token" ] && [ "$token" != "null" ] || { log "empty token"; sleep 30; return 1; }

        log "clone $TR_BASE_IMAGE -> $vm"
        "$TART" clone "$TR_BASE_IMAGE" "$vm" || return 1
        cloned=1
        "$TART" set "$vm" --cpu "$TR_CPU" --memory "$TR_MEMORY_MB" || return 1
        "$TART" run --no-graphics "$vm" >/dev/null 2>&1 &
        run_pid=$!

        local ip="" waited=0
        while [ -z "$ip" ] && [ "$waited" -lt "$TR_BOOT_TIMEOUT" ]; do
          sleep 3
          waited=$((waited + 3))
          ip=$("$TART" ip "$vm" 2>/dev/null || true)
        done
        [ -n "$ip" ] || { log "no IP within ''${TR_BOOT_TIMEOUT}s"; return 1; }
        log "guest up at $ip; registering runner $TR_NAME-$uuid and running one job"

        # Secrets ride stdin, never argv. Unique --name per clone; --ephemeral
        # deregisters after ONE job; NO --replace (unique names never collide,
        # and GitHub garbage-collects a crashed ephemeral registration).
        {
          printf 'export REG_TOKEN=%q RUNNER_NAME=%q SCOPE_URL=%q LABELS=%q GROUP=%q RUNNER_DIR=%q\n' \
            "$token" "$TR_NAME-$uuid" "$SCOPE_URL" "$TR_LABELS" "$TR_RUNNER_GROUP" "$TR_RUNNER_DIR"
          cat <<'GUEST'
      set -euo pipefail
      export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
      cd "$RUNNER_DIR"
      ./config.sh --unattended --url "$SCOPE_URL" --token "$REG_TOKEN" \
        --ephemeral --name "$RUNNER_NAME" --runnergroup "$GROUP" \
        --no-default-labels --labels "$LABELS"
      ./run.sh
      GUEST
        } | sshpass -p "$TR_VM_PASS" ssh \
          -o UserKnownHostsFile="$TR_KNOWN_HOSTS" \
          -o StrictHostKeyChecking=yes \
          -o PreferredAuthentications=password \
          -o PubkeyAuthentication=no \
          -o IdentityAgent=none \
          "$TR_VM_USER@$ip" 'bash -s'
        rc=$?
        [ "$rc" -eq 0 ] || log "guest session rc=$rc (job failure or ssh drop)"
        return "$rc"
      }

      case "''${TR_SCOPE_TYPE:?}" in
        org) SCOPE_URL="https://github.com/$TR_SCOPE" ;;
        repo) SCOPE_URL="https://github.com/$TR_SCOPE" ;;
        *) log "bad TR_SCOPE_TYPE"; exit 1 ;;
      esac
      mkdir -p "$TR_SLOTS_DIR"
      reap_own_orphans
      log "controller up (scope=$TR_SCOPE_TYPE:$TR_SCOPE slots<=$TR_SLOTS_MAX setup_owner=''${TR_SETUP_OWNER:-0})"
      while :; do
        # Pre-flight OUTSIDE run_one_job: no trap armed, no slot held, so a
        # missing base/pin costs neither a bogus teardown warning nor one of
        # the two guests the other CI lane also draws from.
        ensure_image || continue
        run_one_job
        sleep 5
      done
    '';
  };

  setup = writeShellApplication {
    name = "tart-runner-setup";
    runtimeInputs = [
      coreutils
      gnugrep
      openssh
      sshpass
    ];
    text = ''
      # Idempotent per-image bootstrap, in two independently runnable stages:
      #   image  digest-pinned pull -> local base clone (NO guest boots, so no
      #          VM slot is needed — this is the multi-GB, multi-hour half)
      #   pin    boot a throwaway clone once to pin the shared SSH host key
      #          (all clones of one image share it) — one guest, needs a slot
      #   all    both, in order (the default; what the operator runs by hand)
      # The controller calls the stages separately so it never holds one of
      # Apple's two guest slots during a pull. Env: TR_OCI_IMAGE TR_OCI_DIGEST
      # TR_BASE_IMAGE TR_KNOWN_HOSTS [TR_NAME TR_VM_USER/TR_VM_PASS].
      : "''${TR_OCI_IMAGE:?}" "''${TR_OCI_DIGEST:?}" "''${TR_BASE_IMAGE:?}" "''${TR_KNOWN_HOSTS:?}"
      TART=${tartBin}
      TR_VM_USER="''${TR_VM_USER:-admin}"
      stage="''${1:-all}"
      case "$stage" in image | pin | all) ;; *) echo "usage: tart-runner-setup [image|pin|all]" >&2; exit 2 ;; esac
      case "$TR_OCI_DIGEST" in sha256:*) ;; *) echo "TR_OCI_DIGEST must be sha256:… (digest pin is mandatory)" >&2; exit 2 ;; esac

      if [ "$stage" != pin ] && ! "$TART" list --quiet 2>/dev/null | grep -qx "$TR_BASE_IMAGE"; then
        echo "pulling $TR_OCI_IMAGE@$TR_OCI_DIGEST" >&2
        "$TART" pull "$TR_OCI_IMAGE@$TR_OCI_DIGEST"
        "$TART" clone "$TR_OCI_IMAGE@$TR_OCI_DIGEST" "$TR_BASE_IMAGE"
      fi

      if [ "$stage" != image ] && [ ! -s "$TR_KNOWN_HOSTS" ]; then
        # Per-instance name so the controller's reaper can clean up a guest
        # stranded by a restart mid-pin without touching a sibling's.
        pin="pin-tmp-''${TR_NAME:-setup}-$$"
        echo "pinning host key via throwaway clone $pin" >&2
        "$TART" clone "$TR_BASE_IMAGE" "$pin"
        "$TART" run --no-graphics "$pin" >/dev/null 2>&1 &
        rp=$!
        ip=""; waited=0
        while [ -z "$ip" ] && [ "$waited" -lt 180 ]; do
          sleep 3; waited=$((waited + 3)); ip=$("$TART" ip "$pin" 2>/dev/null || true)
        done
        if [ -n "$ip" ]; then
          mkdir -p "$(dirname "$TR_KNOWN_HOSTS")"
          ssh-keyscan -t ed25519 "$ip" 2>/dev/null | sed "s/^$ip/*/" > "$TR_KNOWN_HOSTS"
        fi
        "$TART" stop "$pin" >/dev/null 2>&1 || true
        kill "$rp" 2>/dev/null || true; wait "$rp" 2>/dev/null || true
        "$TART" delete "$pin" >/dev/null 2>&1 || true
        [ -s "$TR_KNOWN_HOSTS" ] || { echo "host-key pin FAILED" >&2; exit 1; }
      fi
      echo "setup ok: base=$TR_BASE_IMAGE pin=$TR_KNOWN_HOSTS" >&2
    '';
  };
in
{
  inherit controller mint setup;
}
