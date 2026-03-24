#!/usr/bin/env bash
# get_version.sh
#
# Outputs a version string in the format YYYYMMDD-HHMM based on the current
# UTC time.  Source or execute this script to obtain the tag/release name.
#
# Usage:
#   VERSION=$(./get_version.sh)
#   echo "Building version: $VERSION"

set -euo pipefail

date -u +"%Y%m%d-%H%M"
