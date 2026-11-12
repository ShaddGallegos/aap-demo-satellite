#!/usr/bin/env bash
# Run on an existing Satellite server; never apply initial-install settings.
set -euo pipefail

satellite_release() {
  local version
  version=$(rpm -q --qf '%{VERSION}' satellite) || return 1
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || {
    echo "ERROR: Unrecognized Satellite RPM version: $version" >&2; return 1;
  }
  printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

satellite_maintenance_target() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("current_satellite_version")' \
    /usr/share/satellite-maintain/config.yml
}

satellite_backup() {
  local root="${SATELLITE_BACKUP_DIR:-/var/backup/satellite}" backup
  install -d -m 700 "$root" || return 1
  backup=$(mktemp -d "$root/pre-${1}.XXXXXX") || return 1
  echo "Satellite rollback backup: $backup"
  satellite-maintain backup offline --assumeyes --preserve-directory "$backup" || {
    echo "ERROR: Backup failed; no package changes will be attempted." >&2
    return 1
  }
}

satellite_reboot_required() {
  local rc=0
  dnf needs-restarting --reboothint || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 194 ;;
    *) echo "ERROR: Cannot determine whether Satellite needs a reboot." >&2; return "$rc" ;;
  esac
}

satellite_apply_maintenance() {
  local operation="$1" expected="$2" actual
  if [ "$operation" = upgrade ]; then
    satellite-maintain upgrade check --assumeyes --disable-self-upgrade || return 1
    satellite-maintain upgrade run --assumeyes --disable-self-upgrade || return 1
  else
    satellite-maintain update check --assumeyes --disable-self-update || return 1
    satellite-maintain update run --assumeyes --disable-self-update || return 1
  fi
  actual=$(satellite_release) || return 1
  [ "$actual" = "$expected" ] || {
    echo "ERROR: Expected Satellite $expected after $operation, found $actual." >&2; return 1;
  }
  satellite-maintain health check --assumeyes || return 1
  satellite_reboot_required
}

satellite_maintenance_main() {
  local current target next repos repo maintenance_repo rc os_major arch
  rpm -q satellite >/dev/null || return 1
  test -s /etc/foreman-installer/scenarios.d/satellite-answers.yaml &&
    test -s /etc/foreman/settings.yaml || {
    echo "ERROR: Satellite packages exist but installation is incomplete. Repair the saved installer scenario before rerunning." >&2
    return 1
  }
  satellite-maintain service start || return 1
  satellite-maintain health check --assumeyes || return 1
  os_major=$(. /etc/os-release; printf '%s' "${VERSION_ID%%.*}")
  arch=$(rpm --eval '%{_arch}') || return 1
  while :; do
    current=$(satellite_release) || return 1
    target=$(satellite_maintenance_target) || return 1
    next="${current%.*}.$((${current#*.} + 1))"
    case "$target" in
      "$next")
        # A previous invocation may already have staged the next maintenance tool.
        satellite_backup "$current" || return 1
        satellite_apply_maintenance upgrade "$next" || return $?
        continue
        ;;
      "$current") ;;
      *)
        echo "ERROR: Maintenance target $target is not a supported adjacent release of Satellite $current." >&2
        return 1
        ;;
    esac
    rc=0
    # Read-only: the protector otherwise hides updates to managed packages.
    dnf --disableplugin=foreman-protector check-update || rc=$?
    case "$rc" in
      0) echo "Satellite $current packages are current." ;;
      100)
        satellite_backup "$current" || return 1
        satellite-maintain self-upgrade || return 1
        target=$(satellite_maintenance_target) || return 1
        [ "$target" = "$current" ] || {
          echo "ERROR: Maintenance self-update changed its target to $target unexpectedly." >&2
          return 1
        }
        satellite_apply_maintenance update "$current" || return $?
        rc=0
        dnf --disableplugin=foreman-protector check-update || rc=$?
        [ "$rc" -eq 0 ] || {
          echo "ERROR: Package updates remain or discovery failed after maintenance; refusing to continue." >&2
          return 1
        }
        ;;
      *) echo "ERROR: Package update discovery failed." >&2; return "$rc" ;;
    esac
    repos=$(LC_ALL=C subscription-manager repos --list) || return 1
    repos=$(awk '$1 == "Repo" && $2 == "ID:" {print $3}' <<<"$repos")
    repo="satellite-${next}-for-rhel-${os_major}-${arch}-rpms"
    maintenance_repo="satellite-maintenance-${next}-for-rhel-${os_major}-${arch}-rpms"
    if ! grep -Fxq "$repo" <<<"$repos"; then
      echo "No adjacent entitled Satellite release after $current."
      satellite_reboot_required
      return $?
    fi
    grep -Fxq "$maintenance_repo" <<<"$repos" || {
      echo "ERROR: Satellite $next is available but its maintenance repository is missing." >&2
      return 1
    }
    satellite_backup "$current" || return 1
    # Only update the maintenance tool here; it owns the actual server upgrade.
    dnf -y --enablerepo="$maintenance_repo" upgrade satellite-maintain rubygem-foreman_maintain || return 1
    target=$(satellite_maintenance_target) || return 1
    [ "$target" = "$next" ] || {
      echo "ERROR: Maintenance repository did not provide the supported $current -> $next upgrade." >&2
      return 1
    }
    satellite_apply_maintenance upgrade "$next" || return $?
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  exec 9>/var/lock/aap-demo-satellite-maintenance.lock
  flock -n 9 || { echo "ERROR: Satellite maintenance is already running." >&2; exit 1; }
  satellite_maintenance_main
fi
