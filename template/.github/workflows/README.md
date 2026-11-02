# CI/CD deployment workflow

Single-job GitHub Actions pipeline that builds a Docker image, publishes it to Harbor and deploys it to a remote host with Docker Compose. Secrets come from OpenBao through GitHub OIDC; no long-lived credentials are stored on GitHub.

- Workflow: `.github/workflows/deployment.yml`
- Helper scripts: `.github/workflows/scripts/` (sourced from the release tag checkout, so every run executes exactly the code of that release)

## 1. Pipeline

The workflow runs one job (`deployment`) on a self-hosted ephemeral runner:

```text
Git tag (v*)
   |
   v
Checkout release tag  ->  Verify scripts  ->  Resolve release
   (tag, SHA, environment, image, version)
   |
   v
Build Docker image  ->  RUNNER_TEMP/image.tar
   |
   v
Load OpenBao configuration (single OIDC fetch, one secret file reused by all later steps)
   |
   v
Publish to Harbor  ->  Create pull-only robot  ->  Prepare SSH
   |
   v
Deploy (scp compose, remote docker login/pull/up --wait)
   |
   v
Cleanup (delete robot, docker logout, remove temp files -- always)
```

Triggered by:

- Pushing a tag matching `v*`
- `workflow_dispatch` with an existing `release_tag` input (same validation as tag pushes)

## 2. Release conventions

| Release tag | Target branch | GitHub Environment | OpenBao KV suffix | Docker tags published |
|---|---|---|---|---|
| `vX.Y.Z-dev.N` | `dev` | `dev` | `Dev` | `vX.Y.Z-dev.N`, `dev`, repository name |
| `vX.Y.Z-rc.N` | `main` | `staging` | `Staging` | `vX.Y.Z-rc.N`, `staging`, repository name |
| `vX.Y.Z` | `main` | `prod` | `Prod` | `vX.Y.Z`, `prod`, `latest`, repository name |

Strictly accepted formats: `vX.Y.Z`, `vX.Y.Z-dev.N`, `vX.Y.Z-rc.N`. Rejected examples: `1.2.3`, `v1.2`, `v1.2.3-beta.1`, `v1.2.3-dev`, `v1.2.3-rc`. Never move an existing tag to a different commit; create a new one.

How to release:

```bash
# Development
git checkout dev && git pull origin dev
git tag v1.2.3-dev.1 && git push origin v1.2.3-dev.1

# Release candidate (after merging dev changes into main)
git checkout main && git pull origin main
git tag v1.2.3-rc.1 && git push origin v1.2.3-rc.1

# Production (after validating the release candidate)
git tag v1.2.3 && git push origin v1.2.3
```

Manual run: **Actions → Build, publish and deploy → Run workflow** → enter an existing release tag.

## 3. GitHub Environments

The job selects its environment from the tag (`dev` / `staging` / `prod`). Configure protection under Settings → Environments:

- `dev`: no approval required
- `staging`: optional required reviewers
- `prod`: required reviewers; protects deployment steps until approved

Protection rules are evaluated when the job starts; they do not control the OpenBao role or KV path (those come from the tag-derived environment).

## 4. Configuration

### GitHub variables/secrets (bootstrap only)

Set as repository Variables (Settings → Secrets and variables → Actions). Workflow-level fallbacks make them optional:

| Variable | Fallback default | Purpose |
|---|---|---|
| `BAO_ADDR` | `https://key.internal.facuynati.website` | OpenBao HTTPS endpoint (cannot come from OpenBao itself) |
| `BAO_PATH_PREFIX` | `kv/data/Facu-HomeLab` | OpenBao KV v2 prefix |
| `BAO_AUDIENCE` | `openbao` | OIDC audience |
| `HARBOR_REGISTRY` | `reg.internal.facuynati.website` | Registry host, no scheme |
| `HARBOR_URL` | `https://<HARBOR_REGISTRY>` | Harbor API base URL |

### OpenBao secrets

KV v2 paths: `<BAO_PATH_PREFIX>/<Dev|Staging|Prod>`.

Required keys per environment:

| Key | Purpose |
|---|---|
| `HARBOR_ADMIN_USERNAME` | Harbor automation identity (project/robot management) |
| `HARBOR_ADMIN_PASSWORD` | Password for that identity |
| `DEPLOY_HOST` | Deployment host/IP |
| `DEPLOY_USER` | Remote deployment user |
| `DEPLOY_SSH_KEY` | Private key of the deployment account |
| `DEPLOY_KNOWN_HOSTS` | Pinned host-key line(s) for the deployment host |
| `DEPLOY_PATH` | Absolute remote deployment root (e.g. `/home/dev/apps`) |

Optional keys (defaults in parentheses):

| Key | Purpose |
|---|---|
| `COMPOSE_FILE` (`docker-compose.yml`) | Compose file copied to the deployment directory |
| `DEPLOY_FILES` (`empty`) | Newline-separated extra files to copy |
| `VERIFY_HEALTH` (`true`) | Wait for healthy containers |
| `HEALTH_TIMEOUT` (`120`) | Compose `--wait-timeout` seconds |
| `HARBOR_ORGANIZATION` (GitHub owner) | Harbor project, lower-cased (e.g. `Facu-HomeLab` → `facu-homelab`) |

### OpenBao JWT roles

The role is selected by environment, not branch:

| Environment | JWT role |
|---|---|
| `dev` | `gh-ci-dev` |
| `staging` | `gh-ci-staging` |
| `prod` | `gh-ci-prod` |

Create these roles in OpenBao and restrict their bound claims to repository, environment, refs and `BAO_AUDIENCE`; each role reads only its own KV path.

## 5. Harbor naming model

```text
Projects
└── facu-homelab                  # Harbor project (private, created if absent)
    └── my-project                # repository = normalized repo slug
        ├── v1.2.3-dev.1          # immutable release tag
        ├── dev                   # moving alias
        ├── my-project            # convenience name tag
        └── (v1.2.3 -> prod + latest)
```

The project is created private if missing; an existing public project is rejected. The workflow always deploys the immutable version tag, never the moving aliases. You can pull by digest or by name:

```bash
docker pull reg.internal.facuynati.website/facu-homelab/my-project:my-project
```

Image builds carry labels: `org.opencontainers.image.title` (image name), `.revision` (commit SHA) and `.source` (repository URL).

## 6. Application requirements

The repository must contain a `Dockerfile` and a Compose file. The Compose service must use the `IMAGE` variable:

```yaml
services:
  app:
    image: ${IMAGE:?nginx:latest}
    container_name: application
    restart: unless-stopped
```

For real health verification define a Compose `healthcheck:`; `--wait` uses it. The `caddy:` labels in the Compose file integrate the service with the reverse proxy on the deploy host.

## 7. Runner requirements

One runner with labels `[self-hosted, linux, x64, ephemeral, docker]`, installed (in the runner image, not per-row): Bash, curl, jq, git, Docker Engine + Compose v2, OpenSSH client (`ssh`, `scp`, `ssh-keygen`), and network access to GitHub, OpenBao, Harbor and the deployment host.

## 8. Local verification

`.github/workflows/debug_temp/run-checks.sh` replays all workflow steps locally:

```bash
.github/workflows/debug_temp/run-checks.sh        # offline: syntax + release resolution
.github/workflows/debug_temp/run-checks.sh --full # live: build, Harbor push, SSH, real deploy, cleanup
```

It uses `secrets.json` from that directory as the OpenBao secret file (OIDC exists only inside Actions). **Do not commit `debug_temp/`** — it holds real credentials.

## 9. Security notes

- Use OIDC tokens fetched from OpenBao, refreshable per stage, never long-lived tokens in GitHub secrets.
- Protect release tags (GitHub rulesets); the workflow and scripts are evaluated from the triggering ref.
- `id-token: write` is the only privileged permission granted; OpenBao token is revoked right after use.
- Harbor publishing authenticates with a dedicated automation identity, not a super-admin; the remote host uses a temporary pull-only robot, deleted during cleanup even on failure.
- SSH host-key checking is strict; never replace pinned `known_hosts` with `StrictHostKeyChecking=no`.
- Logs show phases, resource names and HTTP codes — never credentials or response bodies.
- Pin third-party actions (e.g. `actions/checkout@v4`) to full commit SHAs in a final supply-chain policy.
- Before making the repository public, scan git history and rotate any credential ever committed.

## 10. Troubleshooting

| Symptom | Possible cause |
|---|---|
| Invalid release tag / missing script | Tag format or missing script in the release checkout |
| OpenBao login/read HTTP error | JWT role claims (repo/env/ref/audience) or KV path/keys missing |
| Harbor project error | Project public, credentials, or API unreachable |
| Docker push failed | Registry connectivity or automation identity permissions |
| SSH authentication failed | Key, user or pinned `known_hosts` mismatch |
| Compose interpolation error | `IMAGE` not supplied (must reference `${IMAGE}` in Compose) |
| Container did not start / unhealthy | Remote Docker or missing Compose `healthcheck:` |

Inspect the first failing step; the cleanup step may report follow-up warnings that are not the root cause.
