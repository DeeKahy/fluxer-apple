# Convenience wrapper so you can build the package straight from this repo:
#   nix-build packaging/nix
#   open ./result/Applications/CornFlux.app
# The real package is package.nix, written in nixpkgs by-name form. When you
# submit it upstream, only package.nix moves to pkgs/by-name/co/cornflux/.
(import <nixpkgs> { }).callPackage ./package.nix { }
