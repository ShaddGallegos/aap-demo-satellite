#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/satellite-lab/12-rhis-report-templates.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

bash "$SCRIPT" >"$TMPDIR/output"
grep -Fq 'not requested' "$TMPDIR/output"

if SATELLITE_IMPORT_RHIS_TEMPLATES=true bash "$SCRIPT" >"$TMPDIR/output" 2>&1; then
  echo 'FAIL: RHIS import did not require license acceptance' >&2
  exit 1
fi
grep -Fq 'GPL-3.0 licensed external content' "$TMPDIR/output"

mkdir -p "$TMPDIR/bin"
cat >"$TMPDIR/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = clone ]; then
  target="${!#}"
  mkdir -p "$target/.git" "$target/satellite_templates"
  cat >"$target/satellite_templates/host-summary.erb" <<'TEMPLATE'
<%#
name: Host - Host Summary Report
model: ReportTemplate
-%>
TEMPLATE
fi
EOF
cat >"$TMPDIR/bin/hammer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'report-template list'*) printf '%s\n' '[{"Name":"[RHIS] Host - Host Summary Report"}]' ;;
  *'report-template info'*) exit 1 ;;
  *'report-template create'*) : ;;
  *) echo "Unexpected hammer invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod 700 "$TMPDIR/bin/git" "$TMPDIR/bin/hammer"
PATH="$TMPDIR/bin:$PATH" \
SATELLITE_IMPORT_RHIS_TEMPLATES=true \
SATELLITE_RHIS_TEMPLATE_LICENSE_ACCEPTED=true \
SATELLITE_RHIS_TEMPLATE_STATE_DIR="$TMPDIR/state" \
  bash "$SCRIPT" >"$TMPDIR/output"
grep -Fq 'Imported 1 RHIS report template' "$TMPDIR/output"

echo 'PASS: RHIS report-template import is explicit, pinned, and externally sourced'
