#!/usr/bin/env bash
# Verify that long Satellite installer resources expose numeric progress.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../satellite-lab/build-and-configure.sh
source "$REPO_ROOT/satellite-lab/build-and-configure.sh"

mock_ssh() {
  printf '1597 2360|641082572\n'
}

SAT_SSH=mock_ssh
output=$(_satellite_installer_progress)
grep -Fq 'Satellite installer progress: 1597/2360 resources (67%)' <<<"$output"
grep -Fq 'Discovery image transfer: 611 MiB downloaded' <<<"$output"

mock_maintenance_ssh() {
  printf 'package download/update|189|Downloading Packages:\n'
}

SAT_SSH=mock_maintenance_ssh
output=$(_satellite_maintenance_progress)
grep -Fq 'Satellite maintenance progress: package download/update (DNF cache: 189 MiB)' <<<"$output"
grep -Fq 'DNF: Downloading Packages:' <<<"$output"

grep -Fq '_satellite_seed_discovery_image || return 1' \
  "$REPO_ROOT/satellite-lab/build-and-configure.sh"
grep -Fq 'Streaming cached Discovery image to the Satellite VM' \
  "$REPO_ROOT/satellite-lab/build-and-configure.sh"
grep -Fq 'Could not seed a verified Discovery image on the Satellite VM' \
  "$REPO_ROOT/satellite-lab/build-and-configure.sh"
if grep -Fq 'guest_seed=$(mktemp)' "$REPO_ROOT/satellite-lab/build-and-configure.sh"; then
  echo 'FAIL: Discovery image seeding must not create a second host-sized temporary copy' >&2
  exit 1
fi

echo "PASS: Satellite installer reports resource and transfer progress"
