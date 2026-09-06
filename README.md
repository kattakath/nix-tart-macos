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
runs a persistent `macvm` sandbox guest (see its
[`docs/macvm-tart-runbook.md`](https://github.com/kattakath/nix-config/blob/main/docs/macvm-tart-runbook.md)
for the measured VirtioFS-coherence and quarantine-xattr findings that shaped
this design).

## Ephemeral GitHub Actions runners (`tart.githubRunners.*`)

Every CI job gets a fresh, disposable macOS VM; the VM is the security
boundary (a hostile workflow only destroys its own throwaway guest).
Multi-instance — N orgs/repos on one host — sharing Apple's hard
**two-concurrent-macOS-VM** budget through a slot semaphore.

```nix
imports = [ nix-tart-vms.darwinModules.github-runner ];
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

Per instance: run `tart-runner-setup-<name>` once (digest-pinned pull, base
clone, SSH host-key pin) — then the LaunchAgent loops forever: mint a 1-hour
token → clone → boot headless → run **one** `--ephemeral` job over pinned
SSH → delete the VM. Runner names are `<instance>-<uuid>` (never
`--replace`), orphan reapers are scoped per instance, and controllers must
run in a **GUI login session** (a Virtualization.framework keychain
requirement — there is deliberately no daemon mode). Provenance: hardened
bones from [a1678991/github-tart-runner](https://github.com/a1678991/github-tart-runner)
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
