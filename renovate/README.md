# Renovate - Self-Hosted Dependency Update Bot

Self-hosted Renovate instance running as a Kubernetes CronJob, automatically managing dependencies across all GitHub App installations.

## Architecture

**Single CronJob** with intelligent installation discovery:
1. Generates JWT from GitHub App credentials
2. Calls GitHub API to discover all installations
3. For each installation, generates a fresh JWT and access token, then runs Renovate
4. Processes all installations sequentially in a single job

App JWTs expire after 10 minutes, so they must be regenerated before each
installation token request. A single account's Renovate run can take longer
than that. If any installation fails, the wrapper continues with the remaining
installations and exits nonzero so Kubernetes records the failure.

**Components:**
- **Helm Chart**: ServiceAccount, RBAC, CronJob, ConfigMap (Renovate config)
- **Wrapper Script**: Automates installation discovery and token generation
- **ConfigMap**: Contains the wrapper script (`run-renovate.sh`)

## Configuration

- **Schedule**: Every hour (`0 * * * *`)
- **Authentication**: GitHub App with automatic installation discovery
- **Autodiscovery**: Enabled with filters for Shion1305/* and connected orgs
- **Archived repos**: Automatically excluded
- **Supported managers**: Infrastructure manifests and language package managers;
  see `enabledManagers` in `values.yaml` for the full list

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
  RENOVATE_PLATFORM: "github"
```

**How it works:**
1. Wrapper script generates JWT from App ID + Private Key
2. Calls `GET /app/installations` to list all installations
3. For each installation, regenerates the App JWT and generates a short-lived access token
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

**Wrapper Script (`scripts-configmap.yaml`, mounted at `/scripts/`)**:
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
This includes Lumos-Programming when the app is installed there. Repository
access is controlled by the GitHub App installation. New repositories may
receive a `Configure Renovate` onboarding PR that must be merged before regular
dependency update PRs are created.

## Monitoring

```bash
# View CronJob status
kubectl get cronjobs -n renovate

# Check recent jobs
kubectl get jobs -n renovate

# View logs from latest run
kubectl logs -n renovate -l app.kubernetes.io/name=renovate --tail=200

# Follow live logs
kubectl logs -n renovate -l app.kubernetes.io/name=renovate -f
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

**Later installations fail with `401 Bad credentials`:**
- Check that the deployed wrapper regenerates its App JWT before each token request
- An installation token is scoped to one account; do not reuse it across organizations

**Hourly jobs stop with `JobAlreadyActive`:**
- The CronJob uses `concurrencyPolicy: Forbid`, so an unfinished Job blocks later runs
- Inspect the Job's conditions and terminating Pods, including their nodes' readiness
- A replacement Pod can succeed while a Pod on an unreachable node still prevents
  the Job from reaching `Complete`; recover the node or verify the old process has
  stopped before cleaning up the stale Pod

## Wrapper Regression Tests

Run `python3 renovate/tests/test-wrapper.py` from the repository root. The tests
require `bash`, `jq`, `openssl`, and `yq`. They execute the deployed wrapper with
a fake clock, GitHub API, and Renovate command, including a first installation
that exceeds the JWT lifetime and partial installation failures. They use no
real credentials or network access and also run in manifest validation CI.

## References

- [Renovate Docs](https://docs.renovatebot.com/) | [Self-Hosted Config](https://docs.renovatebot.com/self-hosted-configuration/)
- [GitHub App Setup](https://docs.renovatebot.com/modules/platform/github/) | [Helm Chart](https://github.com/renovatebot/helm-charts)
- [GitHub App REST API](https://docs.github.com/en/rest/apps/apps)
