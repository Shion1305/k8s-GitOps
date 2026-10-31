#!/bin/sh
set -eu

base=/var/lib/garm-workspaces/volumes
marker="$base/.garm-ssd-ready"

# The helper sees only this parent directory as a host mount. The marker is
# written by Ansible only after it verifies the SATA filesystem UUID.
[ -d "$base" ] && [ ! -L "$base" ] || exit 1
[ "$(readlink -f "$base")" = "$base" ] || exit 1
[ "$(stat -c '%u:%g:%a' "$base")" = '0:0:755' ] || exit 1
[ -f "$marker" ] && [ ! -L "$marker" ] || exit 1
[ "$(stat -c '%u:%g:%a' "$marker")" = '0:0:444' ] || exit 1
printf 'garm-workspaces-s2605-v1\n' | cmp -s - "$marker" || exit 1

# Only one flat PV directory in the runner Pod namespace can be created.
[ "${VOL_DIR%/*}" = "$base" ] || exit 1
name=${VOL_DIR##*/}
printf '%s' "$name" | grep -Eq '^pvc-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_github-actions-runner-pods_[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || exit 1
[ ! -L "$VOL_DIR" ] || exit 1

if [ ! -e "$VOL_DIR" ]; then
  mkdir -m 0700 -- "$VOL_DIR"
fi
[ -d "$VOL_DIR" ] && [ ! -L "$VOL_DIR" ] || exit 1
chown 1001:1001 -- "$VOL_DIR"
chmod 0700 -- "$VOL_DIR"
