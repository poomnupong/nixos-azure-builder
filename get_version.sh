#!/usr/bin/env bash
# get_version.sh
#
# Outputs a version string in the format nixos-<channel>-YYYYMMDD-HHMM based
# on the current UTC time and the NixOS channel pinned in flake.nix.
# Example: nixos-25.11-20260429-1858
#
# The NixOS base version is extracted from the nixpkgs input URL in flake.nix
# so that anyone looking at a release tag immediately knows which NixOS
# channel the image was built from.
#
# Usage:
#   VERSION=$(./get_version.sh)
#   echo "Building version: $VERSION"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Extract the NixOS channel version (e.g. "25.11") from flake.nix.
# The nixpkgs input line looks like:  nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
NIXOS_CHANNEL=$(sed -n 's|.*nixpkgs\.url.*nixos-\([0-9][0-9]*\.[0-9][0-9]*\).*|\1|p' \
  "${SCRIPT_DIR}/flake.nix")

if [ -z "$NIXOS_CHANNEL" ]; then
  echo "ERROR: Could not extract NixOS channel from flake.nix" >&2
  exit 1
fi

echo "nixos-${NIXOS_CHANNEL}-$(date -u +"%Y%m%d-%H%M")"
