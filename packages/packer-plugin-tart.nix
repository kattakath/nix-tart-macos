# Packer builder plugin for Tart (github.com/cirruslabs/packer-plugin-tart),
# fetched as the upstream darwin-arm64 release binary and laid out exactly the
# way Packer's plugin discovery wants it:
#
#   $out/libexec/packer/plugins/github.com/cirruslabs/tart/
#     packer-plugin-tart_v<V>_x5.0_darwin_arm64            (the binary)
#     packer-plugin-tart_v<V>_x5.0_darwin_arm64_SHA256SUM  (its sha256, hex)
#
# Point PACKER_PLUGIN_PATH at $out/libexec/packer/plugins and `packer build`
# resolves the `github.com/cirruslabs/tart` required_plugin offline — no
# `packer init`, no plugin download at bake time.
#
# The zip's sha256 below matches upstream's published
# packer-plugin-tart_v<V>_SHA256SUMS for the darwin_arm64 asset.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:
let
  version = "1.21.0";
  # x5.0 is the Packer plugin API version baked into the release asset name —
  # it changes only when Packer breaks its plugin ABI.
  executable = "packer-plugin-tart_v${version}_x5.0_darwin_arm64";
in
stdenvNoCC.mkDerivation {
  pname = "packer-plugin-tart";
  inherit version;

  src = fetchurl {
    url = "https://github.com/cirruslabs/packer-plugin-tart/releases/download/v${version}/${executable}.zip";
    hash = "sha256-SjTKh7VANinaXKSTjpTupb8ygF+vA0ohGDViW2N9TnY=";
  };

  nativeBuildInputs = [ unzip ];
  dontUnpack = true;
  dontFixup = true; # keep the upstream code signature intact

  installPhase = ''
    runHook preInstall
    plugin_dir="$out/libexec/packer/plugins/github.com/cirruslabs/tart"
    mkdir -p "$plugin_dir"
    unzip -p "$src" > "$plugin_dir/${executable}"
    chmod 0755 "$plugin_dir/${executable}"
    sha256sum "$plugin_dir/${executable}" \
      | cut -d ' ' -f 1 \
      > "$plugin_dir/${executable}_SHA256SUM"
    runHook postInstall
  '';

  meta = {
    description = "Packer builder plugin for Tart VMs, prelaid for PACKER_PLUGIN_PATH";
    homepage = "https://github.com/cirruslabs/packer-plugin-tart";
    license = lib.licenses.mpl20;
    platforms = [ "aarch64-darwin" ];
  };
}
