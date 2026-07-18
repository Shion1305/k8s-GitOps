#!/usr/bin/env bash
# Vendors the kube-prometheus-stack mixin dashboards into
# grafana/dashboards/json/ with the `datasource` template variable pinned to
# the primary Prometheus.
#
# Why: the chart-rendered dashboards ship a datasource variable with no
# regex/current, and Grafana selects the first prometheus-type datasource BY
# NAME — not the isDefault one. Any second prometheus datasource in
# main-grafana (e.g. the gh-leaked-tokens long-term instance) can therefore
# shadow the primary. Pinning the variable in the JSON removes the ambiguity
# structurally, independent of datasource names or Grafana's picker behavior.
#
# What it does:
#   1. Reads the chart repo/version from apps/grafana-app.yaml.
#   2. `helm template`s the chart with grafana/values.yaml
#      (forcing grafana.forceDeployDashboards=true for extraction only —
#      the deployed values keep it false; kustomize generates the same-name
#      ConfigMaps from the vendored files instead).
#   3. Extracts exactly the ConfigMaps referenced by the GrafanaDashboard CRs
#      in grafana/dashboards/*.yaml.
#   4. Patches every `type: datasource, query: prometheus` template variable
#      with regex /^Prometheus$/ + current=uid `prometheus`.
#   5. Writes grafana/dashboards/json/<key>, removing stale files.
#
# CI runs this and fails if the committed output differs (see
# .github/workflows/render-validate.yaml), so chart bumps that change
# dashboards force a regeneration commit.
#
# Requires: helm, yq, jq.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_MANIFEST="${ROOT}/apps/grafana-app.yaml"
OUT_DIR="${ROOT}/grafana/dashboards/json"
KUSTOMIZATION="${ROOT}/grafana/kustomization.yaml"
K8S_VERSION="${K8S_VERSION:-1.31.0}"

fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '%s\n' "$*" >&2; }

for tool in helm yq jq; do
  command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done

chart_repo=$(yq -r '.spec.sources[] | select(.chart == "kube-prometheus-stack") | .repoURL' "${APP_MANIFEST}")
chart_version=$(yq -r '.spec.sources[] | select(.chart == "kube-prometheus-stack") | .targetRevision' "${APP_MANIFEST}")
[[ -n "${chart_repo}" && -n "${chart_version}" ]] \
  || fail "could not read kube-prometheus-stack repo/version from ${APP_MANIFEST}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

log "rendering kube-prometheus-stack ${chart_version} ..."
helm template kube-prometheus-stack kube-prometheus-stack \
  --repo "${chart_repo}" \
  --version "${chart_version}" \
  --namespace grafana \
  --kube-version "${K8S_VERSION}" \
  -f "${ROOT}/grafana/values.yaml" \
  --set grafana.forceDeployDashboards=true \
  >"${WORK_DIR}/rendered.yaml" 2>"${WORK_DIR}/helm.err" \
  || { cat "${WORK_DIR}/helm.err" >&2; fail "helm template failed"; }

# The GrafanaDashboard CRs are the source of truth for which dashboards to
# vendor: extract every configMapRef (name, key) they reference.
refs_file="${WORK_DIR}/refs.txt"
for f in "${ROOT}"/grafana/dashboards/*.yaml; do
  yq -N 'select(.kind=="GrafanaDashboard") | .spec.configMapRef.name + " " + .spec.configMapRef.key' "${f}"
done | sort -u | grep -v '^ *$' >"${refs_file}"
[[ -s "${refs_file}" ]] || fail "no configMapRef entries found in grafana/dashboards/*.yaml"

mkdir -p "${OUT_DIR}"

count=0
while read -r cm_name cm_key; do
  json=$(yq "select(.kind==\"ConfigMap\" and .metadata.name==\"${cm_name}\") | .data[\"${cm_key}\"]" \
    "${WORK_DIR}/rendered.yaml")
  [[ -n "${json}" && "${json}" != "null" ]] \
    || fail "ConfigMap ${cm_name} (key ${cm_key}) not found in chart output — dropped upstream? Update grafana/dashboards/*.yaml."

  jq --indent 2 '
    (.templating.list[]? | select(.type == "datasource" and .query == "prometheus"))
      |= (. + {
        regex: "/^Prometheus$/",
        current: {selected: false, text: "Prometheus", value: "prometheus"}
      })
  ' <<<"${json}" >"${OUT_DIR}/${cm_key}" \
    || fail "jq patch failed for ${cm_key}"

  grep -q "dashboards/json/${cm_key}" "${KUSTOMIZATION}" \
    || fail "${cm_key} is not registered in ${KUSTOMIZATION} (configMapGenerator)"

  count=$((count + 1))
done <"${refs_file}"

# Remove vendored files no longer referenced by any GrafanaDashboard CR.
for f in "${OUT_DIR}"/*.json; do
  [[ -e "${f}" ]] || continue
  key=$(basename "${f}")
  grep -q " ${key}$" "${refs_file}" || { log "removing stale ${key}"; rm "${f}"; }
done

log "vendored ${count} dashboards into grafana/dashboards/json/"
