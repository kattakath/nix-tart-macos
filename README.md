# nix-tart-vms

[![CI](https://github.com/kattakath/nix-tart-vms/actions/workflows/ci.yml/badge.svg)](https://github.com/kattakath/nix-tart-vms/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Built with Nix](https://img.shields.io/badge/built%20with-Nix-5277C3.svg?logo=nixos&logoColor=white)](https://nixos.org)

Declarative lifecycle + plug-and-play provisioning for
[Tart](https://tart.run) **macOS guest VMs** on Apple Silicon, as a single Nix
flake: one `tart-vm` CLI that creates/pulls/**bakes** a generic image,
starts/stops/doctors it, and **bootstraps** it over SSH into *your* machine
(your login user, Determinate Nix, your nix-darwin flake, your key) — plus a
nix-darwin module (`tart.vms.<name>`) for the host side.

**Why this exists:** the Tart ecosystem has excellent pieces — Tart itself,
cirruslabs' [packer plugin](https://github.com/cirruslabs/packer-plugin-tart)
and [image templates](https://github.com/cirruslabs/macos-image-templates),
the [guest agent](https://github.com/cirruslabs/tart-guest-agent) — but **no
Nix flake stitches them into a lifecycle**: nixpkgs packages only the `tart`
binary, the guest agent is packaged nowhere, and "clone image → wait for SSH →
create user → install Nix → activate flake → rotate password" is a runbook
people re-type by hand. This flake is that runbook, mechanized and idempotent.

**Design principle — the image is operator-neutral; identity injects at
bootstrap.** A pulled or baked image knows only a throwaway `admin`/`admin`
setup user with SSH on. Everything that makes the VM *yours* — login name,
flake, authorized key, passwords — arrives at `tart-vm bootstrap` time, from
flags. So one image serves every operator, images stay shareable/cacheable,
and no personal data is ever baked into a disk you might publish.

## Prerequisites

- **macOS on Apple Silicon** (Tart drives Apple's Virtualization.framework;
  there is no Intel or Linux path).
- **Nix** with flakes enabled.
- Disk space under `~/.tart/` — VM disks and IPSWs live there, **never** in
  the Nix store or this repo.

## Install

```nix
{
  inputs.tart-vms.url = "github:kattakath/nix-tart-vms";
}
```

Then `nix run github:kattakath/nix-tart-vms#tart-vm -- <subcommand> …`, or
wire `tart-macos.packages.aarch64-darwin.tart-vm` /
`tart-vms.darwinModules.default` into your own flake.

## Quick start

Two ways to get a generic image — a trust decision, not a convenience one:

| | `tart-vm pull` (registry) | `tart-vm bake` (local Packer build) |
|---|---|---|
| **Source** | cirruslabs' prebuilt images on ghcr.io | Apple's signed IPSW, fetched from Apple's CDN |
| **Trust** | You trust cirruslabs' build pipeline | You trust only Apple + this repo's vendored template (readable HCL) |
| **Pin** | `--digest sha256:…` is **required** — bare `:latest` is refused | Template is vendored + rev-pinned in this repo |
| **Time** | Minutes (a large download) | ~1h (full macOS install + scripted Setup Assistant) |
| **Result** | Identical either way: setup user `admin`/`admin`, SSH on | Identical either way |

```sh
# A) pull a prebuilt image, digest-pinned (resolve the digest once, then pin it)
nix run .#tart-vm -- pull dev --image ghcr.io/cirruslabs/macos-tahoe-vanilla \
  --digest sha256:<64-hex-from-the-registry>

# B) or bake your own golden image from Apple's IPSW (see "Golden-image bake")
nix run .#tart-vm -- bake dev

# start it (shares ~/Downloads into the guest by default; --no-share to skip)
nix run .#tart-vm -- start dev
```

## Bootstrap — plug-and-play provisioning

Point `bootstrap` at the running generic VM and at *your* nix-darwin flake
(the installable you'd run inside the guest to activate it — e.g. an app that
wraps `darwin-rebuild switch`):

```sh
nix run .#tart-vm -- bootstrap dev \
  --user alice \
  --fullname "Alice Example" \
  --flake github:alice/nix-config#devvm \
  --authorized-key "ssh-ed25519 AAAA… alice@host" \
  --drop-admin
```

What it does, over SSH, **idempotently** (each step probes before acting, so a
failed run resumes where it stopped):

1. waits for SSH as the image's setup user (password auth),
2. creates `alice` as an admin with a random in-session password,
3. grants her a secure token (from the setup admin's), ensures the home dir,
4. plants the authorized key, writes a `NOPASSWD` sudoers drop-in
   (host-driven re-activation has no TTY for a sudo prompt),
5. installs Determinate Nix if missing,
6. runs `nix run github:alice/nix-config#devvm` **as alice** (skipped if
   `/run/current-system` already exists; `--force-activate` overrides),
7. rotates alice's password to a fresh random secret and prints it **once**
   (store it immediately — it exists nowhere else),
8. `--drop-admin` then deletes the setup admin, via alice's own session.

Day-to-day after that:

```sh
nix run .#tart-vm -- ssh dev --user alice -- uname -a
nix run .#tart-vm -- ssh dev --user alice -- nix run --refresh github:alice/nix-config#devvm
nix run .#tart-vm -- doctor dev       # exit-coded health checks
nix run .#tart-vm -- stop dev
```

Env overrides: `TART_VM_DISK_GB` / `TART_VM_CPUS` / `TART_VM_MEMORY_MB`
(create defaults), `TART_VM_DOWNLOADS` (host dir shared as `Downloads`),
`TART_VM_LOG_DIR`, `TART_VM_SSH_IDENTITY`, `TART_VM_IP_WAIT`.

## The nix-darwin module

Declarative host-side management of running VMs — cpu/memory/shares, and
optional start-at-login via launchd:

```nix
{
  imports = [ inputs.tart-vms.darwinModules.default ];

  tart.vms.dev = {
    cpu = 6;
    memory = 12288;          # MiB
    headless = true;
    dirs = [ "Downloads:/Users/alice/Downloads" ];
    autoStart = true;        # launchd user agent, KeepAlive
    logDir = "/Users/alice/Library/Logs";
  };
}
```

Creating the VM stays imperative (`tart-vm create|pull|bake`) **by design** —
disks and IPSWs must never enter the Nix store; the module manages runtime
shape only.

Every launchd agent the module emits execs through a
`writeShellScriptBin "nix-tart-vm-<name>"` wrapper — never bare `tart`, never
`sh -c`. macOS's Background Task Manager lists agents by executable basename,
so the `nix-` prefix keeps Nix-managed persistence auditable at a glance; and
macOS TCC attributes protected-folder access (e.g. a shared `~/Downloads`) to
that same arg0, where an attributable Apple interpreter like `/bin/sh` can be
silently denied. `nix flake check` asserts the rule mechanically.

## Guest agent

`packages.aarch64-darwin.tart-guest-agent` packages cirruslabs'
[tart-guest-agent](https://github.com/cirruslabs/tart-guest-agent) (nixpkgs
does not carry it) for use **inside** the guest: clipboard sync between host
and guest (Apple's Virtualization.framework does not sync the pasteboard for
macOS guests on its own), `tart exec` RPC, and `tart ip --resolver=agent`.
Run it as a per-user LaunchAgent in the guest — pasteboard access needs a
live GUI session, so a root LaunchDaemon cannot sync the clipboard:

```nix
# in the GUEST's nix-darwin config
launchd.user.agents.tart-guest-agent.serviceConfig = {
  Label = "org.cirruslabs.tart-guest-agent";
  ProgramArguments = [ "${tartGuestAgentWrapper}/bin/nix-tart-guest-agent" ];
  RunAtLoad = true;
  KeepAlive = true;
};
```

(with `nix-tart-guest-agent` a one-line `writeShellScriptBin` wrapper execing
`tart-guest-agent --run-agent` — same arg0 rule as above.)

## Golden-image bake

`tart-vm bake` wraps `packer build` over a **vendored, rev-pinned** copy of
cirruslabs' vanilla template
([`templates/vanilla-tahoe.pkr.hcl`](./templates/vanilla-tahoe.pkr.hcl) —
source repo, rev, license, and the one local delta are recorded in its
header). The pinned
[`packer-plugin-tart`](./packages/packer-plugin-tart.nix) is pre-laid on
`PACKER_PLUGIN_PATH`, so there is no `packer init` and no plugin download at
bake time. The build fetches the macOS IPSW from Apple's CDN, boots it, and
**types its way through Setup Assistant** via scripted keystrokes, ending in
a generic image: setup user `admin`/`admin`, passwordless sudo, SSH and
Screen Sharing on, auto-login, no sleep.

```sh
nix run .#tart-vm -- bake dev            # bakes, then renames to "dev"
nix run .#tart-vm -- bake                # keeps the template's own vm_name
nix run .#tart-vm -- bake dev --template ./my-fork.pkr.hcl
```

Do not touch the VM window while it runs — the keystroke script is blind.

### Refreshing the vendored template

The `boot_command` is **release-specific**: it navigates *that* macOS
release's Setup Assistant screens, so a newer IPSW usually needs a refreshed
script. To refresh:

1. Fetch the current template for your target release from
   [cirruslabs/macos-image-templates](https://github.com/cirruslabs/macos-image-templates)
   (`templates/vanilla-<release>.pkr.hcl`).
2. Re-apply the one local delta (drop the unused `ansible` entry from
   `required_plugins`).
3. Update the header's `Rev:` line and, if the plugin floor moved, bump
   [`packages/packer-plugin-tart.nix`](./packages/packer-plugin-tart.nix).

## Commands

| Subcommand | Role |
|---|---|
| `create` | `tart create --from-ipsw` + `tart set` cpu/ram (manual Setup Assistant path) |
| `pull` | `tart clone` a registry image — **digest pin required**, `:latest` refused |
| `bake` | Packer golden-image build from Apple's IPSW (vendored template) |
| `start` | Detached `tart run` + VirtioFS dir share + DHCP IP wait |
| `stop` / `ip` / `ssh` / `list` | What they say |
| `doctor` | Exit-coded health checks (tart, packer+plugin, VM state, share dir) |
| `bootstrap` | The plug-and-play chain above |

VM name is always a parameter: leading positional (`tart-vm start dev`) or
`--vm dev` — nothing is hardcoded.

## Security model

- **No secret ever lands in the Nix store, git, or an image.** The one
  credential this tool creates — the login user's final password — is
  generated in-session, printed exactly once to your terminal, and stored
  nowhere.
- **Registry pulls are digest-pinned by force.** A moving tag (`:latest`
  included) can be repointed by the registry owner at any time; `pull`
  refuses to proceed without `--digest sha256:…`.
- **Bake trusts less:** Apple's signed IPSW + a vendored, readable, rev-pinned
  HCL template + a hash-pinned plugin binary (checked against upstream's
  published SHA256SUMS).
- Details and reporting: [SECURITY.md](./SECURITY.md).

## Used in production

The machinery here is extracted and generalized from
**[kattakath/nix-config](https://github.com/kattakath/nix-config)**, where it
ran a persistent `macvm` sandbox guest until 2026-09-05 (see its
[`docs/macvm-readd-runbook.md`](https://github.com/kattakath/nix-config/blob/main/docs/macvm-readd-runbook.md)
for the measured VirtioFS-coherence and quarantine-xattr findings that shaped
this design, and what re-adding the guest would take).

## Ephemeral GitHub Actions runners (`tart.githubRunners.*`)

Every CI job gets a fresh, disposable macOS VM; the VM is the security
boundary (a hostile workflow only destroys its own throwaway guest).
Multi-instance — N orgs/repos on one host — sharing Apple's hard
**two-concurrent-macOS-VM** budget through a slot semaphore.

```nix
imports = [ nix-tart-vms.darwinModules.github-runner ];
# Durable state shared with the GitLab lane below — slots, host-key pins and
# BOTH lanes' logs. Defaults to ~/.local/state/tart-runner (derived from
# nix-darwin's system.primaryUserHome). It must be reboot-durable, writable by
# the GUI login user, and whitespace-free; the module asserts all three.
tart.runnerStateDir = "/Users/me/.local/state/tart-runner";
tart.githubRunners.myorg = {
  scope = { type = "org"; value = "myorg"; };   # or type = "repo"; value = "owner/repo"
  appId = 123456;              # one GitHub App (public) serves many installs
  installationId = 7890123;    # this scope's installation of that App
  privateKeyPath = "/run/agenix/gh-app-key";    # consumer delivers the PEM
  image = {
    oci = "ghcr.io/cirruslabs/macos-runner:tahoe";
    digest = "sha256:…";       # digest pin is mandatory
  };
};
```

**The wait for work happens on the host, not in a guest.** The LaunchAgent
loops forever, and the loop is cheap:

```
job queued at GitHub (free, up to 24h)
  → host-side REST poll sees a queued job whose runs-on: this lane satisfies
  → bounded slot acquire (on timeout: mint nothing, leave it queued)
  → JIT config minted — this is what creates the runner at the forge
  → clone → boot headless → ONE job over pinned SSH → delete the VM
```

Nothing is booted between polls, so an **idle lane costs no guest, no slot and
no RAM** — the same shape the GitLab lane below always had. The price is
first-job latency: up to one `pollIntervalSeconds` (default 60s) to notice the
job, then ~1–3 min for clone + boot. That is the right trade for a handful of
jobs a day on a laptop where 8 GB per idle lane and one of only **two** guest
slots are the scarce things; it would be the wrong trade for a
latency-critical or continuously-busy lane, where the guest is never idle
anyway — lower the interval there, or keep a warm runner.

Idle cost is ~2 REST requests per watched repo per interval (queued +
in_progress run listings; a listing of a run's jobs only when one exists).
Org-scope lanes watch every repo the App installation can reach; narrow that
with `watchRepos` if a big installation approaches the App's ≥5000 req/hour
limit. A push channel was considered and declined: `gh webhook forward` is
documented as a webhook *testing* aid, needs a personal `gh` session rather
than this lane's App installation, and a real webhook receiver (ingress,
public URL or tunnel, shared secret, HTTP server, its own supervision) is
bigger than the problem — the same "watch the queue depth" poll shape
actions-runner-controller used before webhooks.

Registration is a **JIT config**
(`POST …/actions/runners/generate-jitconfig`), not a registration token +
`config.sh`: the controller hands the blob to `Runner.Listener run` over ssh
**stdin**, so no registration token exists and no credential outlives the
guest. (JIT does *not* mean an empty guest disk — the blob decodes to
`.runner`/`.credentials` at run time, in a VM deleted minutes later.) The
`run` subcommand is mandatory; without it the runner writes its config, prints
usage and exits 0. A JIT registration is forced ephemeral and
update-disabled server-side, so no `--ephemeral`/`--disableupdate` flag is
passed, and the image's runner version is never silently self-updated.

A guest that never receives a job — a sibling lane won the race, or the job
was cancelled — is torn down after `TR_JOB_GRACE` (300s) instead of sitting at
"Listening for Jobs" holding a slot, and its registration is deleted rather
than left as a phantom offline runner. Runner names are `<instance>-<uuid>`
(never `--replace`), orphan reapers are scoped per instance, and controllers
must run in a **GUI login session** (a Virtualization.framework keychain
requirement — there is deliberately no daemon mode).

**On images and pins.** The local base clone *and* the SSH host-key pin are
content-keyed by `sha256(oci@digest)`, so **bumping the digest renames both** —
by design (a new image genuinely has a new host key, and a fixed pin path would
let a stale pin authenticate a new guest). It is therefore not a one-time
setup: on a bump, one elected instance per distinct image re-creates them by
itself on its next cycle — pulling with **no** VM slot held (a first pull is
**hundreds** of GB: `macos-runner:tahoe` measured 222 GB on 2026-09-06, and
needed ~138 GB of free space while staging), then taking a slot for the single
throwaway pin boot. Watch
`<runnerStateDir>/<owning-instance>.log`; the other instances on that image
just log that they are waiting. `tart-runner-setup-<name> [image|pin|all]`
still exists to pre-warm a bump or to debug one by hand. Superseded
`tr-base-*` images are garbage-collected by the same owner at startup.

Provenance: hardened bones from
[a1678991/github-tart-runner](https://github.com/a1678991/github-tart-runner)
(MIT, notice preserved in `packages/tart-runner.nix`); the multi-instance
fixes are this repo's.

## GitLab CI on the same VM budget (`gitlab-tart`)

The GitLab half needs no custom controller — cirruslabs'
[gitlab-tart-executor](https://github.com/cirruslabs/gitlab-tart-executor)
already runs each GitLab CI job in an ephemeral Tart VM via gitlab-runner's
custom-executor interface. This flake packages its release binary (nixpkgs
carries it nowhere) and adds **slot shims** so its VMs share the host's
two-macOS-guest budget with the `tart.githubRunners.*` GitHub controllers —
`packages/tart-slots.nix` is the single semaphore protocol both speak
(GitHub slots are pid-owned; GitLab slots are keyed by the executor's
deterministic `gitlab-<CI_JOB_ID>` VM name, since its prepare process exits
while the VM lives on).

The wait for a slot is **bounded** (`TR_SLOT_WAIT`), and the two lanes want
opposite defaults because a queued job costs them different things:

| Lane | Default | On expiry |
|---|---|---|
| GitHub (`tart-runner-controller`) | 1800s | Registers **no** runner — the job stays queued at GitHub (free, up to 24h) and the controller loops. |
| GitLab (`nix-gitlab-tart-prepare`) | 120s | Exits `$SYSTEM_FAILURE_EXIT_CODE`, so the failure is attributed to the runner, not the pipeline. gitlab-runner retries `prepare` a bounded number of times and then fails the job as `runner_system_failure` — it does **not** requeue it. Add `retry: { when: runner_system_failure }` to a job that should genuinely retry. Still far better than blocking, which burned the job's own timeout while the coordinator thought it was running. |

Both log a greppable `SLOT-WAIT-TIMEOUT`.

Two ways to wire gitlab-runner to it:

**Declarative** — `darwinModules.gitlab-runner` runs gitlab-runner itself as a
GUI-session LaunchAgent (`nix-gitlab-runner` arg0) and renders its config.toml
at agent start from a runtime token file, so the `glrt-…` token never enters
the Nix store. (nix-darwin's own `services.gitlab-runner` can't do this job:
it is a launchd *daemon* under a service user, and Tart guests only boot in
the GUI login session; it also still speaks the legacy registration-token
flow.) Registration — minting the token — stays a one-time manual act.

```nix
tart.gitlabRunner = {
  enable = true;
  runnerName = "my-mac";
  tokenFile = "/run/agenix/gitlab-runner-token"; # agenix, or any runtime path
  concurrent = 2; # may exceed the VM budget — the slot shims serialize
};
# Same option, same directory as the GitHub lane above — that shared value IS
# the two-guest semaphore. Point the two lanes at different dirs and each gets
# its own budget, which Apple's framework will then refuse mid-job.
tart.runnerStateDir = "/Users/me/.local/state/tart-runner";
```

**Imperative** — keep your own `~/.gitlab-runner/config.toml`:

```sh
nix run github:kattakath/nix-tart-vms#... tart-gitlab-print-config
# paste the printed [runners.custom] stanza into ~/.gitlab-runner/config.toml
```

gitlab-runner **always** runs the cleanup stage, even after a failed prepare,
so slots cannot leak past a job; a hard crash is covered by stale-slot
reclaim (`tart list` no longer shows the marker VM). macOS 15+ note: the
"Local Network" privacy gate can stall guest SSH — see upstream's README for
the privileged `localnetworkhelper` or the RFC1918 pre-allow.

## License

MIT © Ismail Kattakath — except
[`templates/vanilla-tahoe.pkr.hcl`](./templates/vanilla-tahoe.pkr.hcl), which
is vendored from MIT-licensed
[cirruslabs/macos-image-templates](https://github.com/cirruslabs/macos-image-templates)
(attribution in its header).
