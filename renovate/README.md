# Renovate - Self-Hosted Dependency Update Bot

Self-hosted Renovate instance running as a Kubernetes CronJob, automatically managing dependencies across all GitHub App installations.

## Architecture

**Dual execution modes** for flexibility:

1. **Scheduled (CronJob)**: Runs every 6 hours automatically
2. **Webhook-triggered (Argo Events)**: Immediate execution on dependency dashboard changes

**Execution flow:**

1. Generates JWT from GitHub App credentials
2. Calls GitHub API to discover all installations
3. For each installation, generates access token and runs Renovate
4. Processes all installations sequentially in a single job

**Components:**

- **Renovate Helm Chart**: ServiceAccount, RBAC, CronJob, ConfigMap
- **Argo Events**: Webhook receiver (EventSource), Job trigger (Sensor), EventBus (NATS)
- **Wrapper Script**: Automates installation discovery and token generation
- **Ingress**: Exposes webhook endpoint at `renovate.k.shion1305.com`

## Configuration

- **Schedule**: Every 6 hours (`0 */6 * * *`)
- **Authentication**: GitHub App with automatic installation discovery
- **Autodiscovery**: Enabled with filters for Shion1305/* and connected orgs
- **Archived repos**: Automatically excluded
- **Supported managers**: ArgoCD, Docker, GitHub Actions, Helm, Kubernetes, Kustomize

## GitHub App Requirements

**Repository Permissions**: Contents, Issues, Pull Requests, Commit Statuses, Checks, Workflows (R/W) | Administration, Dependabot Alerts, Metadata (Read)
**Organization Permissions**: Members (Read)

## Webhook Configuration

**Webhook URL**: `https://renovate.k.shion1305.com/webhook`

To enable webhook triggering, configure in GitHub App settings:

1. Go to GitHub App Settings → Webhooks
2. Set Payload URL: `https://renovate.k.shion1305.com/webhook`
3. Set Content type: `application/json`
4. Set Secret: (same value as `github-webhook-secret`)
5. Select events: **Issues**, **Issue comments**
6. Ensure webhook is Active

**Triggered events:**

- Dependency Dashboard checkbox edits (issues events)
- Comments on Renovate PRs (issue_comment events, e.g., "rebase")

**Scope:** Webhook-triggered jobs run ONLY for the specific repository that sent the webhook, not all repositories.

**Webhook secret** (`github-webhook-secret`):

```bash
kubectl create secret generic github-webhook-secret -n renovate \
  --from-literal=secret=<your-webhook-secret>
```

## Secret Management

Required fields in `renovate-secret` (namespace: `renovate`):

```yaml
stringData:
  RENOVATE_APP_ID: "<github-app-id>"
  RENOVATE_APP_PRIVATE_KEY: "<github-app-private-key-pem>"
  RENOVATE_GIT_PRIVATE_KEY: "<gpg-private-key-armored>"  # Optional: for commit signing
  RENOVATE_PLATFORM: "github"
```

**How it works:**

1. Wrapper script generates JWT from App ID + Private Key
2. Calls `GET /app/installations` to list all installations
3. For each installation, generates short-lived access token
4. Runs Renovate with that token

**Commit Signing**:

- Git author: `Automation by Shion1305 <bot@github.shion.pro>`
- GPG key must be unprotected (no passphrase) for headless operation
- Add GPG public key to GitHub to enable "Verified" badges

## Key Configuration

**Helm (values.yaml)**:

- CronJob enabled with wrapper script command override
- Resources: 2 CPU / 2Gi memory limit
- PR Limits: 10 concurrent, 2 per hour
- Onboarding: Enabled

**Wrapper Script (scripts/run-renovate.sh)**:

- Discovers installations automatically
- Generates JWT and installation tokens
- Runs Renovate for each installation sequentially

## Adding New Installations

**No configuration needed!** Simply install the GitHub App on a new organization:

1. Go to GitHub → Settings → Developer settings → GitHub Apps
2. Click on your Renovate app
3. Click "Install App"
4. Select the new organization
5. Choose repository access and install

The next CronJob run will automatically discover and process the new installation.

## Manual Triggering from ArgoCD UI

You can manually trigger Renovate for a specific repository using the ArgoCD UI:

1. Open ArgoCD UI → Navigate to `renovate` application
2. Click **Create** → **From YAML**
3. Copy the template from `renovate/manual-job-template.yaml`
4. Edit these values:
   - `TARGET_REPOSITORY`: Set to `"owner/repo"` (e.g., `"Shion1305/k8s-GitOps"`)
   - `INSTALLATION_ID`: Your GitHub App installation ID
5. Click **Create**
6. Monitor job in ArgoCD or via: `kubectl logs -n renovate -l job-name=<job-name> -f`

**Finding your installation ID:**

- Check GitHub App Settings → Installations → Click installation → URL contains installation ID
- Or check any webhook delivery payload: `installation.id` field

## Monitoring

```bash
# View CronJob status
kubectl get cronjobs -n renovate

# Check recent jobs (both scheduled and webhook-triggered)
kubectl get jobs -n renovate

# View webhook-triggered jobs specifically
kubectl get jobs -n renovate -l triggered-by=webhook

# View logs from latest run
kubectl logs -n renovate -l app.kubernetes.io/name=renovate --tail=200

# Follow live logs
kubectl logs -n renovate -l app.kubernetes.io/name=renovate -f

# Check Argo Events components
kubectl get eventbus,eventsource,sensor -n renovate
```

## Troubleshooting

**No installations found:**

- Verify GitHub App has been installed on at least one account/org
- Check `RENOVATE_APP_ID` and `RENOVATE_APP_PRIVATE_KEY` in secret

**Token generation failed:**

- Check GitHub App permissions are correct
- Verify App ID matches the actual GitHub App
- Ensure private key is in correct format (armored PEM)

**Renovate fails for specific installation:**

- Check that installation has access to repositories
- Verify repository permissions are granted
- Review Renovate logs for specific error

**Webhook not triggering:**

- Verify webhook is configured in GitHub App settings
- Check webhook deliveries in GitHub App → Advanced → Recent Deliveries
- Verify EventSource is running: `kubectl get pods -n renovate -l eventsource-name=renovate-github`
- Check EventSource logs: `kubectl logs -n renovate -l eventsource-name=renovate-github`
- Verify `github-webhook-secret` exists and matches GitHub App configuration
- Check Ingress is properly routing: `kubectl get ingress -n renovate renovate-webhook`

## References

- [Renovate Docs](https://docs.renovatebot.com/) | [Self-Hosted Config](https://docs.renovatebot.com/self-hosted-configuration/)
- [GitHub App Setup](https://docs.renovatebot.com/modules/platform/github/) | [Helm Chart](https://github.com/renovatebot/helm-charts)
- [GitHub App REST API](https://docs.github.com/en/rest/apps/apps)
