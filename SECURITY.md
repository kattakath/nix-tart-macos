# Security Policy

## The model (important)

`nix-tart-macos` provisions local VMs; its security posture is about **what
gets trusted, pinned, and printed**:

- **No secret in the Nix store, git, or an image.** Images are
  operator-neutral by design: the only credential they carry is the public,
  throwaway `admin`/`admin` setup user, which `tart-vm bootstrap` exists to
  supersede (and can delete with `--drop-admin`).
- **The one credential this tool creates** — the login user's rotated
  password — is generated from `/dev/urandom` in-session, printed exactly
  once to the operator's terminal, and stored nowhere (no logs, no files).
  Intermediate in-session passwords are random, never echoed, and dead by the
  time bootstrap exits. (Caveat: passwords handed to `sysadminctl` ride the
  *guest's* process argv for the duration of that command — visible to
  someone already root inside your fresh, single-user VM, i.e. nobody.)
- **Registry pulls are digest-pinned by force.** `tart-vm pull` refuses any
  bare tag, `:latest` included: a moving tag is a trust decision delegated to
  whoever controls the registry, revocable at any time. Resolve the digest
  once, audit that image, pin it.
- **Bake minimizes third-party trust:** Apple's signed IPSW from Apple's CDN,
  a vendored + rev-pinned + human-readable HCL template (header records
  source, rev, license, delta), and a hash-pinned plugin binary whose sha256
  is checked against upstream's published `SHA256SUMS`.
- **The guest is not a security boundary you should over-trust.** Bootstrap
  grants the login user passwordless sudo (host-driven, TTY-less
  re-activation needs it) and disables host-key checking against the local
  DHCP bridge (fresh images reuse leases; pinning would only produce false
  MITM alarms). Both are the right defaults for a disposable dev/CI sandbox —
  not for a VM you expose to a hostile network.
- **launchd persistence stays auditable.** Every agent the darwin module
  emits uses a `nix-tart-vm-<name>` arg0 wrapper so macOS's Background Task
  Manager attributes it legibly; `nix flake check` asserts this.

## Reporting a vulnerability

Please open a **private** security advisory via GitHub
("Security" → "Report a vulnerability"), or contact the maintainer directly.
Do not file public issues for undisclosed vulnerabilities.
