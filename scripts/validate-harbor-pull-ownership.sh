#!/usr/bin/env bash
# ESO consumer namespaces must not also be clone targets for Kyverno.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
consumers=$(yq -o=json '.' "${root}/harbor-pull/cluster-external-secret.yaml" | jq -r '.spec.namespaceSelector.matchExpressions[] | select(.key == "kubernetes.io/metadata.name" and .operator == "In") | .values[]')
excluded=$(yq -o=json '.' "${root}/kyverno-policies/harbor-pull-injection.yaml" | jq -r '.spec.rules[] | select(.name == "generate-harbor-pull-secret") | .exclude.any[].resources.namespaces[]')
failed=0
while IFS= read -r namespace; do
  # The canonical clone source is not a generated consumer secret.
  [[ "$namespace" == "harbor-pull-source" ]] && continue
  if ! grep -Fxq -- "$namespace" <<<"$excluded"; then
    printf 'Harbor pull secret has two controllers in namespace: %s\n' "$namespace" >&2
    failed=1
  fi
done <<<"$consumers"
exit "$failed"
