#!/bin/bash
# SPDX-License-Identifier: MIT
#
# GARM-compatible entrypoint, based on the upstream garm-provider-k8s runner
# entrypoint. Keep this image on the official actions/runner base, but let
# GARM provide the metadata and callback URLs needed for ephemeral runners.

set -e
set -o pipefail

RUNNER_ASSETS_DIR=${RUNNER_ASSETS_DIR:-/home/runner}
RUNNER_HOME=${RUNNER_HOME:-/runner}

if [ ! -d "${RUNNER_HOME}" ]; then
  echo "$RUNNER_HOME should be an emptyDir mount. Please fix the pod spec."
  exit 1
fi

if [ -z "$METADATA_URL" ]; then
    echo "no token is available and METADATA_URL is not set"
    exit 1
fi

if [ -z "$CALLBACK_URL" ]; then
    echo "CALLBACK_URL is not set"
    exit 1
fi

function call() {
    PAYLOAD="$1"
    local cb_url=$CALLBACK_URL
    [[ $cb_url =~ ^(.*)/status(/)?$ ]] || cb_url="${cb_url}/status"
    curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s -X POST -d "${PAYLOAD}" -H 'Accept: application/json' -H "Authorization: Bearer ${BEARER_TOKEN}" "${cb_url}" || echo "failed to call home: exit code ($?)"
}

function systemInfo() {
    if [ -f "/etc/os-release" ]; then
        . /etc/os-release
    fi
    local cb_url=$CALLBACK_URL
    OS_NAME=${NAME:-""}
    OS_VERSION=${VERSION_ID:-""}
    AGENT_ID=${1:-null}
    [[ $cb_url =~ ^(.*)/status(/)?$ ]] && cb_url="${BASH_REMATCH[1]}" || true
    SYSINFO_URL="${cb_url}/system-info/"
    PAYLOAD="{\"os_name\": \"$OS_NAME\", \"os_version\": \"$OS_VERSION\", \"agent_id\": $AGENT_ID}"
    curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s -X POST -d "${PAYLOAD}" -H 'Accept: application/json' -H "Authorization: Bearer ${BEARER_TOKEN}" "${SYSINFO_URL}" || true
}

function sendStatus() {
    MSG="$1"
    call "{\"status\": \"installing\", \"message\": \"$MSG\"}"
}

function fail() {
    MSG="$1"
    call "{\"status\": \"failed\", \"message\": \"$MSG\"}"
    exit 1
}

function success() {
    MSG="$1"
    ID=${2:-null}
    if [ "$JIT_CONFIG_ENABLED" != "true" ] && [ "$ID" == "null" ]; then
        fail "agent ID is required when JIT_CONFIG_ENABLED is not true"
    fi

    call "{\"status\": \"idle\", \"message\": \"$MSG\", \"agent_id\": $ID}"
}

function getRunnerFile() {
    curl --retry 5 --retry-delay 5 \
        --retry-connrefused --fail -s \
        -X GET -H 'Accept: application/json' \
        -H "Authorization: Bearer ${BEARER_TOKEN}" \
        "${METADATA_URL}/$1" -o "$2"
}

function check_runner {
    set +e
    echo "Checking runner health..."
    RETRIES=0
    MAX_RETRIES=15

    while true; do
        if [[ $RETRIES -eq $MAX_RETRIES ]]; then
          echo "failed to start runner"
          fail "failed to start runner"
        fi

        AGENT_ID=""
        if [ -f "$RUNNER_HOME"/.runner ]; then

          AGENT_ID=$(grep -io '"[aA]gent[iI]d": [0-9]*' "$RUNNER_HOME"/.runner | sed 's/.*[aA]gent[iI]d": \([0-9]*\).*/\1/')
          if [ "$JIT_CONFIG_ENABLED" == "true" ]; then
            AGENT_ID=$(grep -ioE '"[aA]gent[iI]d":"?[0-9]+"?' "$RUNNER_HOME"/.runner | sed -E 's/.*[aA]gent[iI]d"?: ?"([0-9]+)".*/\1/')
          fi

          echo "Calling $CALLBACK_URL with $AGENT_ID"
          systemInfo "$AGENT_ID"
          success "runner successfully installed" "$AGENT_ID"
          break
        fi

        RETRIES=$(expr $RETRIES + 1)
        echo "RETRIES: $RETRIES"
        sleep 10
    done
    set -e
}

shopt -s dotglob
cp -r "$RUNNER_ASSETS_DIR"/* "$RUNNER_HOME"/
shopt -u dotglob

pushd "$RUNNER_HOME"

sendStatus "configuring runner"
if [ "$JIT_CONFIG_ENABLED" == "true" ]; then
    sendStatus "downloading JIT credentials"
    getRunnerFile "credentials/runner" "$RUNNER_HOME/.runner" || fail "failed to get runner file"
    getRunnerFile "credentials/credentials" "$RUNNER_HOME/.credentials" || fail "failed to get credentials file"
    getRunnerFile "credentials/credentials_rsaparams" "$RUNNER_HOME/.credentials_rsaparams" || fail "failed to get credentials_rsaparams file"
else
    if [ -n "${RUNNER_ORG}" ] && [ -n "${RUNNER_REPO}" ]; then
        ATTACH="${RUNNER_ORG}/${RUNNER_REPO}"
    elif [ -n "${RUNNER_ORG}" ]; then
        ATTACH="${RUNNER_ORG}"
    elif [ -n "${RUNNER_REPO}" ]; then
        ATTACH="${RUNNER_REPO}"
    elif [ -n "${RUNNER_ENTERPRISE}" ]; then
        ATTACH="enterprises/${RUNNER_ENTERPRISE}"
    else
        fail 'At least one of RUNNER_ORG, RUNNER_REPO, or RUNNER_ENTERPRISE must be set'
        exit 1
    fi

    REPO_URL="${GITHUB_URL}/${ATTACH}"

    config_args=()
    if [ "${RUNNER_FEATURE_FLAG_ONCE:-}" != "true" ] && [ "${RUNNER_EPHEMERAL}" == "true" ]; then
      config_args+=(--ephemeral)
    fi
    if [ "${DISABLE_RUNNER_UPDATE:-}" == "true" ]; then
      config_args+=(--disableupdate)
    fi
    if [ "${RUNNER_NO_DEFAULT_LABELS:-}" == "true" ]; then
      config_args+=(--no-default-labels)
    fi
    if [ -n "$RUNNER_GROUP" ] && [ "$RUNNER_GROUP" != "default" ]; then
        config_args+=(--runnergroup "$RUNNER_GROUP")
    fi

    GITHUB_TOKEN=$(curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s -X GET -H 'Accept: application/json' -H "Authorization: Bearer ${BEARER_TOKEN}" "${METADATA_URL}/runner-registration-token/")
    set +e
    attempt=1
    while true; do
        ERROUT=$(mktemp)

        if ./config.sh --unattended \
            --url "$REPO_URL" \
            --token "$GITHUB_TOKEN" \
            --name "$RUNNER_NAME" \
            --labels "$RUNNER_LABELS" \
            --work "${RUNNER_WORKDIR}" "${config_args[@]}" 2>"$ERROUT"
        then
            rm "$ERROUT" || true
            sendStatus "runner successfully configured after $attempt attempt(s)"
            break
        fi

        LAST_ERR=$(cat "$ERROUT")
        echo "$LAST_ERR"

        ./config.sh remove --token "$GITHUB_TOKEN" || true

        if [ $attempt -gt 5 ]; then
            rm "$ERROUT" || true
            fail "failed to configure runner: $LAST_ERR"
        fi

        sendStatus "failed to configure runner (attempt $attempt): $LAST_ERR (retrying in 5 seconds)"
        attempt=$((attempt + 1))
        rm "$ERROUT" || true
        sleep 5
    done
    set -e
fi

# Point Docker Buildx at the in-cluster rootless BuildKit (../../buildkit) so
# workflows can run `docker build` / `docker buildx build --push` unchanged with
# no Docker daemon in this pod. The remote driver only records the endpoint (it
# starts nothing locally), and `buildx install` aliases `docker build` to buildx.
# Failures here must never block runner startup.
BUILDKIT_REMOTE_ENDPOINT=${BUILDKIT_REMOTE_ENDPOINT:-tcp://buildkitd.buildkit.svc.cluster.local:1234}
if command -v docker >/dev/null 2>&1; then
  docker buildx create --name incluster --driver remote "$BUILDKIT_REMOTE_ENDPOINT" --use >/dev/null 2>&1 || true
  docker buildx install >/dev/null 2>&1 || true
fi

check_runner &

./run.sh "$@"
