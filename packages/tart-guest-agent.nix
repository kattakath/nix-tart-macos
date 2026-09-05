# Guest agent for Tart VMs (github.com/cirruslabs/tart-guest-agent) — clipboard
# sync (`--run-vdagent`, an in-house SPICE vdagent implementation), `tart exec`
# RPC, and `tart ip --resolver=agent`, bundled under `--run-agent`.
#
# NEITHER nixpkgs NOR a Homebrew tap carries this — cirruslabs publish only a
# GitHub Releases tarball. So this derivation fetches the release asset
# directly: an ad-hoc-signed (linker-signed) universal arm64/x86_64 binary.
# It runs fine unsigned via launchd because a Nix-fetched file carries no
# quarantine xattr (the actual Gatekeeper trigger, not the absence of a
# signature).
#
# Install + run this INSIDE the guest (as a per-user LaunchAgent — pasteboard
# access needs a live GUI session, so a root LaunchDaemon cannot sync the
# clipboard), never on the host.
{
  stdenvNoCC,
  fetchurl,
}:
let
  version = "0.14.1";
in
stdenvNoCC.mkDerivation {
  pname = "tart-guest-agent";
  inherit version;

  src = fetchurl {
    url = "https://github.com/cirruslabs/tart-guest-agent/releases/download/v${version}/tart-guest-agent-darwin-all.tar.gz";
    hash = "sha256-lllmdUUsik7tb5PIagW2oeDEvSsOOBkxsZ3e7jIg6yM=";
  };

  # The release tarball has no top-level directory (LICENSE/README.md/binary
  # sit flat) — stdenv's unpacker otherwise errors with "produced no directories".
  sourceRoot = ".";

  dontBuild = true;
  dontFixup = true; # skip fixup — it would strip the ad-hoc Mach-O signature

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m755 tart-guest-agent "$out/bin/tart-guest-agent"
    runHook postInstall
  '';

  meta = {
    description = "Tart VM guest agent — clipboard sync (vdagent), tart exec RPC, disk resize";
    homepage = "https://github.com/cirruslabs/tart-guest-agent";
    mainProgram = "tart-guest-agent";
    # Functional Source License 1.1, ALv2 Future (source-available; converts to
    # Apache-2.0 two years after each release) — not a standard OSI license, so
    # no matching lib.licenses.* entry; not free but permits personal,
    # non-competing use.
    license = {
      fullName = "Functional Source License 1.1, ALv2 Future License";
      url = "https://github.com/cirruslabs/tart-guest-agent/blob/main/LICENSE";
      free = false;
    };
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
