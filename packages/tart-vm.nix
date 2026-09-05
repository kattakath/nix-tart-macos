# tart-vm — declarative lifecycle + plug-and-play provisioning for Tart macOS
# guest VMs on Apple Silicon (host-side CLI).
#
#   tart-vm create|pull|bake|start|stop|ip|ssh|list|doctor|bootstrap <vm> [flags]
#
# Design principle: the IMAGE is operator-neutral (a generic `admin`/`admin`
# setup user with SSH on — either pulled from a registry by digest, or baked
# locally from an Apple IPSW with the vendored Packer template), and IDENTITY
# is injected at `tart-vm bootstrap` time (your login user, your flake, your
# key). Disks and IPSWs never enter the Nix store — they live under
# ~/.tart/vms/<name>.
#
# Env overrides:
#   TART_VM_DISK_GB / TART_VM_CPUS / TART_VM_MEMORY_MB — create defaults
#   TART_VM_DOWNLOADS  — host dir shared into the guest (default ~/Downloads)
#   TART_VM_LOG_DIR    — detached-run log dir (default ~/Library/Logs)
#   TART_VM_SSH_IDENTITY / TART_VM_IP_WAIT — ssh key + ip-wait seconds
{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  openssh,
  sshpass,
  curl,
  tart,
  packer,
  packer-plugin-tart,
  # Path to the vendored Packer template used by `tart-vm bake` when --template
  # is not given. Override via callPackage to bake a different macOS release.
  defaultTemplate ? ../templates/vanilla-tahoe.pkr.hcl,
}:
let
  tartBin = lib.getExe tart;
  # getExe' — nixpkgs' packer does not set meta.mainProgram.
  packerBin = lib.getExe' packer "packer";
in
writeShellApplication {
  name = "tart-vm";
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    gnused
    openssh
    sshpass
    curl
  ];
  # SC2029: every `ssh host "cmd $var"` below expands client-side ON PURPOSE —
  # the whole point of bootstrap is composing remote commands from local state.
  excludeShellChecks = [ "SC2029" ];
  text = ''
    TART="${tartBin}"
    PACKER="${packerBin}"
    PACKER_PLUGINS="${packer-plugin-tart}/libexec/packer/plugins"
    DEFAULT_TEMPLATE="${defaultTemplate}"

    DOWNLOADS="''${TART_VM_DOWNLOADS:-$HOME/Downloads}"
    LOG_DIR="''${TART_VM_LOG_DIR:-$HOME/Library/Logs}"

    VM=""

    die() { echo "tart-vm: $*" >&2; exit 1; }
    info() { echo "tart-vm: $*" >&2; }

    usage() {
      cat <<'EOF'
    tart-vm — declarative lifecycle + plug-and-play provisioning for Tart macOS VMs

    usage: tart-vm <subcommand> [<vm-name> | --vm NAME] [flags]

    subcommands:
      create     create a VM from an Apple IPSW   [--ipsw PATH|latest] [--disk-gb N]
                 [--cpus N] [--memory-mb N] [--force]
      pull       clone a REGISTRY image, digest-pinned:
                 --image ghcr.io/... --digest sha256:...   [--force]
      bake       bake a generic golden image locally with Packer
                 [--template PATH] [--force]   (default: vendored vanilla template)
      start      start detached, share a host dir, wait for the IP
                 [--no-share] [--dir NAME:PATH ...]
      stop       stop the VM
      ip         print the guest IP               [--wait SECS]
      ssh        ssh into the guest               [--user U] [--wait SECS] [-- ssh args]
      list       tart list passthrough
      doctor     exit-coded health checks
      bootstrap  personalize a generic image over SSH:
                 --user LOGIN --fullname "Full Name" --flake github:owner/repo#host
                 [--admin-user admin] [--admin-pass admin]
                 [--authorized-key "ssh-ed25519 ..."] [--drop-admin]
                 [--force-activate] [--no-activate]

    env: TART_VM_DISK_GB TART_VM_CPUS TART_VM_MEMORY_MB TART_VM_DOWNLOADS
         TART_VM_LOG_DIR TART_VM_SSH_IDENTITY TART_VM_IP_WAIT
    EOF
    }

    require_tart() {
      [ -x "$TART" ] || die "tart not found at $TART"
    }

    require_vm() {
      [ -n "$VM" ] || die "no VM name — pass it as the first argument or --vm NAME"
    }

    vm_exists() {
      require_tart
      # --quiet: one name per line (no header/columns).
      "$TART" list --quiet 2>/dev/null | grep -qx "$VM"
    }

    # Prefer tart list state — tart ip can still resolve after stop (stale DHCP).
    vm_running() {
      require_tart
      "$TART" list 2>/dev/null | /usr/bin/awk -v n="$VM" '
        NR>1 && $2==n {
          st=tolower($NF)
          exit (st=="running" || st=="suspended") ? 0 : 1
        }
        END { if (NR==0) exit 1 }
      '
    }

    guest_ip() {
      require_tart
      local wait="''${1:-0}"
      "$TART" ip "$VM" --wait "$wait" 2>/dev/null || true
    }

    # 32 hex chars from /dev/urandom. od reads a FIXED byte count, so the
    # pipeline terminates cleanly under `set -o pipefail` (no SIGPIPE race).
    random_password() {
      od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    }

    # Take the VM name from --vm (anywhere) or from a LEADING bare argument;
    # everything else is handed back to the subcommand via REST. A bare token
    # after the first flag is never the VM name — it could be a flag's value.
    REST=()
    parse_vm_and_rest() {
      while [ $# -gt 0 ]; do
        case "$1" in
          --vm) VM="''${2:?--vm needs a value}"; shift 2 ;;
          --) shift; REST+=("$@"); break ;;
          -*) REST+=("$1"); shift ;;
          *)
            if [ -z "$VM" ] && [ "''${#REST[@]}" -eq 0 ]; then
              VM="$1"
            else
              REST+=("$1")
            fi
            shift
            ;;
        esac
      done
    }

    # ---------------------------------------------------------------- create --
    cmd_create() {
      require_tart
      require_vm
      local ipsw="latest" force=0
      local disk_gb="''${TART_VM_DISK_GB:-80}"
      local cpus="''${TART_VM_CPUS:-4}"
      local memory_mb="''${TART_VM_MEMORY_MB:-8192}"
      set -- "''${REST[@]+"''${REST[@]}"}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --ipsw) ipsw="''${2:?}"; shift 2 ;;
          --disk-gb) disk_gb="''${2:?}"; shift 2 ;;
          --cpus) cpus="''${2:?}"; shift 2 ;;
          --memory-mb) memory_mb="''${2:?}"; shift 2 ;;
          --force) force=1; shift ;;
          *) die "create: unknown arg: $1" ;;
        esac
      done

      if vm_exists; then
        if [ "$force" -eq 0 ]; then
          die "VM '$VM' already exists. --force deletes + recreates."
        fi
        info "deleting existing $VM (--force)"
        "$TART" stop "$VM" 2>/dev/null || true
        "$TART" delete "$VM"
      fi

      info "creating $VM from IPSW=$ipsw disk=''${disk_gb}G (disk lives under ~/.tart, not the Nix store)"
      "$TART" create --from-ipsw="$ipsw" --disk-size "$disk_gb" "$VM"
      "$TART" set "$VM" --cpu "$cpus" --memory "$memory_mb"
      info "created. Next: tart-vm start $VM  (finish Setup Assistant in the Tart window)"
      info "or skip manual setup entirely: tart-vm bake / tart-vm pull + tart-vm bootstrap"
    }

    # ------------------------------------------------------------------ pull --
    cmd_pull() {
      require_tart
      require_vm
      local image="" digest="" force=0
      set -- "''${REST[@]+"''${REST[@]}"}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --image) image="''${2:?}"; shift 2 ;;
          --digest) digest="''${2:?}"; shift 2 ;;
          --force) force=1; shift ;;
          *) die "pull: unknown arg: $1" ;;
        esac
      done
      [ -n "$image" ] || die "pull: --image ghcr.io/... is required"

      # A moving tag (":latest" or any other) is a TRUST decision made for you
      # by whoever controls the registry, whenever they like. Refuse it: a pull
      # must be digest-pinned so the image you provision today is byte-for-byte
      # the image you audited.
      if [ -z "$digest" ]; then
        die "pull: --digest sha256:... is REQUIRED. Refusing a bare tag (even ':latest'):
      a moving tag can be repointed at any time by the registry owner, so what you
      pull tomorrow need not be what you inspected today. Resolve the digest once
      (e.g. \`crane digest <image>:<tag>\`, or the registry UI) and pin it."
      fi
      case "$digest" in
        sha256:*) : ;;
        *) die "pull: --digest must look like sha256:<64 hex chars>" ;;
      esac

      # Strip any tag; the digest is the pin.
      local repo="''${image%%@*}"
      case "$repo" in
        */*:*) repo="''${repo%:*}" ;;
      esac

      if vm_exists; then
        if [ "$force" -eq 0 ]; then
          die "VM '$VM' already exists. --force deletes + re-clones."
        fi
        info "deleting existing $VM (--force)"
        "$TART" stop "$VM" 2>/dev/null || true
        "$TART" delete "$VM"
      fi

      info "cloning $repo@$digest -> $VM"
      "$TART" clone "$repo@$digest" "$VM"
      info "pulled. Next: tart-vm start $VM && tart-vm bootstrap $VM --user ... --flake ..."
    }

    # ------------------------------------------------------------------ bake --
    cmd_bake() {
      require_tart
      local template="$DEFAULT_TEMPLATE" force=0
      set -- "''${REST[@]+"''${REST[@]}"}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --template) template="''${2:?}"; shift 2 ;;
          --force) force=1; shift ;;
          *) die "bake: unknown arg: $1" ;;
        esac
      done
      [ -r "$template" ] || die "bake: template not readable: $template"

      # The vendored template hardcodes its own vm_name; bake into that, then
      # rename to the requested VM name (if one was given and differs).
      local built
      built="$(sed -n 's/^[[:space:]]*vm_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$template" | head -n1)"
      [ -n "$built" ] || die "bake: could not find vm_name in $template"

      local target="''${VM:-$built}"
      local n
      for n in "$built" "$target"; do
        VM="$n"
        if vm_exists; then
          if [ "$force" -eq 0 ]; then
            die "VM '$n' already exists. --force deletes it before baking."
          fi
          info "deleting existing $n (--force)"
          "$TART" stop "$n" 2>/dev/null || true
          "$TART" delete "$n"
        fi
      done
      VM="$target"

      info "baking golden image with Packer (template: $template)"
      info "this boots Setup Assistant and types through it — takes a while, do not interfere with the VM window"
      CHECKPOINT_DISABLE=1 PACKER_PLUGIN_PATH="$PACKER_PLUGINS" \
        "$PACKER" build "$template"

      if [ "$target" != "$built" ]; then
        "$TART" rename "$built" "$target"
        info "renamed $built -> $target"
      fi
      info "baked. Generic image ready (setup user admin/admin, SSH on)."
      info "Next: tart-vm start $target && tart-vm bootstrap $target --user ... --flake ..."
    }

    # ----------------------------------------------------------------- start --
    cmd_start() {
      require_tart
      require_vm
      vm_exists || die "no VM '$VM' — tart-vm create/pull/bake first"
      local no_share=0
      local extra_dirs=()
      set -- "''${REST[@]+"''${REST[@]}"}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --no-share) no_share=1; shift ;;
          --dir) extra_dirs+=("--dir=''${2:?}"); shift 2 ;;
          *) die "start: unknown arg: $1" ;;
        esac
      done

      if vm_running; then
        info "already running"
        local ip
        ip=$(guest_ip 5 || true)
        echo "ip=''${ip:-pending}"
        return 0
      fi

      mkdir -p "$LOG_DIR"
      local run_log="$LOG_DIR/tart-vm-$VM.log"
      local args=()
      if [ "$no_share" -eq 0 ]; then
        # Guest mount: /Volumes/My Shared Files/Downloads (VirtioFS automount).
        mkdir -p "$DOWNLOADS"
        args+=("--dir=Downloads:$DOWNLOADS")
      fi
      args+=("''${extra_dirs[@]+"''${extra_dirs[@]}"}")

      info "starting $VM — log: $run_log"
      # tart run is long-lived (owns the VM window); detach so this CLI returns.
      nohup "$TART" run "''${args[@]+"''${args[@]}"}" "$VM" >>"$run_log" 2>&1 &
      echo $! >"$LOG_DIR/tart-vm-$VM.pid"
      info "waiting for DHCP IP (up to 180s)…"
      local ip
      ip=$(guest_ip 180 || true)
      if [ -n "''${ip:-}" ]; then
        echo "ip=$ip"
      else
        info "IP not ready yet — check the Tart window / $run_log; later: tart-vm ip $VM"
      fi
    }

    # ------------------------------------------------------------------ stop --
    cmd_stop() {
      require_tart
      require_vm
      vm_exists || die "no VM '$VM'"
      info "stopping $VM"
      "$TART" stop "$VM" || true
    }

    # -------------------------------------------------------------------- ip --
    cmd_ip() {
      require_tart
      require_vm
      vm_exists || die "no VM '$VM'"
      local wait="''${TART_VM_IP_WAIT:-30}"
      set -- "''${REST[@]+"''${REST[@]}"}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --wait) wait="''${2:?}"; shift 2 ;;
          *) die "ip: unknown arg: $1" ;;
        esac
      done
      local ip
      ip=$(guest_ip "$wait")
      [ -n "''${ip:-}" ] || die "no IP yet (is the VM running?)"
      printf '%s\n' "$ip"
    }

    # ------------------------------------------------------------------- ssh --
    cmd_ssh() {
      require_tart
      require_vm
      local user="''${USER:-}" wait="''${TART_VM_IP_WAIT:-60}"
      local identity="''${TART_VM_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
      set -- "''${REST[@]+"''${REST[@]}"}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --user) user="''${2:?}"; shift 2 ;;
          --wait) wait="''${2:?}"; shift 2 ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      [ -n "$user" ] || die "ssh: --user required (no \$USER in env)"

      vm_exists || die "no VM '$VM' — create + start first"
      vm_running || die "VM not running — tart-vm start $VM"
      local ip
      ip=$(guest_ip "$wait")
      [ -n "''${ip:-}" ] || die "no IP from tart ip (guest Remote Login on?)"

      info "ssh $user@$ip"
      exec ssh \
        -o "IdentityFile=$identity" \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" \
        "$user@$ip" "$@"
    }

    # ------------------------------------------------------------------ list --
    cmd_list() {
      require_tart
      exec "$TART" list "''${REST[@]+"''${REST[@]}"}"
    }

    # ---------------------------------------------------------------- doctor --
    cmd_doctor() {
      local rc=0
      echo "=== tart-vm doctor ==="
      if [ -x "$TART" ]; then
        echo "tart: ok ($TART)"
        "$TART" --version 2>/dev/null || true
      else
        echo "tart: MISSING"
        rc=1
      fi
      if [ -x "$PACKER" ] && [ -d "$PACKER_PLUGINS" ]; then
        echo "bake: ok (packer + tart plugin present)"
      else
        echo "bake: packer or plugin MISSING"
        rc=1
      fi
      if [ -n "$VM" ]; then
        if vm_exists; then
          echo "vm: present ($VM)"
          "$TART" list 2>/dev/null | /usr/bin/awk -v n="$VM" 'NR==1 || $2==n {print}'
          if vm_running; then
            echo "state: running"
            local ip
            ip=$(guest_ip 0 || true)
            echo "ip: ''${ip:-unknown}"
          else
            echo "state: stopped (or no DHCP lease yet)"
          fi
        else
          echo "vm: ABSENT ($VM) — tart-vm create|pull|bake $VM"
          rc=1
        fi
      else
        echo "vm: (none named — pass a VM name for per-VM checks)"
      fi
      echo "downloads share dir: $DOWNLOADS ($([ -d "$DOWNLOADS" ] && echo present || echo MISSING))"
      echo "backend: Tart -> Apple Virtualization.framework"
      exit "$rc"
    }

    # ------------------------------------------------------------- bootstrap --
    # Personalize a generic image (admin/admin setup user, SSH on) into YOUR
    # machine, over SSH: create the login user, secure-token it, install
    # Determinate Nix, activate the provided flake installable, rotate the
    # login password, optionally drop the setup admin. Idempotent — each step
    # probes before acting, so re-running after a failure resumes.
    cmd_bootstrap() {
      require_tart
      require_vm
      local login="" fullname="" flake="" authorized_key=""
      local admin_user="admin" admin_pass="admin"
      local drop_admin=0 force_activate=0 no_activate=0
      set -- "''${REST[@]+"''${REST[@]}"}"
      while [ $# -gt 0 ]; do
        case "$1" in
          --user) login="''${2:?}"; shift 2 ;;
          --fullname) fullname="''${2:?}"; shift 2 ;;
          --flake) flake="''${2:?}"; shift 2 ;;
          --admin-user) admin_user="''${2:?}"; shift 2 ;;
          --admin-pass) admin_pass="''${2:?}"; shift 2 ;;
          --authorized-key) authorized_key="''${2:?}"; shift 2 ;;
          --drop-admin) drop_admin=1; shift ;;
          --force-activate) force_activate=1; shift ;;
          --no-activate) no_activate=1; shift ;;
          *) die "bootstrap: unknown arg: $1" ;;
        esac
      done
      [ -n "$login" ] || die "bootstrap: --user LOGIN is required"
      [ -n "$flake" ] || [ "$no_activate" -eq 1 ] || die "bootstrap: --flake <installable> is required (or pass --no-activate)"
      [ -n "$fullname" ] || fullname="$login"
      [ "$login" = "$admin_user" ] && die "bootstrap: --user must differ from --admin-user (identity injects OVER the setup user, not into it)"

      vm_exists || die "no VM '$VM' — tart-vm pull/bake + start first"
      vm_running || die "VM not running — tart-vm start $VM"

      info "waiting for guest IP…"
      local ip
      ip=$(guest_ip 180)
      [ -n "''${ip:-}" ] || die "no IP from tart ip"
      info "guest ip: $ip"

      # Fresh images reuse DHCP leases across bakes, so pinning host keys here
      # would only ever produce false MITM alarms on a local bridge.
      local ssh_opts=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=10
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
      )

      # Run a command on the guest as the setup admin (password auth). SSHPASS
      # travels via the environment (sshpass -e), never argv — `ps` on the host
      # never shows it.
      adm() {
        SSHPASS="$admin_pass" sshpass -e \
          ssh "''${ssh_opts[@]}" "$admin_user@$ip" "$@"
      }

      info "waiting for SSH as $admin_user@$ip (password auth)…"
      local tries=0
      until adm true 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 60 ] || die "SSH not reachable after 5 minutes — is Remote Login enabled in the image?"
        sleep 5
      done
      info "ssh: ok"

      # Both supported image paths (this repo's bake template and cirruslabs'
      # registry images) give the setup admin passwordless sudo. Everything
      # below leans on that, so gate on it explicitly.
      adm "sudo -n true" 2>/dev/null \
        || die "setup admin '$admin_user' has no passwordless sudo — bootstrap needs it (both bake and cirruslabs images provide it)"

      # -- 1. login user ------------------------------------------------------
      # NOTE: passwords passed to sysadminctl ride the REMOTE argv and are
      # briefly visible in the guest's `ps` — a throwaway in-session credential
      # on a single-user VM, rotated to a fresh secret before this command
      # exits. Nothing is ever echoed except the single final print.
      local user_pw=""
      if adm "id -u $(printf '%q' "$login")" >/dev/null 2>&1; then
        info "user $login: exists — skipping create"
      else
        user_pw="$(random_password)"
        info "user $login: creating (admin, random in-session password)"
        adm "sudo -n sysadminctl -addUser $(printf '%q' "$login") -fullName $(printf '%q' "$fullname") -password $(printf '%q' "$user_pw") -admin" \
          || die "sysadminctl -addUser failed"
      fi

      # -- 2. secure token ----------------------------------------------------
      # FileVault/ownership needs at least one secure-token holder; grant it to
      # the new user from the setup admin (the image's sole token holder).
      if adm "sysadminctl -secureTokenStatus $(printf '%q' "$login") 2>&1 | grep -q ENABLED"; then
        info "secure token: already enabled for $login"
      elif [ -n "$user_pw" ]; then
        info "secure token: enabling for $login"
        adm "sudo -n sysadminctl -secureTokenOn $(printf '%q' "$login") -password $(printf '%q' "$user_pw") -adminUser $(printf '%q' "$admin_user") -adminPassword $(printf '%q' "$admin_pass")" \
          || info "WARNING: secureTokenOn failed (continuing — not fatal for headless use)"
      else
        info "WARNING: $login pre-exists without a secure token and its password is unknown — cannot enable; continuing"
      fi

      # -- 3. home directory --------------------------------------------------
      adm "sudo -n createhomedir -c -u $(printf '%q' "$login") >/dev/null 2>&1 || true"
      info "home directory: ensured"

      # -- 4. authorized key --------------------------------------------------
      if [ -n "$authorized_key" ]; then
        local akq homeq
        akq=$(printf '%q' "$authorized_key")
        homeq="/Users/$login"
        adm "sudo -n sh -c 'mkdir -p $homeq/.ssh && touch $homeq/.ssh/authorized_keys && grep -qxF $akq $homeq/.ssh/authorized_keys || echo $akq >> $homeq/.ssh/authorized_keys; chown -R $(printf '%q' "$login"):staff $homeq/.ssh; chmod 700 $homeq/.ssh; chmod 600 $homeq/.ssh/authorized_keys'" \
          || die "planting authorized_key failed"
        info "authorized key: planted for $login"
      fi

      # -- 5. passwordless sudo for the login user ----------------------------
      # Host-driven re-activation (`tart-vm ssh <vm> --user <login> -- nix run
      # <flake>`) has no TTY for a sudo prompt; the activation app escalates
      # itself. Same model as a disposable CI/sandbox guest — not a hardening
      # profile.
      adm "sudo -n sh -c 'mkdir -p /etc/sudoers.d && printf \"%s ALL=(ALL) NOPASSWD: ALL\n\" $(printf '%q' "$login") > /etc/sudoers.d/$(printf '%q' "$login")-nopasswd'" \
        || die "writing sudoers drop-in failed"
      info "passwordless sudo: ensured for $login"

      # -- 6. Determinate Nix -------------------------------------------------
      if adm "[ -x /nix/var/nix/profiles/default/bin/nix ]" 2>/dev/null; then
        info "nix: present — skipping install"
      else
        info "nix: installing Determinate Nix (this downloads inside the guest)…"
        adm "curl -fsSL https://install.determinate.systems/nix | sudo -n sh -s -- install --no-confirm" \
          || die "Determinate Nix install failed"
      fi

      # -- 7. activate the flake as the login user ----------------------------
      if [ "$no_activate" -eq 1 ]; then
        info "activation: skipped (--no-activate)"
      elif [ "$force_activate" -eq 0 ] && adm "[ -e /run/current-system ]" 2>/dev/null; then
        info "activation: /run/current-system exists — skipping (re-run with --force-activate to re-activate)"
      else
        info "activation: nix run $flake (as $login)"
        # -H so the consumer's activation app starts from the login user's HOME
        # (it is expected to handle its own root escalation, e.g. via the
        # sudoers drop-in above).
        adm "sudo -n -u $(printf '%q' "$login") -H /nix/var/nix/profiles/default/bin/nix run --extra-experimental-features 'nix-command flakes' $(printf '%q' "$flake")" \
          || die "activation failed — fix and re-run bootstrap (idempotent)"
      fi

      # -- 8. rotate the login password to a fresh secret ---------------------
      local final_pw
      final_pw="$(random_password)"
      adm "sudo -n sysadminctl -resetPasswordFor $(printf '%q' "$login") -newPassword $(printf '%q' "$final_pw")" \
        || die "password rotation failed"

      # -- 9. optionally drop the setup admin ---------------------------------
      if [ "$drop_admin" -eq 1 ]; then
        info "dropping setup admin '$admin_user' (via $login's session)"
        # Run the delete AS the login user — deleting the account that owns the
        # live SSH session from inside itself is unreliable.
        SSHPASS="$final_pw" sshpass -e \
          ssh "''${ssh_opts[@]}" "$login@$ip" \
          "sudo -n sysadminctl -deleteUser $(printf '%q' "$admin_user")" \
          || info "WARNING: deleting $admin_user failed (it may hold the GUI session) — demote/delete it manually"
      fi

      # THE single credential print of this whole script.
      echo
      echo "=================================================================="
      echo " bootstrap complete: $login@$VM ($ip)"
      echo
      echo " $login's password was rotated to:"
      echo
      echo "   $final_pw"
      echo
      echo " STORE IT NOW (password manager / Keychain). It is shown exactly"
      echo " once and exists nowhere else — not in logs, not on disk."
      echo "=================================================================="
    }

    # -------------------------------------------------------------- dispatch --
    [ $# -gt 0 ] || { usage; exit 2; }
    sub="$1"; shift
    case "$sub" in
      -h|--help|help) usage; exit 0 ;;
    esac
    parse_vm_and_rest "$@"
    case "$sub" in
      create) cmd_create ;;
      pull) cmd_pull ;;
      bake) cmd_bake ;;
      start) cmd_start ;;
      stop) cmd_stop ;;
      ip) cmd_ip ;;
      ssh) cmd_ssh ;;
      list) cmd_list ;;
      doctor) cmd_doctor ;;
      bootstrap) cmd_bootstrap ;;
      *) usage; die "unknown subcommand: $sub" ;;
    esac
  '';
}
