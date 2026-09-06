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
#
# THE WAIT FOR WORK HAPPENS ON THE HOST, NOT IN A GUEST (2026-09-06).
# Until this change the controller booted an 8 GB guest and ran `./run.sh`
# inside it, so the guest long-polled GitHub while idle — a lane held one of
# Apple's two guest slots, and 8 GB of RAM, with no job to show for it. The
# GitLab lane never had this problem: gitlab-runner is a small host-side
# listener and the guest exists only for the duration of a job. The shape is
# now the same on both lanes:
#
#   job queued at the forge (free, up to 24h)
#     -> tart-runner-poll (host, cheap REST) sees queued work for THESE labels
#     -> bounded slot acquire; on timeout mint NOTHING, leave it queued
#     -> tart-runner-api jitconfig  (the runner is created at the forge HERE)
#     -> clone + boot guest -> Runner.Listener run -> one job -> destroy
#
# Registration is a JIT config (POST .../actions/runners/generate-jitconfig),
# not a registration token + `config.sh`. Verified live against
# pkgs.github-runner 2.336.0: `Runner.Listener run` with the blob in
# ACTIONS_RUNNER_INPUT_JITCONFIG reaches "Listening for Jobs" with no
# config.sh, no --url and no --token. Two traps worth keeping in view:
#   * the `run` subcommand is MANDATORY — without it the process writes the
#     config files, prints its usage banner and exits 0, so a supervisor that
#     reads exit 0 as success spins forever launching no-op runners;
#   * `--jitconfig` is absent from `--help` by deliberate omission (PrintUsage
#     is a hardcoded literal), NOT because the pinned runner is too old.
# JIT does NOT mean "nothing lands on the guest disk": the blob decodes to
# .runner/.credentials/.credentials_rsaparams, written into the runner dir at
# run time. What it removes is the registration token and any credential that
# outlives the guest — the guest is deleted minutes later either way.
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

  # The ONE way anything here talks to api.github.com, so "no secret in argv"
  # is a property of the helper rather than of each call site.
  ghLib = writeText "tart-runner-gh.sh" ''
    # `curl -H "Authorization: Bearer $tok"` is the obvious spelling and the
    # wrong one: every argument of an exec'd process is world-readable through
    # `ps -ww`, which on a shared Mac hands an installation token — or a JIT
    # blob carrying an RSA private key — to any local account. curl's own
    # config reader is the off-the-shelf fix: `--config -` takes the header
    # from STDIN, which no other process can see. Shell FUNCTION arguments are
    # not process arguments, so the token in $1 is not exposed either.
    gh_curl() { # $1 = bearer token; remaining args go to curl
      local tok="$1"
      shift
      printf 'header = "Authorization: Bearer %s"\n' "$tok" \
        | curl -fsS --config - \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$@"
    }
  '';

  # Env contract (set by the darwin module's per-instance wrapper):
  #   TR_NAME TR_SCOPE_TYPE(org|repo) TR_SCOPE TR_APP_ID TR_INSTALLATION_ID
  #   TR_KEY_PATH TR_LABELS TR_RUNNER_GROUP TR_BASE_IMAGE TR_OCI_IMAGE
  #   TR_OCI_DIGEST TR_CPU TR_MEMORY_MB TR_VM_USER TR_VM_PASS TR_KNOWN_HOSTS
  #   TR_SETUP_OWNER TR_LIVE_BASES TR_SLOTS_DIR TR_SLOTS_MAX TR_RUNNER_DIR
  #   TR_BOOT_TIMEOUT TR_PULL_TIMEOUT TR_POLL_INTERVAL TR_WATCH_REPOS
  api = writeShellApplication {
    name = "tart-runner-api";
    runtimeInputs = [
      coreutils
      jq
      openssl
      curl
    ];
    text = ''
      # The GitHub REST surface this lane needs, and nothing else:
      #   install-token            App PEM -> 10-min RS256 JWT -> ~1h token
      #   jitconfig <runner-name>  stdin: installation token
      #                            stdout: "<runner id>\n<encoded_jit_config>"
      #   runner-busy <id>         stdin: token; exit 0 busy, 3 idle
      #   runner-delete <id>       stdin: token; best-effort deregistration
      # Only install-token prints a secret it derived itself; everything else
      # takes the token on stdin, so no token ever reaches a command line.
      : "''${TR_SCOPE_TYPE:?}" "''${TR_SCOPE:?}"
      case "$TR_SCOPE_TYPE" in
        org | repo) ;;
        *) echo "tart-runner-api: bad TR_SCOPE_TYPE '$TR_SCOPE_TYPE'" >&2; exit 1 ;;
      esac
      # shellcheck disable=SC1091
      source ${ghLib}

      scope_path() {
        case "$TR_SCOPE_TYPE" in
          org) printf 'orgs/%s' "$TR_SCOPE" ;;
          repo) printf 'repos/%s' "$TR_SCOPE" ;;
        esac
      }

      read_token() {
        local t
        t=$(cat)
        [ -n "$t" ] || { echo "tart-runner-api: empty installation token on stdin" >&2; exit 1; }
        printf '%s' "$t"
      }

      case "''${1:-}" in
        install-token)
          : "''${TR_APP_ID:?}" "''${TR_INSTALLATION_ID:?}" "''${TR_KEY_PATH:?}"
          [ -r "$TR_KEY_PATH" ] || { echo "tart-runner-api: key unreadable: $TR_KEY_PATH" >&2; exit 1; }
          b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
          now=$(date +%s)
          header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
          payload=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$((now - 60))" "$((now + 600))" "$TR_APP_ID" | b64url)
          sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$TR_KEY_PATH" | b64url)
          jwt="$header.$payload.$sig"
          tok=$(gh_curl "$jwt" -X POST \
            "https://api.github.com/app/installations/$TR_INSTALLATION_ID/access_tokens" \
            | jq -r '.token // empty')
          [ -n "$tok" ] || { echo "tart-runner-api: installation token mint failed" >&2; exit 1; }
          printf '%s\n' "$tok"
          ;;

        jitconfig)
          name="''${2:?usage: tart-runner-api jitconfig <runner-name>}"
          : "''${TR_LABELS:?}"
          tok=$(read_token)
          # runner_group_id is REQUIRED by the endpoint and is an integer, but
          # the module's knob is a NAME — and the id for a given name is
          # account-specific ("Default" is 1 on dontsell-ai, verified, and
          # nothing promises that elsewhere). Resolve it per mint rather than
          # hard-coding the coupling; fall back to 1, which is what GitHub
          # assigns the built-in Default group.
          gid="''${TR_RUNNER_GROUP_ID:-}"
          if [ -z "$gid" ] && [ "$TR_SCOPE_TYPE" = org ]; then
            gid=$(gh_curl "$tok" "https://api.github.com/orgs/$TR_SCOPE/actions/runner-groups?per_page=100" \
              | jq -r --arg n "''${TR_RUNNER_GROUP:-Default}" \
                  '[.runner_groups[] | select(.name == $n) | .id][0] // empty' || true)
          fi
          case "$gid" in "" | *[!0-9]*) gid=1 ;; esac
          # Labels are EXACTLY what is passed — unlike config.sh, the JIT API
          # adds no {self-hosted, macOS, ARM64} defaults, so omitting
          # `self-hosted` here would silently make the runner unmatchable by
          # `runs-on: self-hosted`. The module's label option is the complete
          # set for precisely this reason.
          body=$(jq -cn --arg name "$name" --argjson gid "$gid" --arg labels "$TR_LABELS" \
            '{name: $name, runner_group_id: $gid, labels: ($labels | split(","))}')
          resp=$(gh_curl "$tok" -X POST -H "Content-Type: application/json" -d "$body" \
            "https://api.github.com/$(scope_path)/actions/runners/generate-jitconfig")
          rid=$(printf '%s' "$resp" | jq -r '.runner.id // empty')
          blob=$(printf '%s' "$resp" | jq -r '.encoded_jit_config // empty')
          [ -n "$rid" ] && [ -n "$blob" ] || {
            echo "tart-runner-api: generate-jitconfig returned no config" >&2
            exit 1
          }
          # The blob has NO expiry of its own — it carries no JWT, only an RSA
          # keypair bound to a server-side registration. What expires is that
          # REGISTRATION (GitHub deletes an ephemeral runner unconnected for
          # >1 day), so mint at boot time, never ahead of time, and treat a
          # "registration has been deleted" failure as "mint a fresh one".
          printf '%s\n%s\n' "$rid" "$blob"
          ;;

        runner-busy)
          id="''${2:?usage: tart-runner-api runner-busy <id>}"
          tok=$(read_token)
          busy=$(gh_curl "$tok" "https://api.github.com/$(scope_path)/actions/runners/$id" \
            | jq -r '.busy // false' || true)
          if [ "$busy" = "true" ]; then exit 0; fi
          exit 3
          ;;

        runner-delete)
          id="''${2:?usage: tart-runner-api runner-delete <id>}"
          tok=$(read_token)
          gh_curl "$tok" -X DELETE -o /dev/null \
            "https://api.github.com/$(scope_path)/actions/runners/$id"
          ;;

        *)
          echo "usage: tart-runner-api install-token | jitconfig <name> | runner-busy <id> | runner-delete <id>" >&2
          exit 2
          ;;
      esac
    '';
  };

  poll = writeShellApplication {
    name = "tart-runner-poll";
    runtimeInputs = [
      coreutils
      jq
      curl
    ];
    text = ''
      # HOST-SIDE queued-work detector. Reads an installation token on stdin.
      # Exit 0 = at least one QUEUED job whose `runs-on:` set this lane can
      # satisfy; 3 = nothing to do; 1 = the poll itself failed.
      #
      # WHY A PLAIN REST POLL AND NOT `gh webhook forward`.
      # `gh webhook forward` is the obvious "push, not poll" answer and it is
      # declined on purpose: GitHub documents it under *testing and
      # troubleshooting webhooks*, it needs an outbound long-lived connection
      # to a GitHub-operated relay, admin:org_hook scope, and a `gh` auth
      # session that is a PERSONAL credential rather than this lane's App
      # installation. It is a beta developer aid, not a production dispatch
      # channel, and it would put a second credential model next to the one
      # this module already has. A real webhook receiver is the other
      # alternative and is bigger than the problem: an ingress, a public URL
      # or a tunnel, a shared secret, an HTTP server and its own supervision —
      # a framework where a 60s `curl` suffices at a handful of jobs a day.
      # Motto grade: polling reuses the API this lane already authenticates
      # to, adds no component, and the "watch the queue depth" shape is the
      # same one actions-runner-controller used before webhooks
      # (TotalNumberOfQueuedAndInProgressWorkflowRuns, which likewise listed
      # runs per repo with status=queued / status=in_progress).
      #
      # IDLE COST, measured in requests per poll:
      #   repo scope : 2  (queued + in_progress run listings)
      #   org  scope : 2xR, plus 1 every TR_REPO_TTL to re-list the repos
      # A queued or in-progress RUN costs one extra jobs listing each; in the
      # steady idle state there are none, so the cost above is the whole cost.
      # At the default 60s interval and R=10 repos that is ~1200 requests/hour
      # against a GitHub App installation limit of >=5000/hour. If a bigger
      # installation gets close, narrow it with `watchRepos` (or lengthen
      # `pollIntervalSeconds`) rather than raising the limit; conditional
      # requests (curl --etag-compare/--etag-save; a 304 does not count against
      # the limit) are the next lever if that is ever not enough.
      : "''${TR_SCOPE_TYPE:?}" "''${TR_SCOPE:?}" "''${TR_LABELS:?}"
      # shellcheck disable=SC1091
      source ${ghLib}

      tok=$(cat)
      [ -n "$tok" ] || { echo "tart-runner-poll: empty installation token on stdin" >&2; exit 1; }

      # `runs-on:` is a hard AND-match and matching is case-insensitive, so a
      # job is dispatchable HERE iff every label it asks for is one this lane
      # registers. Subset, not intersection — an extra label on the runner is
      # free, a missing one is fatal.
      mine=$(jq -cn --arg l "$TR_LABELS" '$l | split(",") | map(ascii_downcase)')

      repos=""
      case "$TR_SCOPE_TYPE" in
        repo) repos="$TR_SCOPE" ;;
        org)
          if [ -n "''${TR_WATCH_REPOS:-}" ]; then
            repos=$(printf '%s' "$TR_WATCH_REPOS" | tr ' ' '\n')
          else
            # The App installation already knows exactly which repos this lane
            # may serve — no second list to keep in sync, and a repo added to
            # the installation starts being watched without a rebuild.
            p=1
            while [ "$p" -le 10 ]; do
              page=$(gh_curl "$tok" "https://api.github.com/installation/repositories?per_page=100&page=$p" \
                | jq -r '.repositories[].full_name' || true)
              [ -n "$page" ] || break
              repos=$(printf '%s\n%s' "$repos" "$page")
              [ "$(printf '%s\n' "$page" | wc -l)" -ge 100 ] || break
              p=$((p + 1))
            done
          fi
          ;;
        *) echo "tart-runner-poll: bad TR_SCOPE_TYPE '$TR_SCOPE_TYPE'" >&2; exit 1 ;;
      esac

      while read -r repo; do
        [ -n "$repo" ] || continue
        if [ "$TR_SCOPE_TYPE" = org ]; then
          case "$repo" in "$TR_SCOPE"/*) ;; *) continue ;; esac
        fi
        for st in queued in_progress; do
          # in_progress matters as much as queued: a fan-out or a `needs:`
          # stage leaves the RUN in progress while its next job sits queued,
          # and watching only status=queued would never boot a guest for it.
          runs=$(gh_curl "$tok" "https://api.github.com/repos/$repo/actions/runs?status=$st&per_page=50" \
            | jq -r '.workflow_runs[].id' || true)
          [ -n "$runs" ] || continue
          while read -r run; do
            [ -n "$run" ] || continue
            if gh_curl "$tok" "https://api.github.com/repos/$repo/actions/runs/$run/jobs?filter=latest&per_page=100" \
              | jq -e --argjson mine "$mine" '
                  [ .jobs[]
                    | select(.status == "queued")
                    | select((.labels | length) > 0)
                    | select(((.labels | map(ascii_downcase)) - $mine) | length == 0)
                  ] | length > 0' >/dev/null 2>&1; then
              echo "tart-runner-poll: queued job for [$TR_LABELS] in $repo run $run" >&2
              exit 0
            fi
          done <<< "$runs"
        done
      done <<< "$repos"

      exit 3
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
      api
      poll
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
      # A first pull of a Cirrus macOS runner image is HUNDREDS of GB, not the
      # "tens" earlier revisions of this comment claimed: macos-runner:tahoe
      # measured 222 GB on 2026-09-06 (`tart list` Size column), and consumed
      # ~138 GB of free space while staging into ~/.tart/tmp before dedup.
      # Hours on a home link, against the ~180s a pin boot costs — which is why
      # the pull deliberately holds NO slot. Bounded so a wedged pull cannot
      # hold the loop forever; 4h is generous for a warm link and tight for a
      # cold one, so raise TR_PULL_TIMEOUT rather than assume it is enough.
      TR_PULL_TIMEOUT="''${TR_PULL_TIMEOUT:-14400}"
      # Slot-wait ceiling (tart-slots.sh). GitHub is the FORGIVING lane: with no
      # runner registered a queued job simply waits at the forge — free, for up
      # to 24h — so a timeout here costs nothing but a loop iteration, and the
      # loop is worth returning to (it reaps orphans and re-checks base/pin).
      # 30 min is long enough to ride out a sibling lane's whole job and short
      # enough that a wedged slot marker cannot pin this controller for a day.
      # The GitLab lane deliberately uses a far smaller value; see
      # packages/gitlab-tart.nix.
      TR_SLOT_WAIT="''${TR_SLOT_WAIT:-1800}"
      # HOST-SIDE POLL INTERVAL, and the trade it buys.
      # Idle now costs ~2 HTTPS requests per watched repo per interval and ZERO
      # guests — where the pre-2026-09-06 shape kept an 8 GB guest booted per
      # lane, long-polling from inside, whether or not any job existed. The
      # price is first-job latency: the queued job waits up to one interval to
      # be noticed, then ~1-3 min for clone + boot (TR_BOOT_TIMEOUT is 180s,
      # plus the SSH-readiness probe). So roughly 1-4 minutes before a job
      # starts, versus seconds when a warm guest was already listening.
      #
      # That is the RIGHT trade for THESE lanes: a handful of jobs a day, on a
      # laptop where 8 GB per idle lane and one of only two guest slots are the
      # scarce resources, and where GitHub holds a queued job for free for 24h.
      # It would be the WRONG trade for a latency-critical lane (interactive
      # deploys, a PR gate someone watches) or a continuously-busy one — there
      # the guest is never idle, so the memory is not wasted, and a warm
      # listener is strictly better. Do not copy this default into such a lane;
      # lower TR_POLL_INTERVAL there, or keep a warm runner.
      TR_POLL_INTERVAL="''${TR_POLL_INTERVAL:-60}"
      # A JIT runner that loses the race for its job would otherwise sit at
      # "Listening for Jobs" forever, holding the slot this whole change exists
      # to free. Two lanes can see the same queued job in the same breath, and
      # a job can be cancelled between the poll and the boot, so this is a
      # normal outcome, not an error path. 5 min is far longer than a
      # dispatch takes once a runner is online.
      TR_JOB_GRACE="''${TR_JOB_GRACE:-300}"
      # Backstop only — deliberately at GitHub's own 6h job ceiling so this
      # timer can never pre-empt a legitimate job. It exists to catch a wedged
      # guest, not to bound job runtime.
      TR_JOB_TIMEOUT="''${TR_JOB_TIMEOUT:-21600}"

      log() { echo "[$(date -u +%FT%TZ)] [$TR_NAME] $*" >&2; }

      # --- slot semaphore: the shared library (tart-slots.sh) — one protocol
      # with the GitLab shims. Waits at most TR_SLOT_WAIT for a slot and then
      # REFUSES (non-zero); on this lane a refusal is cheap, because GitHub
      # simply keeps the job queued while no runner is registered.
      # shellcheck disable=SC1091
      source ${slotsLib}

      # --- the ONE way this controller talks to a guest. Defined once so the
      # readiness probe and the real job session cannot drift apart: the probe
      # only proves something if it uses byte-identical flags.
      #
      # `-F /dev/null` is load-bearing, not tidiness. Without it ssh reads the
      # OPERATOR's ~/.ssh/config, and this ssh is nixpkgs' OpenSSH, not Apple's.
      # `UseKeychain` is an Apple-only patch, so a perfectly valid personal
      # config killed every guest session before a job could run (2026-09-06):
      #
      #   /Users/…/.ssh/config: line 23: Bad configuration option: usekeychain
      #   guest session rc=255 (job failure or ssh drop)
      #
      # The guest connection is machine-to-machine and fully specified here; it
      # must inherit nothing from the login user. Credentials stay in the env
      # (never argv beyond sshpass's own flag) and the host key is pinned —
      # fail-closed, never StrictHostKeyChecking=no.
      guest_ssh() {
        local host="$1"; shift
        sshpass -p "$TR_VM_PASS" ssh \
          -F /dev/null \
          -o UserKnownHostsFile="$TR_KNOWN_HOSTS" \
          -o StrictHostKeyChecking=yes \
          -o PreferredAuthentications=password \
          -o PubkeyAuthentication=no \
          -o IdentityAgent=none \
          -o ConnectTimeout=10 \
          "$TR_VM_USER@$host" "$@"
      }

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
      # at ~222 GB each (macos-runner:tahoe, measured 2026-09-06). TR_LIVE_BASES is the set EVERY enabled instance on
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
            if slot_acquire_pid; then
              tart-runner-setup pin || log "re-pin FAILED ($TR_OCI_IMAGE@$TR_OCI_DIGEST)"
              slot_release
            else
              # No slot, so no pin: `tart-runner-setup pin` boots a REAL
              # throwaway guest, and running it unslotted would be a third
              # macOS guest. Nothing is registered at the forge at this point,
              # so deferring costs nothing — fall through to the backoff below
              # and try again on the next cycle.
              log "SLOT-WAIT-TIMEOUT after ''${TR_SLOT_WAIT}s — re-pin deferred, all $TR_SLOTS_MAX guest slots busy"
            fi
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

      # --- the installation token: two HTTPS round-trips, valid ~1h, and the
      # credential BOTH the poll and the JIT mint need. Cached in-process and
      # refreshed at 45 min so a 60s poll does not re-mint it 60 times an hour.
      INSTALL_TOKEN=""
      INSTALL_TOKEN_AT=0
      refresh_install_token() {
        local now
        now=$(date +%s)
        if [ -n "$INSTALL_TOKEN" ] && [ $((now - INSTALL_TOKEN_AT)) -lt 2700 ]; then return 0; fi
        INSTALL_TOKEN=$(tart-runner-api install-token) || { INSTALL_TOKEN=""; return 1; }
        [ -n "$INSTALL_TOKEN" ] || return 1
        INSTALL_TOKEN_AT="$now"
        return 0
      }

      run_one_job() {
        local vm uuid run_pid="" ssh_pid="" rc=0 cloned=0 runner_id="" jit="" blob="" started=0
        uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
        vm="run-$TR_NAME-$uuid"
        # Tear down only what was actually created. The RETURN trap fires on
        # EVERY early return (slot-wait timeout, mint failure — neither of
        # which has cloned anything), and an unconditional `tart delete` on a
        # never-cloned VM emits a bogus "possible leaked clone" — the red
        # herring that sat next to the real 2026-09-05 cause in the log.
        cleanup() {
          if [ "$cloned" = 1 ]; then
            "$TART" stop "$vm" >/dev/null 2>&1 || true
          fi
          # Killing the ssh client is best-effort; what actually ends the
          # session is the guest going away one line below.
          if [ -n "$ssh_pid" ]; then
            kill "$ssh_pid" >/dev/null 2>&1 || true
            wait "$ssh_pid" 2>/dev/null || true
          fi
          if [ -n "$run_pid" ]; then
            kill "$run_pid" >/dev/null 2>&1 || true
            wait "$run_pid" 2>/dev/null || true
          fi
          if [ "$cloned" = 1 ]; then
            "$TART" delete "$vm" >/dev/null 2>&1 || log "WARNING: delete $vm failed — possible leaked clone"
          fi
          # A JIT registration OUTLIVES the guest it was minted for: GitHub
          # only garbage-collects an unconnected ephemeral runner after a day.
          # An ephemeral runner that finished its job has already deregistered
          # itself, so this 404s and is a no-op; one that never got work, or
          # whose guest we tore down, is removed here instead of lingering as
          # a phantom "offline" runner the next job could be dispatched to.
          if [ -n "$runner_id" ]; then
            printf '%s' "$INSTALL_TOKEN" | tart-runner-api runner-delete "$runner_id" >/dev/null 2>&1 \
              && log "deregistered runner $runner_id" || true
          fi
          slot_release
        }
        trap cleanup RETURN

        # ORDER IS LOAD-BEARING: work is already known to exist (the caller
        # only reaches here when tart-runner-poll said so, and that poll boots
        # nothing and creates nothing at the forge). Slot SECOND, JIT mint
        # THIRD — because the mint is the step that actually CREATES a runner
        # at GitHub. Minting before the slot would leave a registered runner
        # behind on a slot-wait timeout: GitHub would happily dispatch the job
        # to a runner that no guest will ever answer for, and the job would
        # burn its own timeout instead of waiting for real capacity.
        if ! slot_acquire_pid; then
          log "SLOT-WAIT-TIMEOUT after ''${TR_SLOT_WAIT}s: all $TR_SLOTS_MAX guest slots busy — nothing minted, nothing registered, job stays queued at GitHub"
          return 1
        fi

        jit=$(printf '%s' "$INSTALL_TOKEN" | tart-runner-api jitconfig "$TR_NAME-$uuid") \
          || { log "JIT config mint failed"; return 1; }
        runner_id=$(printf '%s\n' "$jit" | head -n 1)
        blob=$(printf '%s\n' "$jit" | tail -n 1)
        [ -n "$runner_id" ] && [ -n "$blob" ] || { log "empty JIT config"; return 1; }

        log "slot acquired; clone $TR_BASE_IMAGE -> $vm"
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

        # AN IP IS NOT READINESS. macOS answers on :22 while opendirectoryd is
        # still starting, so a CORRECT password is rejected for the first few
        # seconds. Observed 2026-09-06: a guest contacted 3s after its IP
        # appeared returned
        #
        #   Permission denied, please try again.
        #   admin@…: Permission denied (publickey,password,keyboard-interactive).
        #
        # while sibling lanes a few seconds slower reached "Listening for Jobs".
        # Treating that refusal as a job failure throws away a whole clone+boot
        # cycle and the slot it held, for a guest that was about to be fine.
        local ready=0 probed=0
        while [ "$probed" -lt "$TR_BOOT_TIMEOUT" ]; do
          if guest_ssh "$ip" true >/dev/null 2>&1; then ready=1; break; fi
          sleep 5
          probed=$((probed + 5))
        done
        [ "$ready" = 1 ] || { log "guest at $ip never accepted ssh within ''${TR_BOOT_TIMEOUT}s"; return 1; }

        log "guest up at $ip; JIT runner $TR_NAME-$uuid (id $runner_id) — one job, then the guest dies"

        # Secrets ride stdin, never argv — on the host side (the blob reaches
        # ssh through a pipe) and inside the guest (the runner reads
        # ACTIONS_RUNNER_INPUT_JITCONFIG from its environment and SCRUBS it
        # from the process env before spawning Runner.Worker, whereas
        # `--jitconfig <blob>` would be visible in the guest's own `ps`).
        #
        # Runner.Listener is invoked DIRECTLY, not through run.sh: run.sh
        # wraps it in a `while :;` restart loop, which is exactly wrong for a
        # one-shot ephemeral runner. `run` is mandatory — without it the
        # process writes its config files, prints a usage banner and exits 0.
        # No --ephemeral / --disableupdate flags: a JIT registration is forced
        # Ephemeral=True and DisableUpdate=True server-side.
        {
          printf 'export ACTIONS_RUNNER_INPUT_JITCONFIG=%q RUNNER_DIR=%q\n' "$blob" "$TR_RUNNER_DIR"
          cat <<'GUEST'
      set -euo pipefail
      export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
      cd "$RUNNER_DIR"
      exec ./bin/Runner.Listener run
      GUEST
        } | guest_ssh "$ip" 'bash -s' &
        ssh_pid=$!

        # Watchdog. Only two things end this: the runner finishes its one job
        # (Runner.Listener exits, the ssh session closes), or a timer fires.
        # `busy` on the runner itself is the dispatch signal — no log scraping,
        # and it stops being polled the moment work starts.
        local waited_job=0
        while kill -0 "$ssh_pid" 2>/dev/null; do
          if [ "$started" = 0 ] \
            && printf '%s' "$INSTALL_TOKEN" | tart-runner-api runner-busy "$runner_id" >/dev/null 2>&1; then
            started=1
            log "runner $runner_id picked up a job"
          fi
          if [ "$started" = 0 ] && [ "$waited_job" -ge "$TR_JOB_GRACE" ]; then
            log "IDLE-GUEST-TIMEOUT: runner $runner_id got no job within ''${TR_JOB_GRACE}s (a sibling lane most likely won it) — releasing the guest and its slot"
            return 1
          fi
          if [ "$waited_job" -ge "$TR_JOB_TIMEOUT" ]; then
            log "JOB-TIMEOUT after ''${TR_JOB_TIMEOUT}s — releasing the guest and its slot"
            return 1
          fi
          sleep 10
          waited_job=$((waited_job + 10))
        done
        if wait "$ssh_pid"; then rc=0; else rc=$?; fi
        ssh_pid=""
        [ "$rc" -eq 0 ] || log "guest session rc=$rc (job failure or ssh drop)"
        return "$rc"
      }

      case "''${TR_SCOPE_TYPE:?}" in
        org | repo) ;;
        *) log "bad TR_SCOPE_TYPE"; exit 1 ;;
      esac
      mkdir -p "$TR_SLOTS_DIR"
      reap_own_orphans
      log "controller up (scope=$TR_SCOPE_TYPE:$TR_SCOPE slots<=$TR_SLOTS_MAX poll=''${TR_POLL_INTERVAL}s setup_owner=''${TR_SETUP_OWNER:-0})"
      while :; do
        # Pre-flight OUTSIDE run_one_job: no trap armed, no slot held, so a
        # missing base/pin costs neither a bogus teardown warning nor one of
        # the two guests the other CI lane also draws from.
        ensure_image || continue
        if ! refresh_install_token; then
          log "installation token mint failed — retrying in ''${TR_POLL_INTERVAL}s"
          sleep "$TR_POLL_INTERVAL"
          continue
        fi
        # NO guest is booted speculatively. This is the whole point of the
        # 2026-09-06 change: the wait for work is these two HTTPS calls on the
        # host, not an 8 GB macOS guest long-polling from inside a slot.
        printf '%s' "$INSTALL_TOKEN" | tart-runner-poll
        prc=$?
        case "$prc" in
          0) run_one_job ;;
          3) : ;;
          *) log "queued-work poll failed (rc=$prc)" ;;
        esac
        sleep "$TR_POLL_INTERVAL"
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

      # A digest-pinned reference is `repo@sha256:…` with NO tag. Appending the
      # digest to a TAGGED image instead — `…/macos-runner:tahoe@sha256:…`, which
      # is what TR_OCI_IMAGE carries — is rejected by tart's own parser before a
      # byte is fetched:
      #
      #   failed to parse remote name: mismatched input '@' expecting
      #   {<EOF>, '.', '-', '_', DIGIT, LETTER} (character 38)
      #
      # (character 38 is exactly the '@'.) Docker tolerates tag+digest; tart,
      # containerd and the OCI grammar do not. This is why the 2026-09-05 digest
      # bump left the host with no base image and no pin: EVERY pull, manual or
      # automatic, failed instantly at parse. Verified against tart 2.36.0 —
      # the tag-stripped form reaches "pulling manifest" and only then 404s on a
      # deliberately bogus digest.
      #
      # Strip only a tag in the LAST path segment: a registry may carry a port
      # (`registry.example.com:5000/repo`), and `''${ref%:*}` alone would eat it.
      ociRef="$TR_OCI_IMAGE"
      case "''${ociRef##*/}" in *:*) ociRef="''${ociRef%:*}" ;; esac
      pinnedRef="$ociRef@$TR_OCI_DIGEST"

      if [ "$stage" != pin ] && ! "$TART" list --quiet 2>/dev/null | grep -qx "$TR_BASE_IMAGE"; then
        echo "pulling $pinnedRef" >&2
        "$TART" pull "$pinnedRef"
        "$TART" clone "$pinnedRef" "$TR_BASE_IMAGE"
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
        # `tart stop` returns before the guest has actually gone, and `tart
        # delete` REFUSES a running VM — so the old stop-then-delete-then-|| true
        # swallowed the failure and leaked a RUNNING pin guest. That is worse
        # than a stray disk clone: it silently consumes one of Apple's two
        # concurrent macOS guests, which the slot semaphore cannot see (the pin
        # holds no slot marker of its own), so the next lane's boot fails inside
        # Virtualization.framework instead of queueing. Observed 2026-09-06.
        # Wait for the state to actually leave `running` before deleting.
        "$TART" stop "$pin" >/dev/null 2>&1 || true
        kill "$rp" 2>/dev/null || true; wait "$rp" 2>/dev/null || true
        gone=0
        for _ in $(seq 1 30); do
          "$TART" list --quiet 2>/dev/null | grep -qx "$pin" || { gone=1; break; }
          "$TART" delete "$pin" >/dev/null 2>&1 && { gone=1; break; }
          sleep 2
        done
        [ "$gone" = 1 ] || echo "WARNING: pin guest $pin still present — it consumes one of Apple's two guests" >&2
        [ -s "$TR_KNOWN_HOSTS" ] || { echo "host-key pin FAILED" >&2; exit 1; }
      fi
      echo "setup ok: base=$TR_BASE_IMAGE pin=$TR_KNOWN_HOSTS" >&2
    '';
  };
in
{
  inherit
    controller
    api
    poll
    setup
    ;
}
