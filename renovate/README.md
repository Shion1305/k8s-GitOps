# Renovate - Self-Hosted Dependency Update Bot

Self-hosted Renovate instance running as a Kubernetes CronJob, managing dependencies across all repositories under Shion1305 and connected organizations.

## Configuration

- **Schedule**: Every 6 hours (`0 */6 * * *`)
- **Authentication**: GitHub App with installation-scoped tokens
- **Autodiscovery**: Enabled with filters for Shion1305/* and connected orgs
- **Archived repos**: Automatically excluded
- **Supported managers**: ArgoCD, Docker, GitHub Actions, Helm, Kubernetes, Kustomize

## GitHub App Requirements

**Repository Permissions**: Contents, Issues, Pull Requests, Commit Statuses, Checks, Workflows (R/W) | Administration, Dependabot Alerts, Metadata (Read)
**Organization Permissions**: Members (Read)

## Secret Management

Required fields in `renovate-secret` (namespace: `renovate`):

```yaml
stringData:
  RENOVATE_APP_ID: "<github-app-id>"
  RENOVATE_APP_PRIVATE_KEY: "<github-app-private-key-pem>"
  RENOVATE_GIT_PRIVATE_KEY: "<gpg-private-key-armored>"  # Optional: for commit signing
```

**Authentication**: GitHub App generates installation tokens automatically for each org. Tokens are short-lived (1h) and auto-refreshed.

**Commit Signing**:

- Git author: `Automation by Shion1305 <bot@github.shion.pro>`
- GPG key must be unprotected (no passphrase) for headless operation
- Add GPG public key to GitHub to enable "Verified" badges

## Key Configuration (values.yaml)

**Schedule**: `0 */6 * * *` (modify `cronjob.schedule`)
**Resources**: 2 CPU / 2Gi memory limit, 500m / 512Mi requests
**PR Limits**: 10 concurrent, 2 per hour
**Onboarding**: Enabled (creates renovate.json PRs for unconfigured repos)

## Monitoring

```bash
# View CronJob and recent jobs
kubectl get cronjobs,jobs -n renovate

# Check logs
kubectl logs -n renovate -l app.kubernetes.io/name=renovate --tail=100

# Latest job logs
kubectl logs -n renovate job/renovate-<timestamp> -f
```

## References

- [Renovate Docs](https://docs.renovatebot.com/) | [Self-Hosted Config](https://docs.renovatebot.com/self-hosted-configuration/)
- [GitHub App Setup](https://docs.renovatebot.com/modules/platform/github/) | [Helm Chart](https://github.com/renovatebot/helm-charts)
