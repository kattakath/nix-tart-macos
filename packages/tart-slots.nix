# The host-wide VM-slot semaphore, as a sourceable shell library — the SINGLE
# protocol every VM-spawning CI system on the host speaks (GitHub tart.runners
# controllers, the GitLab executor shims). Apple's Virtualization framework
# refuses a third concurrent macOS guest; this is where that budget is shared.
#
# Why not `/usr/bin/lockf` — the off-the-shelf answer, and the one that DELETED
# this exact mkdir + pid-file + `kill -0` + stale-reclaim shape over in
# nix-media-cli (packages/media-queue.nix:396-405: "THE LOCK IS THE KERNEL'S,
# NOT OURS … that makes a stale lock structurally impossible"). lockf takes a
# `flock(2)`, whose entire guarantee is that the kernel drops the lock when the
# holder dies — and the `vm` marker below must OUTLIVE its acquiring process,
# because GitLab's prepare stage exits while the guest it booted lives on.
# Nor does splitting it help: flock for `pid` + mkdir for `vm` would be two
# separate accountings of ONE hard 2-guest budget, which is the single thing
# this file exists to prevent.
#
# Protocol: TR_SLOTS_DIR holds slot-N dirs, created with atomic mkdir. Each
# slot carries ONE ownership marker:
#   pid  — a long-lived controller process; stale when the pid is dead.
#   vm   — a specific VM name (e.g. gitlab-<job-id>) whose spawning process
#          exits before the VM does (GitLab's prepare stage); stale when
#          `tart list` no longer shows the VM.
# Callers: slot_acquire_pid | slot_acquire_vm <name> (both wait for a slot, but
# for at most TR_SLOT_WAIT seconds — see _slot_acquire — and return NON-ZERO on
# expiry), then slot_release, or slot_release_vm <name> from a different
# process (cleanup).
# Requires: TR_SLOTS_DIR TR_SLOTS_MAX TART (tart binary path) in scope.
# Optional: TR_SLOT_WAIT (seconds; each lane sets its own default).
{ writeText }:
writeText "tart-slots.sh" ''
  _slot_stale() {
    if [ -f "$1/vm" ]; then
      local vm
      vm=$(cat "$1/vm" 2>/dev/null || true)
      [ -n "$vm" ] || return 0
      "$TART" list --quiet 2>/dev/null | grep -qx "$vm" && return 1 || return 0
    fi
    local pid
    pid=$(cat "$1/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    return 0
  }

  # Retire a slot directory the only safe way: rename FIRST, delete after. Two
  # acquirers can judge the same slot stale in the same breath, and a bare
  # `rm -rf "$d"` then lets the loser delete the slot the winner has already
  # reclaimed and legitimately re-mkdir'ed — two holders for one slot, which
  # over-subscribes the very 2-guest budget this file exists to enforce.
  # rename(2) is atomic, so exactly one racer's `mv` can win; the loser's fails
  # and it just looks again on the next pass. Never `rm -rf` a live path.
  # Always returns 0: callers run under `set -euo pipefail`, and a lost race is
  # ordinary, not an error. A crash between the two lines leaves an inert
  # `slot-N.stale.<pid>` — the protocol only ever addresses `slot-$i`, so
  # nothing can mistake it for a slot.
  _slot_discard() {
    mv "$1" "$1.stale.$$" 2>/dev/null && rm -rf "$1.stale.$$"
    return 0
  }

  # BOUNDED wait — this loop used to be `while :; … sleep 10`, i.e. block
  # forever. Measured 2026-09-06 on the GitLab lane: the shim that acquires runs
  # in the executor's *prepare* stage, which the coordinator starts only AFTER
  # it has already assigned the job — so every second spent here is charged to
  # that job's own timeout while GitLab believes the job is running. An
  # unbounded wait therefore converts "the host's two guests are busy" into
  # silent starvation instead of a visible refusal, and the operator sees a job
  # that timed out with no logs rather than one that was told "no capacity".
  #
  # TR_SLOT_WAIT is the ceiling in seconds. It has NO single right value, so
  # each lane sets its own default at the call site (GitHub waits long — its
  # jobs sit queued at the forge for free; GitLab fails fast so the job returns
  # to `pending`); 900 here is only the floor-level fallback for a caller that
  # sets nothing. 0 means "one pass, never sleep".
  #
  # On expiry: returns 1 with SLOT_DIR UNTOUCHED. No slot is held, so the caller
  # must neither slot_release nor go on to boot a guest — doing so would exceed
  # Apple's hard 2-guest cap and fail inside Virtualization.framework mid-job,
  # which is the exact failure this whole file exists to prevent.
  _slot_acquire() { # $1 = marker filename, $2 = marker content
    mkdir -p "$TR_SLOTS_DIR"
    local waited=0 limit="''${TR_SLOT_WAIT:-900}" step=10
    while :; do
      local i d
      for i in $(seq 1 "$TR_SLOTS_MAX"); do
        d="$TR_SLOTS_DIR/slot-$i"
        if mkdir "$d" 2>/dev/null; then
          printf '%s' "$2" > "$d/$1"
          SLOT_DIR="$d"
          return 0
        fi
        if _slot_stale "$d"; then
          echo "tart-slots: reclaiming stale slot $i" >&2
          _slot_discard "$d"
        fi
      done
      if [ "$waited" -ge "$limit" ]; then
        echo "tart-slots: SLOT-WAIT-TIMEOUT after ''${waited}s (all $TR_SLOTS_MAX guest slots busy)" >&2
        return 1
      fi
      # Never overshoot the ceiling: the last nap is the remainder, so a caller
      # asking for 5s does not actually wait 10.
      [ $((limit - waited)) -ge "$step" ] || step=$((limit - waited))
      sleep "$step"
      waited=$((waited + step))
    done
  }

  slot_acquire_pid() { _slot_acquire pid "$$"; }
  slot_acquire_vm() { _slot_acquire vm "$1"; }

  slot_release() {
    if [ -n "''${SLOT_DIR:-}" ]; then _slot_discard "$SLOT_DIR"; SLOT_DIR=""; fi
  }

  slot_release_vm() { # release the slot holding this vm marker, from ANY process
    local i d
    for i in $(seq 1 "$TR_SLOTS_MAX"); do
      d="$TR_SLOTS_DIR/slot-$i"
      if [ "$(cat "$d/vm" 2>/dev/null || true)" = "$1" ]; then
        # Same check-then-delete shape as the reclaim above, and the same
        # hazard: between the `cat` and the delete this slot can be reclaimed
        # and handed to another job.
        _slot_discard "$d"
        return 0
      fi
    done
    return 0
  }
''
