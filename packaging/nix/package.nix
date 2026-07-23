# CornFlux, a native client for Fluxer. macOS only (distributed as a universal
# .app inside a DMG, no Linux build exists).
#
# To submit this to nixpkgs, drop it in as:
#   pkgs/by-name/co/cornflux/package.nix
# Nixpkgs auto-discovers by-name packages, so no all-packages.nix edit is needed.
# Bump `version` and `src.hash` on each release. Get the hash with:
#   nix store prefetch-file --name cornflux.dmg \
#     https://github.com/DeeKahy/fluxer-apple/releases/download/vVERSION/CornFlux-macOS-Universal.dmg
#
# Build and try it locally from the repo (default.nix here wires up callPackage):
#   nix-build packaging/nix
#   open ./result/Applications/CornFlux.app

{
  lib,
  stdenvNoCC,
  fetchurl,
  _7zz,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cornflux";
  version = "0.1.0";

  src = fetchurl {
    url = "https://github.com/DeeKahy/fluxer-apple/releases/download/v${finalAttrs.version}/CornFlux-macOS-Universal.dmg";
    hash = "sha256-gXwmUpyTWEopRqoFnFXibAnZq7kdnT4M1hMBRpb8KF0=";
  };

  nativeBuildInputs = [ _7zz ];

  # The DMG is APFS (macOS 15 default), which undmg cannot read, so unpack it
  # with 7zz. CornFlux.app lands at the extraction root.
  unpackPhase = ''
    runHook preUnpack
    7zz x -y "$src" > /dev/null
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    cp -r CornFlux.app "$out/Applications/CornFlux.app"
    runHook postInstall
  '';

  meta = {
    description = "Native client for the Fluxer chat platform";
    homepage = "https://github.com/DeeKahy/fluxer-apple";
    changelog = "https://github.com/DeeKahy/fluxer-apple/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.agpl3Only;
    maintainers = with lib.maintainers; [ ];
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "CornFlux";
  };
})
