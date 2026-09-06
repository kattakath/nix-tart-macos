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

  # Env contract (set by the darwin module's per-instance wrapper):
  #   TR_NAME TR_SCOPE_TYPE(org|repo) TR_SCOPE TR_APP_ID TR_INSTALLATION_ID
  #   TR_KEY_PATH TR_LABELS TR_RUNNER_GROUP TR_BASE_IMAGE TR_OCI_IMAGE
  #   TR_OCI_DIGEST TR_CPU TR_MEMORY_MB TR_VM_USER TR_VM_PASS TR_KNOWN_HOSTS
  #   TR_SLOTS_DIR TR_SLOTS_MAX TR_RUNNER_DIR TR_BOOT_TIMEOUT
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

      log() { echo "[$(date -u +%FT%TZ)] [$TR_NAME] $*" >&2; }

      # --- slot semaphore: atomic mkdir per slot; reclaim slots whose owner
      # PID is dead (crashed controller). Blocks until a slot frees up —
      # GitHub simply queues jobs while no runner is registered.
      acquire_slot() {
        while :; do
          local i
          for i in $(seq 1 "$TR_SLOTS_MAX"); do
            local d="$TR_SLOTS_DIR/slot-$i"
            if mkdir "$d" 2>/dev/null; then
              echo "$$" > "$d/pid"
              SLOT_DIR="$d"
              return 0
            fi
            local owner
            owner=$(cat "$d/pid" 2>/dev/null || true)
            if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
              log "reclaiming stale slot $i (dead pid $owner)"
              rm -rf "$d"
            fi
          done
          sleep 10
        done
      }
      release_slot() { [ -n "''${SLOT_DIR:-}" ] && rm -rf "$SLOT_DIR"; SLOT_DIR=""; }

      # --- reaper: ONLY this instance's prefix — never siblings'.
      reap_own_orphans() {
        local vm
        for vm in $("$TART" list --quiet 2>/dev/null | grep "^run-$TR_NAME-" || true); do
          log "reaping orphan $vm"
          "$TART" stop "$vm" >/dev/null 2>&1 || true
          "$TART" delete "$vm" >/dev/null 2>&1 || true
        done
      }

      run_one_job() {
        local vm uuid run_pid="" rc=0
        uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
        vm="run-$TR_NAME-$uuid"
        cleanup() {
          "$TART" stop "$vm" >/dev/null 2>&1 || true
          if [ -n "$run_pid" ]; then
            kill "$run_pid" >/dev/null 2>&1 || true
            wait "$run_pid" 2>/dev/null || true
          fi
          "$TART" delete "$vm" >/dev/null 2>&1 || log "WARNING: delete $vm failed — possible leaked clone"
          release_slot
        }
        trap cleanup RETURN

        if [ ! -s "$TR_KNOWN_HOSTS" ]; then
          log "pinned host key missing ($TR_KNOWN_HOSTS) — run tart-runner-setup; refusing"
          sleep 60
          return 1
        fi

        acquire_slot
        log "slot acquired; minting registration token"
        local token
        token=$(tart-runner-mint) || { log "mint failed"; sleep 30; return 1; }
        [ -n "$token" ] && [ "$token" != "null" ] || { log "empty token"; sleep 30; return 1; }

        log "clone $TR_BASE_IMAGE -> $vm"
        "$TART" clone "$TR_BASE_IMAGE" "$vm" || return 1
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
      log "controller up (scope=$TR_SCOPE_TYPE:$TR_SCOPE slots<=$TR_SLOTS_MAX)"
      while :; do
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
      # Idempotent per-image bootstrap: digest-pinned pull -> local base clone
      # -> boot a throwaway clone once to pin the shared SSH host key (all
      # clones of one image share it). Env: TR_OCI_IMAGE TR_OCI_DIGEST
      # TR_BASE_IMAGE TR_KNOWN_HOSTS [TR_VM_USER/TR_VM_PASS].
      : "''${TR_OCI_IMAGE:?}" "''${TR_OCI_DIGEST:?}" "''${TR_BASE_IMAGE:?}" "''${TR_KNOWN_HOSTS:?}"
      TART=${tartBin}
      TR_VM_USER="''${TR_VM_USER:-admin}"
      case "$TR_OCI_DIGEST" in sha256:*) ;; *) echo "TR_OCI_DIGEST must be sha256:… (digest pin is mandatory)" >&2; exit 2 ;; esac

      if ! "$TART" list --quiet 2>/dev/null | grep -qx "$TR_BASE_IMAGE"; then
        echo "pulling $TR_OCI_IMAGE@$TR_OCI_DIGEST" >&2
        "$TART" pull "$TR_OCI_IMAGE@$TR_OCI_DIGEST"
        "$TART" clone "$TR_OCI_IMAGE@$TR_OCI_DIGEST" "$TR_BASE_IMAGE"
      fi

      if [ ! -s "$TR_KNOWN_HOSTS" ]; then
        pin="pin-tmp-$$"
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
