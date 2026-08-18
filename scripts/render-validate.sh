#!/usr/bin/env bash
# Render every ArgoCD Application in apps/ and validate the output against
# Kubernetes + CRD schemas with kubeconform. Designed to run identically in
# local dev and in CI.
#
# Exit codes:
#   0  every app renders and validates clean
#   1  one or more apps failed (render error, kubeconform error, or schema miss)
#
# Required tools: helm, kustomize, kubeconform, yq, jq.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="${ROOT}/apps"
ALLOWLIST_FILE="${ROOT}/scripts/render-validate.allowlist"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Apps to render but tolerate validation failure for (upstream chart bugs).
declare -A ALLOWED_FAILURE
if [[ -f "${ALLOWLIST_FILE}" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -z "${line}" ]] && continue
    ALLOWED_FAILURE["${line}"]=1
  done <"${ALLOWLIST_FILE}"
fi

# Pinned k8s API version to validate against. Bump when the cluster upgrades.
K8S_VERSION="${K8S_VERSION:-1.31.0}"

# CRD schema sources (datreeio mirror of the CNCF CRD catalog + per-project
# schema repos). kubeconform tries each in order; first hit wins.
SCHEMA_LOCATIONS=(
  "default"
  "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
)

# CRD groups we accept as "schema unavailable" rather than failing the build.
# kubeconform's --strict flag rejects unknown kinds; this lets us allowlist
# CRDs whose schemas aren't published anywhere we can fetch them.
SKIP_KINDS=(
  # Argo CRDs (Application/ApplicationSet are managed by argocd itself)
  "Application"
  "ApplicationSet"
  "AppProject"
)

declare -a FAILED_APPS=()
declare -a SKIPPED_APPS=()
declare -a ALLOWED_FAILED_APPS=()

log()  { printf '%s\n' "$*" >&2; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }

# HTTPRoute matches contain routing semantics (path, method, headers, and
# query parameters). Ignoring the entire list makes ArgoCD report path changes
# as Synced without applying them. Admission's exact catch-all default may be
# ignored conditionally, but never the whole field.
validate_argocd_diff_safety() {
  local http_route_ignores ignore_program explicit_route near_default_route
  local default_route
  http_route_ignores="$(
    yq -o=json \
      '.configs.cm."resource.customizations.ignoreDifferences.gateway.networking.k8s.io_HTTPRoute" | from_yaml' \
      "${ROOT}/argocd/values.yaml"
  )"
  if ! ignore_program="$(
    jq -er '
      .jqPathExpressions
      | select(type == "array" and length > 0)
      | "del((" + join("), (") + "))"
    ' <<<"${http_route_ignores}"
  )"; then
    fail "argocd: HTTPRoute ignore-difference expressions are missing or invalid"
    return 1
  fi

  explicit_route="$(
    jq -cn '{
      spec: {
        parentRefs: [{group: "gateway.networking.k8s.io", kind: "Gateway"}],
        rules: [{
          backendRefs: [{group: "", kind: "Service", weight: 1}],
          matches: [{
            path: {type: "Exact", value: "/must-remain"},
            method: "GET",
            headers: [{name: "x-atc-test", value: "present"}],
            queryParams: [{name: "mode", value: "safe"}]
          }, {
            path: {type: "PathPrefix", value: "/"},
            method: "POST",
            headers: [{name: "x-near-default", value: "constrained"}],
            queryParams: [{name: "scope", value: "narrow"}]
          }]
        }]
      }
    }'
  )"
  if ! jq -e "${ignore_program} | .spec.rules[0].matches == [{
    \"path\":{\"type\":\"Exact\",\"value\":\"/must-remain\"},
    \"method\":\"GET\",
    \"headers\":[{\"name\":\"x-atc-test\",\"value\":\"present\"}],
    \"queryParams\":[{\"name\":\"mode\",\"value\":\"safe\"}]
  }, {
    \"path\":{\"type\":\"PathPrefix\",\"value\":\"/\"},
    \"method\":\"POST\",
    \"headers\":[{\"name\":\"x-near-default\",\"value\":\"constrained\"}],
    \"queryParams\":[{\"name\":\"scope\",\"value\":\"narrow\"}]
  }]" >/dev/null <<<"${explicit_route}"; then
    fail "argocd: HTTPRoute ignore rules erase explicit routing semantics"
    return 1
  fi

  near_default_route="$(
    jq -cn '{
      spec: {
        parentRefs: [{group: "gateway.networking.k8s.io", kind: "Gateway"}],
        rules: [{
          backendRefs: [{group: "", kind: "Service", weight: 1}],
          matches: [{
            path: {type: "PathPrefix", value: "/"},
            method: "POST",
            headers: [{name: "x-near-default", value: "constrained"}],
            queryParams: [{name: "scope", value: "narrow"}]
          }]
        }]
      }
    }'
  )"
  if ! jq -e "${ignore_program} | .spec.rules[0].matches == [{
    \"path\":{\"type\":\"PathPrefix\",\"value\":\"/\"},
    \"method\":\"POST\",
    \"headers\":[{\"name\":\"x-near-default\",\"value\":\"constrained\"}],
    \"queryParams\":[{\"name\":\"scope\",\"value\":\"narrow\"}]
  }]" >/dev/null <<<"${near_default_route}"; then
    fail "argocd: HTTPRoute ignore rules erase a constrained catch-all match"
    return 1
  fi

  default_route="$(
    jq -cn '{
      spec: {
        parentRefs: [{group: "gateway.networking.k8s.io", kind: "Gateway"}],
        rules: [{
          backendRefs: [{group: "", kind: "Service", weight: 1}],
          matches: [{path: {type: "PathPrefix", value: "/"}}]
        }]
      }
    }'
  )"
  if ! jq -e "${ignore_program} | (.spec.rules[0] | has(\"matches\") | not)" \
    >/dev/null <<<"${default_route}"; then
    fail "argocd: HTTPRoute admission's exact catch-all default is not ignored"
    return 1
  fi
  ok "ArgoCD HTTPRoute diff coverage"
}

# Repo-server initializes submodules recursively by default, even when an
# Application only consumes a chart from the parent repository. None of this
# cluster's Git sources require submodules, and unrelated private/SSH
# submodules must not block manifest generation for an otherwise public repo.
validate_argocd_submodule_safety() {
  local enabled
  enabled="$(
    yq -r '.configs.params."reposerver.enable.git.submodule" // "true"' \
      "${ROOT}/argocd/values.yaml"
  )"
  if [[ "${enabled}" != "false" ]]; then
    fail "argocd: repo-server Git submodules must be explicitly disabled"
    return 1
  fi
  ok "ArgoCD Git submodule policy"
}

# The deployed media-server image reads HF_HOME before huggingface_hub can
# create it. Point directly at the chart's existing persistent cache mount so
# startup cannot fail on a missing subdirectory and partial downloads survive
# container restarts.
validate_whisper_cache_safety() {
  local values_file hf_home progress_deadline
  values_file="${ROOT}/whisper/values.yaml"
  hf_home="$(
    yq -r '
      .defaults.extraEnv[]?
      | select(.name == "HF_HOME")
      | .value // ""
    ' "${values_file}"
  )"
  if [[ "${hf_home}" != "/home/container_app_user/cache_root" ]]; then
    fail "whisper: HF_HOME must use the existing persistent cache mount root"
    return 1
  fi

  # This leaf overrides defaults in the pinned upstream chart. Twelve hours
  # tolerates the observed slow Hub transfer; the persistent cache still lets
  # a later restart resume if the transfer takes longer.
  progress_deadline="$(
    yq -r '
      .models.whisper-large-v3.media.p150.impls.whisper.progressDeadlineSeconds // 0
    ' "${values_file}"
  )"
  if [[ ! "${progress_deadline}" =~ ^[0-9]+$ ]] || (( progress_deadline < 43200 )); then
    fail "whisper: model startup progress deadline must be at least 43200 seconds"
    return 1
  fi
  ok "Whisper persistent model-cache policy"
}

# Hugging Face credentials must come from the namespace-scoped Vault mount.
# Never let a token enter Helm values, and keep the ExternalSecret, Pod env,
# and Kustomize resource registration aligned.
validate_whisper_hf_token_safety() {
  local values_file external_secret inline_token secret_name secret_key
  local remote_key remote_property registered
  values_file="${ROOT}/whisper/values.yaml"
  external_secret="${ROOT}/whisper/hf-token.yaml"

  inline_token="$(yq -r '.hfToken // ""' "${values_file}")"
  if [[ -n "${inline_token}" ]]; then
    fail "whisper: hfToken must remain empty; use the Vault-backed Secret"
    return 1
  fi

  secret_name="$(
    yq -r '
      .defaults.extraEnv[]?
      | select(.name == "HF_TOKEN")
      | .valueFrom.secretKeyRef.name // ""
    ' "${values_file}"
  )"
  secret_key="$(
    yq -r '
      .defaults.extraEnv[]?
      | select(.name == "HF_TOKEN")
      | .valueFrom.secretKeyRef.key // ""
    ' "${values_file}"
  )"
  if [[ "${secret_name}" != "whisper-hf-token" || "${secret_key}" != "token" ]]; then
    fail "whisper: HF_TOKEN must reference whisper-hf-token/token"
    return 1
  fi

  if [[ ! -f "${external_secret}" ]]; then
    fail "whisper: Vault-backed Hugging Face ExternalSecret is missing"
    return 1
  fi
  remote_key="$(yq -r '.spec.data[0].remoteRef.key // ""' "${external_secret}")"
  remote_property="$(yq -r '.spec.data[0].remoteRef.property // ""' "${external_secret}")"
  if [[ "${remote_key}" != "huggingface" || "${remote_property}" != "token" ]]; then
    fail "whisper: Hugging Face ExternalSecret must read huggingface/token"
    return 1
  fi

  registered="$(
    yq -r '.resources[]? | select(. == "hf-token.yaml")' \
      "${ROOT}/whisper/kustomization.yaml"
  )"
  if [[ "${registered}" != "hf-token.yaml" ]]; then
    fail "whisper: hf-token.yaml must be registered in the Kustomization"
    return 1
  fi
  ok "Whisper Vault-backed Hugging Face token policy"
}

# Extract a field from an ArgoCD Application manifest. Returns empty string if
# the field is missing — callers MUST handle the empty case explicitly.
yq_get() {
  local file="$1" query="$2"
  yq -r "${query} // \"\"" "${file}"
}

# Convert a Helm repoURL into a form `helm pull` accepts. ArgoCD accepts
# `docker.io/envoyproxy` as an OCI chart repo; helm CLI wants `oci://...`.
normalize_repo_url() {
  local url="$1"
  case "${url}" in
    http://*|https://*|oci://*) printf '%s' "${url}" ;;
    *) printf 'oci://%s' "${url}" ;;
  esac
}

render_helm_source() {
  # $1 = app name, $2 = source index, $3 = source JSON
  local app="$1" idx="$2" src="$3"
  local repo chart version release_name
  repo=$(jq -r '.repoURL' <<<"${src}")
  chart=$(jq -r '.chart' <<<"${src}")
  version=$(jq -r '.targetRevision' <<<"${src}")
  release_name=$(jq -r '.helm.releaseName // ""' <<<"${src}")
  [[ -z "${release_name}" ]] && release_name="${app}"

  local repo_norm chart_dir
  repo_norm=$(normalize_repo_url "${repo}")
  chart_dir="${WORK_DIR}/${app}-helm-${idx}"
  mkdir -p "${chart_dir}"

  if [[ "${repo_norm}" == oci://* ]]; then
    helm pull "${repo_norm}/${chart}" --version "${version}" --untar \
      --untardir "${chart_dir}" >/dev/null 2>&1 \
      || { fail "${app}: helm pull failed (${repo_norm}/${chart}@${version})"; return 1; }
  else
    helm pull "${chart}" --repo "${repo_norm}" --version "${version}" --untar \
      --untardir "${chart_dir}" >/dev/null 2>&1 \
      || { fail "${app}: helm pull failed (${repo_norm} ${chart}@${version})"; return 1; }
  fi

  # Resolve $values/<path> against repo root; raw value files live under
  # ROOT in the working tree.
  local -a helm_args=("template" "${release_name}" "${chart_dir}/${chart}")
  local value_files vf vf_path
  value_files=$(jq -r '.helm.valueFiles // [] | .[]' <<<"${src}")
  while IFS= read -r vf; do
    [[ -z "${vf}" ]] && continue
    # Substitute $values/ prefix with repo root.
    vf_path="${vf/#\$values\//${ROOT}/}"
    if [[ ! -f "${vf_path}" ]]; then
      fail "${app}: values file ${vf} (resolved: ${vf_path}) not found"
      return 1
    fi
    helm_args+=("-f" "${vf_path}")
  done <<<"${value_files}"

  # Helm --set parameters from sources[].helm.parameters
  local params name value
  params=$(jq -c '.helm.parameters // [] | .[]' <<<"${src}")
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    name=$(jq -r '.name' <<<"${p}")
    value=$(jq -r '.value' <<<"${p}")
    helm_args+=("--set" "${name}=${value}")
  done <<<"${params}"

  # Namespace from spec.destination.namespace (best-effort — used by some
  # charts for default ServiceAccount targeting).
  helm_args+=("--namespace" "${app}")

  if ! helm "${helm_args[@]}" 2>"${WORK_DIR}/${app}-helm.err"; then
    fail "${app}: helm template failed"
    cat "${WORK_DIR}/${app}-helm.err" >&2
    return 1
  fi
}

render_path_source() {
  # $1 = app name, $2 = source index, $3 = path, $4 = optional dir override,
  # $5 = optional source JSON (for Helm options on path-based charts)
  # (used when the path lives inside a cloned external repo).
  local app="$1" idx="$2" path="$3" dir_override="${4:-}" src="${5:-}"
  local dir
  if [[ -n "${dir_override}" ]]; then
    dir="${dir_override}/${path}"
  else
    dir="${ROOT}/${path}"
  fi

  if [[ ! -d "${dir}" ]]; then
    fail "${app}: source path '${path}' does not exist (resolved: ${dir})"
    return 1
  fi

  if [[ -f "${dir}/kustomization.yaml" || -f "${dir}/kustomization.yml" ]]; then
    if ! kustomize build "${dir}" 2>"${WORK_DIR}/${app}-kustomize.err"; then
      fail "${app}: kustomize build failed for ${path}"
      cat "${WORK_DIR}/${app}-kustomize.err" >&2
      return 1
    fi
  elif compgen -G "${dir}/Chart.yaml" >/dev/null 2>&1; then
    # In-repo (or cloned) Helm chart. Some apps use an external git repo whose
    # path points at a chart directory rather than a chart-repo entry. Honor
    # the same releaseName, valueFiles, and parameters Argo CD applies.
    local release_name="${app}"
    if [[ -n "${src}" ]]; then
      release_name=$(jq -r '.helm.releaseName // ""' <<<"${src}")
      [[ -z "${release_name}" ]] && release_name="${app}"
    fi

    local -a helm_args=("template" "${release_name}" "${dir}")
    local value_files vf vf_path
    if [[ -n "${src}" ]]; then
      value_files=$(jq -r '.helm.valueFiles // [] | .[]' <<<"${src}")
      while IFS= read -r vf; do
        [[ -z "${vf}" ]] && continue
        if [[ "${vf}" == \$values/* ]]; then
          vf_path="${vf/#\$values\//${ROOT}/}"
        else
          vf_path="${dir}/${vf}"
        fi
        if [[ ! -f "${vf_path}" ]]; then
          fail "${app}: values file ${vf} (resolved: ${vf_path}) not found"
          return 1
        fi
        helm_args+=("-f" "${vf_path}")
      done <<<"${value_files}"

      local params p name value
      params=$(jq -c '.helm.parameters // [] | .[]' <<<"${src}")
      while IFS= read -r p; do
        [[ -z "${p}" ]] && continue
        name=$(jq -r '.name' <<<"${p}")
        value=$(jq -r '.value' <<<"${p}")
        helm_args+=("--set" "${name}=${value}")
      done <<<"${params}"
    fi
    helm_args+=("--namespace" "${app}")

    if ! helm "${helm_args[@]}" \
        2>"${WORK_DIR}/${app}-helm.err"; then
      fail "${app}: helm template failed for in-tree chart ${path}"
      cat "${WORK_DIR}/${app}-helm.err" >&2
      return 1
    fi
  else
    # Raw-manifest dir: concat all *.yaml files except values.yaml (helm input,
    # not a manifest) and README/other non-YAML. Ensure a trailing newline so
    # the next `---` separator lands on its own line even when a file omits
    # the terminating LF.
    local f
    for f in "${dir}"/*.yaml "${dir}"/*.yml; do
      [[ -e "${f}" ]] || continue
      [[ "$(basename "${f}")" == "values.yaml" ]] && continue
      printf -- '---\n'
      cat "${f}"
      # Some files omit the terminating LF; emit one so the next `---`
      # separator lands on its own line.
      if [[ "$(tail -c1 "${f}" | wc -l)" -eq 0 ]]; then
        printf '\n'
      fi
    done
  fi
}

# Shallow-clone an external git repo to a deterministic dir under WORK_DIR
# and echo the dir path. Used for ArgoCD path-sources that live in upstream
# repos (e.g. kubernetes-sigs/gateway-api).
clone_external_repo() {
  local repo="$1" rev="$2"
  local key
  key=$(printf '%s@%s' "${repo}" "${rev}" | shasum -a 256 | cut -c1-12)
  local dir="${WORK_DIR}/clones/${key}"
  if [[ -d "${dir}/.git" ]]; then
    printf '%s' "${dir}"
    return 0
  fi
  mkdir -p "${dir}"
  if ! git clone --depth=1 --branch "${rev}" --quiet "${repo}" "${dir}" 2>"${WORK_DIR}/clone.err"; then
    # Some revisions are commit SHAs rather than tags/branches; fall back to
    # a full clone + checkout.
    rm -rf "${dir}"
    if git clone --quiet "${repo}" "${dir}" 2>>"${WORK_DIR}/clone.err" \
       && git -C "${dir}" checkout --quiet "${rev}" 2>>"${WORK_DIR}/clone.err"; then
      printf '%s' "${dir}"
      return 0
    fi
    cat "${WORK_DIR}/clone.err" >&2
    return 1
  fi
  printf '%s' "${dir}"
}

# True if the given URL points at an external git repo (anything except this
# repo or a helm chart repo). Helm chart sources have `.chart` set, which is
# checked at the caller site.
is_external_git_repo() {
  local url="$1"
  case "${url}" in
    *://github.com/Shion1305/k8s-GitOps.git|*://github.com/Shion1305/k8s-GitOps) return 1 ;;
    http*.git|http*/) return 0 ;;
    http*://github.com/*|http*://gitlab.com/*|git@*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_app() {
  local app_file="$1"
  local app_name
  app_name=$(yq_get "${app_file}" '.metadata.name')
  [[ -z "${app_name}" ]] && { fail "${app_file}: missing .metadata.name"; return 1; }

  local rendered="${WORK_DIR}/${app_name}.yaml"
  : >"${rendered}"

  # Two shapes: spec.sources[] (multi-source) or spec.source (single).
  local has_sources
  has_sources=$(yq_get "${app_file}" '.spec.sources | type')

  if [[ "${has_sources}" == "!!seq" ]]; then
    # Multi-source. Render each source that is either a Helm chart or a
    # path:; skip ref:-only sources (they only carry values for $values
    # substitution and aren't rendered themselves).
    local sources_json idx=0
    sources_json=$(yq -o=json '.spec.sources' "${app_file}")
    local count
    count=$(jq 'length' <<<"${sources_json}")
    local i
    for ((i=0; i<count; i++)); do
      local src
      src=$(jq -c ".[${i}]" <<<"${sources_json}")
      local chart path ref
      chart=$(jq -r '.chart // ""' <<<"${src}")
      path=$(jq -r '.path // ""' <<<"${src}")
      ref=$(jq -r '.ref // ""' <<<"${src}")

      if [[ -n "${chart}" ]]; then
        printf -- '---\n' >>"${rendered}"
        render_helm_source "${app_name}" "${idx}" "${src}" >>"${rendered}" || return 1
        idx=$((idx+1))
      elif [[ -n "${path}" ]]; then
        local repo rev clone_dir="" target_dir_override=""
        repo=$(jq -r '.repoURL' <<<"${src}")
        rev=$(jq -r '.targetRevision' <<<"${src}")
        if is_external_git_repo "${repo}"; then
          if ! clone_dir=$(clone_external_repo "${repo}" "${rev}"); then
            fail "${app_name}: failed to clone ${repo}@${rev}"
            return 1
          fi
          target_dir_override="${clone_dir}"
        fi
        printf -- '---\n' >>"${rendered}"
        render_path_source "${app_name}" "${idx}" "${path}" "${target_dir_override}" "${src}" \
          >>"${rendered}" || return 1
        idx=$((idx+1))
      elif [[ -n "${ref}" ]]; then
        : # values-only ref source, skip
      else
        warn "${app_name}: source #${i} has neither chart, path, nor ref — skipping"
      fi
    done
  else
    # Single source.
    local chart path
    chart=$(yq_get "${app_file}" '.spec.source.chart')
    path=$(yq_get "${app_file}" '.spec.source.path')
    if [[ -n "${chart}" ]]; then
      local src
      src=$(yq -o=json '.spec.source' "${app_file}")
      render_helm_source "${app_name}" 0 "${src}" >>"${rendered}" || return 1
    elif [[ -n "${path}" ]]; then
      local repo rev clone_dir="" target_dir_override="" src
      repo=$(yq_get "${app_file}" '.spec.source.repoURL')
      rev=$(yq_get "${app_file}" '.spec.source.targetRevision')
      src=$(yq -o=json '.spec.source' "${app_file}")
      if is_external_git_repo "${repo}"; then
        if ! clone_dir=$(clone_external_repo "${repo}" "${rev}"); then
          fail "${app_name}: failed to clone ${repo}@${rev}"
          return 1
        fi
        target_dir_override="${clone_dir}"
      fi
      render_path_source "${app_name}" 0 "${path}" "${target_dir_override}" "${src}" \
        >>"${rendered}" || return 1
    else
      warn "${app_name}: single-source app has no chart or path — skipping"
      SKIPPED_APPS+=("${app_name}")
      return 0
    fi
  fi

  if [[ ! -s "${rendered}" ]]; then
    warn "${app_name}: rendered output was empty — skipping kubeconform"
    SKIPPED_APPS+=("${app_name}")
    return 0
  fi

  local -a kc_args=(
    "-strict"
    "-summary"
    "-kubernetes-version" "${K8S_VERSION}"
    "-ignore-missing-schemas"
  )
  local loc
  for loc in "${SCHEMA_LOCATIONS[@]}"; do
    kc_args+=("-schema-location" "${loc}")
  done
  local k
  for k in "${SKIP_KINDS[@]}"; do
    kc_args+=("-skip" "${k}")
  done

  if ! kubeconform "${kc_args[@]}" "${rendered}" >"${WORK_DIR}/${app_name}.kc.out" 2>&1; then
    if [[ -n "${ALLOWED_FAILURE[${app_name}]:-}" ]]; then
      warn "${app_name}: kubeconform failed (allowlisted — see scripts/render-validate.allowlist)"
      sed 's/^/    /' "${WORK_DIR}/${app_name}.kc.out" >&2
      ALLOWED_FAILED_APPS+=("${app_name}")
      return 0
    fi
    fail "${app_name}: kubeconform failed"
    cat "${WORK_DIR}/${app_name}.kc.out" >&2
    return 1
  fi
  # The app actually passed but is listed in the allowlist — surface that so
  # the entry can be removed.
  if [[ -n "${ALLOWED_FAILURE[${app_name}]:-}" ]]; then
    warn "${app_name}: now passes — drop from scripts/render-validate.allowlist"
  fi
  ok "${app_name}"
}

main() {
  local app_file
  validate_argocd_diff_safety || exit 1
  validate_argocd_submodule_safety || exit 1
  validate_whisper_cache_safety || exit 1
  validate_whisper_hf_token_safety || exit 1

  for app_file in "${APPS_DIR}"/*.yaml; do
    [[ -e "${app_file}" ]] || continue
    if ! validate_app "${app_file}"; then
      FAILED_APPS+=("$(basename "${app_file}")")
    fi
  done

  echo
  if (( ${#SKIPPED_APPS[@]} > 0 )); then
    log "Skipped (no renderable source): ${SKIPPED_APPS[*]}"
  fi
  if (( ${#ALLOWED_FAILED_APPS[@]} > 0 )); then
    warn "Allowlisted failures (${#ALLOWED_FAILED_APPS[@]}): ${ALLOWED_FAILED_APPS[*]}"
  fi
  if (( ${#FAILED_APPS[@]} > 0 )); then
    fail "Failed apps (${#FAILED_APPS[@]}): ${FAILED_APPS[*]}"
    exit 1
  fi
  ok "All apps rendered and validated."
}

main "$@"
