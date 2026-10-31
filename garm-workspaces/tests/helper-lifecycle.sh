#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
image='docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'
volume="garm-workspaces-helper-test-$$"

docker volume create "$volume" >/dev/null
trap 'docker volume rm -f "$volume" >/dev/null' EXIT

docker run --rm \
  --volume "$volume:/var/lib/garm-workspaces/volumes" \
  --volume "$script_dir:/scripts:ro" \
  "$image" sh -ec '
    base=/var/lib/garm-workspaces/volumes
    marker="$base/.garm-ssd-ready"
    valid="$base/pvc-12345678-1234-1234-1234-123456789abc_github-actions-runner-pods_canary"
    export VOL_DIR="$valid"

    # Without the Ansible-issued marker, setup must fail and create nothing.
    if sh /scripts/setup.sh >/dev/null 2>&1; then exit 1; fi
    [ ! -e "$valid" ]

    printf "garm-workspaces-s2605-v1\n" > "$marker"
    chmod 0444 "$marker"
    sh /scripts/setup.sh
    [ "$(stat -c "%u:%g:%a" "$valid")" = "1001:1001:700" ]
    printf payload > "$valid/output"

    # An unexpected path and a symlink must never be removed.
    export VOL_DIR="$base/../outside"
    if sh /scripts/teardown.sh >/dev/null 2>&1; then exit 1; fi
    [ -f "$valid/output" ]
    export VOL_DIR="$base/pvc-12345678-1234-1234-1234-123456789abc_github-actions-runner-pods_symlink"
    ln -s "$valid" "$VOL_DIR"
    if sh /scripts/teardown.sh >/dev/null 2>&1; then exit 1; fi
    [ -L "$VOL_DIR" ]
    rm "$VOL_DIR"

    export VOL_DIR="$valid"
    mv "$marker" "$marker.disabled"
    if sh /scripts/teardown.sh >/dev/null 2>&1; then exit 1; fi
    [ -f "$valid/output" ]
    mv "$marker.disabled" "$marker"
    mkdir "$base/unrelated"
    sh /scripts/teardown.sh
    [ ! -e "$valid" ]
    [ -d "$base/unrelated" ]
    [ -f "$marker" ]
  '

echo 'GARM workspace setup/teardown guards passed'
