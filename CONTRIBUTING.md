# Contributing

A small, focused, macOS-only flake — contributions that keep it that way are
the most welcome.

## Dev loop

```sh
nix flake check -L            # build the CLI (shellcheck), validate the Packer
                              # template offline, smoke-eval the darwin module
nix fmt                       # nixfmt-rfc-style (CI enforces this)
nix build .#tart-vm
nix run .#tart-vm -- doctor   # against your local tart install
```

## Guidelines

- The CLI stays one `writeShellApplication` (`packages/tart-vm.nix`),
  shellcheck-clean under `set -euo pipefail`. New behavior is a subcommand or
  a flag, not a second binary.
- **VM name is a parameter, always.** Nothing may hardcode a VM name — the
  point of extracting this from a personal config was removing exactly that.
- **The image stays operator-neutral.** Identity (users, keys, flakes,
  passwords) enters only at `bootstrap` time, from flags. Never bake personal
  data into the template or an image.
- **No secret values in code or output, ever.** The single sanctioned
  credential print is the rotated-password block at the end of `bootstrap`;
  everything else refers to secrets by name only.
- **Digest pins stay mandatory** for `pull`. Do not add a
  `--i-know-what-im-doing` escape for bare tags.
- `templates/*.pkr.hcl` is **vendored, not authored** — refresh it from
  upstream (per the README) rather than editing behavior into it; local
  deltas are recorded in the file header and kept minimal.
- Every launchd unit the darwin module emits keeps its
  `nix-<kebab>` arg0 wrapper (BTM/TCC legibility — rationale in
  `modules/darwin.nix`); `nix flake check` asserts it.
- Fetched release artifacts (`packer-plugin-tart`, `tart-guest-agent`) are
  hash-pinned; version bumps update URL + hash together, verified against
  upstream's published checksums where they exist.
- Update `README.md` for user-facing changes; CI (format + `nix flake check`)
  must pass.
