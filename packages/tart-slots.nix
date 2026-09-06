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
# Callers: slot_acquire_pid | slot_acquire_vm <name> (both BLOCK until a slot
# frees; GitHub queues jobs and GitLab holds prepare meanwhile), then
# slot_release, or slot_release_vm <name> from a different process (cleanup).
# Requires: TR_SLOTS_DIR TR_SLOTS_MAX TART (tart binary path) in scope.
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

  _slot_acquire() { # $1 = marker filename, $2 = marker content
    mkdir -p "$TR_SLOTS_DIR"
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
          rm -rf "$d"
        fi
      done
      sleep 10
    done
  }

  slot_acquire_pid() { _slot_acquire pid "$$"; }
  slot_acquire_vm() { _slot_acquire vm "$1"; }

  slot_release() {
    if [ -n "''${SLOT_DIR:-}" ]; then rm -rf "$SLOT_DIR"; SLOT_DIR=""; fi
  }

  slot_release_vm() { # release the slot holding this vm marker, from ANY process
    local i d
    for i in $(seq 1 "$TR_SLOTS_MAX"); do
      d="$TR_SLOTS_DIR/slot-$i"
      if [ "$(cat "$d/vm" 2>/dev/null || true)" = "$1" ]; then
        rm -rf "$d"
        return 0
      fi
    done
    return 0
  }
''
