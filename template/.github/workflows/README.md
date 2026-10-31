# CI/CD Deployment Guide

Automated Docker build, Harbor publishing and remote Docker Compose deployment using GitHub Actions, OpenBao, Harbor and self-hosted ephemeral runners.

This document explains how to release an application, how release tags select deployment environments, and how GitHub Environments and OpenBao secrets are used.

## 1. Deployment overview

The deployment workflow is defined in:

```text
.github/workflows/deployment.yml
```

It is triggered by:

- Pushing a release tag matching `v*`.
- Manually starting the workflow with `workflow_dispatch` and providing a `release_tag`.

The workflow performs these operations:

1. Resolves and validates the release tag.
2. Determines the source branch, GitHub Environment and OpenBao secret path.
3. Checks that the tagged commit belongs to the expected source branch.
4. Authenticates against OpenBao using GitHub OIDC.
5. Reads the environment-specific deployment secrets.
6. Ensures the Harbor project exists.
7. Creates a temporary Harbor robot account.
8. Builds the Docker image and pushes its release and environment tags.
9. Prepares SSH credentials.
10. Deploys the image to the remote host using Docker Compose.
11. Cleans up temporary credentials and resources.

```text
Git tag
   |
   v
Resolve release metadata
   |
   +--> Validate tag format
   +--> Validate source branch
   +--> Select GitHub Environment
   +--> Select OpenBao secret path
   |
   v
OpenBao authentication (GitHub OIDC)
   |
   v
Read environment secrets
   |
   v
Harbor project and temporary robot
   |
   v
Docker build and push
   |
   v
SSH preparation
   |
   v
Remote Docker Compose deployment
   |
   v
Cleanup
```

## 2. Release tag conventions

The tag determines the deployment environment, expected source branch and OpenBao KV secret directory.

Only the following formats are accepted:

| Release tag | Target branch | GitHub Environment | OpenBao KV directory | Release channel |
|---|---|---|---|---|
| `v1.2.3-dev.1` | `dev` | `dev` | `Dev` | `dev` |
| `v1.2.3-rc.1` | `main` | `staging` | `Staging` | `staging` |
| `v1.2.3` | `main` | `prod` | `Prod` | `prod` |

### Development releases

Format:

```text
vMAJOR.MINOR.PATCH-dev.NUMBER
```

Example:

```text
v1.2.3-dev.1
v1.2.3-dev.2
v1.2.3-dev.3
```

Behavior:

- The tag must point to a commit contained in the `dev` branch.
- GitHub Environment: `dev`.
- OpenBao secret directory: `Dev`.
- Docker environment alias: `dev`.
- Deploys to the development target configured in OpenBao.

Recommended usage:

```bash
git checkout dev
git pull origin dev

git tag v1.2.3-dev.1
git push origin v1.2.3-dev.1
```

Each new development build should use an incremented development number.

### Staging / release candidate

Format:

```text
vMAJOR.MINOR.PATCH-rc.NUMBER
```

Example:

```text
v1.2.3-rc.1
v1.2.3-rc.2
```

Behavior:

- The tag must point to a commit contained in the `main` branch.
- GitHub Environment: `staging`.
- OpenBao secret directory: `Staging`.
- Docker environment alias: `staging`.
- Deploys to the staging target configured in OpenBao.

Recommended usage:

```bash
git checkout main
git pull origin main

git tag v1.2.3-rc.1
git push origin v1.2.3-rc.1
```

A new release candidate should be created when a new candidate needs to be tested.

### Production releases

Format:

```text
vMAJOR.MINOR.PATCH
```

Example:

```text
v1.2.3
v1.2.4
v2.0.0
```

Behavior:

- The tag must point to a commit contained in the `main` branch.
- GitHub Environment: `prod`.
- OpenBao secret directory: `Prod`.
- Docker environment alias: `prod`.
- An additional Docker `latest` alias is published.
- Deploys to the production target configured in OpenBao.

Recommended usage:

```bash
git checkout main
git pull origin main

git tag v1.2.3
git push origin v1.2.3
```

Production tags should only be created after the corresponding release candidate has been validated.

## 3. Git tag validation

The workflow does not deploy an arbitrary commit just because it has a valid tag.

It validates that the tagged commit is an ancestor of the expected remote branch:

| Tag type | Required branch |
|---|---|
| `-dev.N` | `dev` |
| `-rc.N` | `main` |
| Stable release | `main` |

For example, creating `v1.2.3-dev.1` from a commit that is not contained in `dev` will fail validation.

The following formats are rejected:

```text
1.2.3
v1.2
v1.2.3-beta.1
v1.2.3-dev
v1.2.3-rc
```

The accepted formats are strictly:

```text
vX.Y.Z-dev.N
vX.Y.Z-rc.N
vX.Y.Z
```

## 4. GitHub Environments

The deployment job dynamically selects its GitHub Environment using the release metadata.

The following environments must exist in the application repository:

| GitHub Environment | Purpose |
|---|---|
| `dev` | Development deployments |
| `staging` | Release candidate deployments |
| `prod` | Production deployments |

Configure them under:

```text
Repository
  → Settings
    → Environments
```

### Environment protection

Recommended configuration:

**dev**
- No manual approval required.
- Development-specific deployment configuration.

**staging**
- Optional required reviewers.
- Staging-specific deployment configuration.
- Used for release candidate validation.

**prod**
- Required reviewers / deployment approval.
- Restrict deployment branches and tags where appropriate.
- Production-specific deployment configuration.

GitHub Environment protection rules are evaluated when the deployment job starts. This means production approval can prevent the deployment steps from executing until approval is granted.

The GitHub Environment controls the deployment context; it does not automatically select the OpenBao policy or secret path. Those are handled separately by the workflow.

## 5. OpenBao configuration

OpenBao is used as the central secret store.

The workflow authenticates through GitHub Actions OIDC and reads the secrets corresponding to the selected release environment.

Base KV v2 path:

```text
kv/data/Facu-HomeLab
```

Environment paths:

```text
kv/data/Facu-HomeLab/Dev
kv/data/Facu-HomeLab/Staging
kv/data/Facu-HomeLab/Prod
```

The workflow selects the suffix automatically:

| GitHub Environment | OpenBao path |
|---|---|
| `dev` | `kv/data/Facu-HomeLab/Dev` |
| `staging` | `kv/data/Facu-HomeLab/Staging` |
| `prod` | `kv/data/Facu-HomeLab/Prod` |

### Required secret keys

Each environment must contain the deployment values required by the workflow:

| Key | Purpose |
|---|---|
| `HARBOR_ADMIN_USERNAME` | Harbor administrator username used for project management |
| `HARBOR_ADMIN_PASSWORD` | Harbor administrator password |
| `DEPLOY_SSH_KEY` | Private SSH key used by the deployment workflow |
| `DEPLOY_KNOWN_HOSTS` | Pinned SSH host key entries |
| `DEPLOY_HOST` | Remote deployment hostname or IP |
| `DEPLOY_USER` | SSH deployment user |
| `DEPLOY_PATH` | Remote deployment root directory |

The workflow reads these values from the selected KV path. Do not put environment-specific credentials directly in the workflow YAML.

### OpenBao JWT roles

The workflow currently resolves the JWT role from the target branch:

| Branch | Current JWT role |
|---|---|
| `dev` | `gh-ci-dev` |
| `test` | `gh-ci-test` |
| `main` | `gh-ci-prod` |
| `prod` | `gh-ci-prod` |

**Important: staging role separation**

The current resolver uses the branch rather than the GitHub Environment to select the JWT role.

Consequently:

- A development tag selects `gh-ci-dev`.
- A staging tag selects `gh-ci-prod`, because its target branch is `main`.
- A production tag also selects `gh-ci-prod`.

This means the current implementation does not provide a separate OpenBao JWT role for staging and production.

Before using staging and production as isolated security boundaries, change the resolver to select roles by environment:

| GitHub Environment | Recommended JWT role |
|---|---|
| `dev` | `gh-ci-dev` |
| `staging` | `gh-ci-staging` |
| `prod` | `gh-ci-prod` |

The corresponding OpenBao roles should have environment-specific bound claims and policies. In particular, `gh-ci-staging` should be restricted to the staging environment and staging KV read policy.

Do not assume that a branch-based role mapping provides environment isolation.

## 6. Harbor image publishing

The Harbor project and image name are generated automatically from the repository.

For example, for:

```text
Repository: Facu-HomeLab/my-project
Registry:   reg.internal.facuynati.website
```

The generated values are:

```text
Harbor project:
facu-homelab-my-project

Image:
reg.internal.facuynati.website/facu-homelab-my-project/my-project
```

### Published image tags

The workflow builds the image once and publishes the release tag plus the environment alias.

| Release | Published image tags |
|---|---|
| `v1.2.3-dev.1` | `v1.2.3-dev.1`, `dev` |
| `v1.2.3-rc.1` | `v1.2.3-rc.1`, `staging` |
| `v1.2.3` | `v1.2.3`, `prod`, `latest` |

The version tag is immutable by convention and should be used for deployment.

The environment aliases are convenient pointers to the latest image published for that environment. The `latest` alias is only published for production releases.

A temporary project-scoped Harbor robot is created for the build and deployment. It is removed during cleanup.

## 7. Application Docker Compose requirements

The application repository must contain a Dockerfile and a Compose file.

Default files:

```text
Dockerfile
docker-compose.yml
```

The Compose service must use the `IMAGE` variable supplied by the deployment script.

Example:

```yaml
services:
  app:
    image: ${IMAGE:?IMAGE is required}
    container_name: application
    restart: unless-stopped
```

The deployment script supplies:

```text
IMAGE=reg.internal.facuynati.website/facu-homelab-my-project/my-project:v1.2.3
```

It then executes:

```bash
docker compose config -q
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
```

The workflow deploys the exact version tag, not the moving `dev`, `staging`, `prod` or `latest` aliases.

### Health verification

Health verification is enabled by default:

```yaml
VERIFY_HEALTH: 'true'
HEALTH_TIMEOUT: '120'
```

The current check waits for at least one Compose container to be running. This does not prove that every service is healthy.

For actual application health verification, define a Docker `HEALTHCHECK` or a Compose `healthcheck:` for the relevant service.

## 8. Manual deployment

The workflow can also be started manually from GitHub Actions.

1. Open the repository's Actions tab.
2. Select **Build, publish and deploy**.
3. Select **Run workflow**.
4. Select the branch containing the workflow.
5. Enter the existing release tag in `release_tag`.
6. Start the workflow.

Example input:

```text
release_tag: v1.2.3-dev.1
```

The supplied tag must already exist and must satisfy the same tag format and source-branch validation rules as an automatically triggered release.

Manual execution does not bypass tag validation or environment selection.

## 9. Recommended release lifecycle

A typical release follows this sequence:

```text
dev branch
   |
   | v1.2.3-dev.1
   v
Development deployment
   |
   | Testing and fixes
   |
   | v1.2.3-dev.2
   v
Development deployment
   |
   | Merge approved changes into main
   |
   | v1.2.3-rc.1
   v
Staging deployment
   |
   | Validation / acceptance
   |
   | v1.2.3
   v
Production deployment
```

If a release candidate requires changes, create a new candidate tag after the changes have been merged into `main`.

For example:

```text
v1.2.3-rc.1
v1.2.3-rc.2
v1.2.3
```

Never move an existing release tag to a different commit. Create a new version or candidate tag instead.

## 10. Runner requirements

The self-hosted ephemeral Linux runner must provide:

- Bash
- curl
- jq
- git
- Docker Engine and Docker CLI
- Docker Compose v2 plugin
- OpenSSH client (`ssh`, `scp`, `ssh-keygen`)
- Network connectivity to GitHub, OpenBao, Harbor and the deployment host

Dependencies should be installed in the runner image or VM rather than during each workflow execution.

The runner labels currently expected by the workflow are:

```yaml
runs-on: [self-hosted, linux, x64, ephemeral, docker]
```

## 11. Troubleshooting

| Symptom | Possible cause |
|---|---|
| Unsupported tag | Tag does not match one of the accepted release formats |
| Tag commit is not contained in branch | Tag points to a commit outside the required source branch |
| OpenBao claim validation failed | JWT role claims do not match the repository, ref or GitHub Environment |
| OpenBao permission denied | The selected token policy cannot read the requested KV path |
| Harbor project error | Project does not exist, is public, or has incompatible metadata |
| Docker build or push failed | Runner Docker configuration, registry connectivity or robot permissions |
| SSH authentication failed | Invalid private key, host key or deployment user |
| Compose interpolation error | Required Compose variable such as `IMAGE` was not supplied to a command |
| Container did not start | Remote Docker or application configuration issue |

When diagnosing deployment failures, inspect the first failing workflow step. Later cleanup steps may also report errors, but those should be distinguished from the original failure.

## 12. Security recommendations

- Use GitHub OIDC rather than storing long-lived OpenBao tokens in GitHub secrets.
- Restrict OpenBao JWT roles using repository owner, environment and permitted refs.
- Use different OpenBao policies and secret paths for development, staging and production.
- Require approval for production deployments.
- Protect production release tags against unauthorized creation or mutation.
- Use pinned SSH known-host entries.
- Use temporary Harbor robot accounts with the minimum required permissions.
- Deploy immutable version tags rather than moving aliases.
- Keep deployment credentials out of logs and repository files.
- Ensure cleanup runs even when deployment fails.