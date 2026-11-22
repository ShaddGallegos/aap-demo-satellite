#!/usr/bin/env bash
# Import RHIS Satellite report templates as explicitly opted-in external content.
# This script runs on the Satellite VM as root; no third-party template source
# is vendored into aap-demo.
set -euo pipefail

enabled="${SATELLITE_IMPORT_RHIS_TEMPLATES:-false}"
accepted="${SATELLITE_RHIS_TEMPLATE_LICENSE_ACCEPTED:-false}"
org="${SAT_ORG:-Default Organization}"
repo="https://github.com/parmstro/rhis-builder-satellite-templates.git"
revision="2988eb2690aa3e3777dcfcc92a4f9c1b9cc37c28"
prefix="[RHIS] "
state_dir="${SATELLITE_RHIS_TEMPLATE_STATE_DIR:-/var/lib/aap-demo}"

case "$enabled" in
  true) ;;
  false) echo "✓ RHIS report-template import not requested"; exit 0 ;;
  *) echo "ERROR: SATELLITE_IMPORT_RHIS_TEMPLATES must be true or false" >&2; exit 2 ;;
esac

if [ "$accepted" != true ]; then
  cat >&2 <<'EOF'
ERROR: RHIS report templates are GPL-3.0 licensed external content.
Set SATELLITE_RHIS_TEMPLATE_LICENSE_ACCEPTED=true to import the pinned upstream
repository into Satellite. aap-demo does not vendor or modify those templates.
EOF
  exit 2
fi

for command in git hammer jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: RHIS report-template import requires $command" >&2
    exit 1
  }
done

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "ERROR: RHIS template revision must be a full Git SHA" >&2
  exit 2
}

[[ "$state_dir" = /* ]] || {
  echo "ERROR: SATELLITE_RHIS_TEMPLATE_STATE_DIR must be absolute" >&2
  exit 2
}
checkout="${state_dir}/rhis-satellite-templates-${revision}"
mkdir -p "$state_dir"
if [ -d "$checkout/.git" ]; then
  git -C "$checkout" fetch --depth 1 origin "$revision" >/dev/null
else
  git clone --quiet --no-checkout "$repo" "$checkout"
fi
git -C "$checkout" checkout --quiet --detach "$revision"

echo "Importing pinned RHIS Satellite report templates..."
imported=0
for template in "$checkout"/satellite_templates/*.erb; do
  [ -f "$template" ] || continue
  name=$(awk '/^name:[[:space:]]*/ {sub(/^name:[[:space:]]*/, ""); print; exit}' "$template")
  [ -n "$name" ] || {
    echo "ERROR: RHIS report template lacks a metadata name: $template" >&2
    exit 1
  }
  target_name="${prefix}${name}"
  if hammer report-template info --name "$target_name" --organization "$org" >/dev/null 2>&1; then
    hammer report-template update --name "$target_name" --organization "$org" --file "$template" >/dev/null
  else
    hammer report-template create --name "$target_name" --organization "$org" \
      --file "$template" --locked false >/dev/null
  fi
  imported=$((imported + 1))
done
[ "$imported" -gt 0 ] || {
  echo "ERROR: No RHIS report template files were found in the pinned checkout" >&2
  exit 1
}

templates=$(hammer --output json report-template list) || exit 1
count=$(jq --arg prefix "$prefix" \
  '[.[] | (.Name // .name // "") | select(startswith($prefix))] | length' <<<"$templates")
[[ "$count" =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: RHIS template import completed without a prefixed report template" >&2
  exit 1
}
echo "✓ Imported ${count} RHIS report template(s) into ${org}"
