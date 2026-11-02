# generate_template.sh

Creates a new, ready-to-deploy project repository from `template/` in this repo:
a private GitHub repository under `Facu-HomeLab`, with all project-specific
values already filled in.

## Requirements

- **bash 4+** (the script uses associative arrays; macOS `/bin/bash` 3.2 is too old)
- **gh** (GitHub CLI), logged in and a member of `Facu-HomeLab`
  with permission to create private repositories
- **git**
- `docker` + Docker Compose v2 — optional; the script validates the generated
  Compose files with `docker compose config` when it is available

## Usage

Interactive (press Enter to accept each default):

```bash
./scripts/generate_template.sh
```

Non-interactive (all six options are required):

```bash
./scripts/generate_template.sh \
  --name my-project \
  --description "My project" \
  --dev-hostname my-project.dev.facuynati.online \
  --prod-hostname my-project.facuynati.online \
  --dev-target proxmox-dev \
  --prod-target proxmox-prod
```

`./scripts/generate_template.sh --help` shows the same information.

## What it does

1. Checks gh authentication and access to the organization.
2. Fails early if `./<NAME>` already exists locally or the GitHub repository
   `Facu-HomeLab/<NAME>` already exists.
3. Prompts for confirmation, then creates a **private** repository.
4. Copies `template/` into the new repository.

## What it fills in

Project-specific values are baked into the generated files (they no longer
depend on `.env` at deploy time):

| File | Filled values |
|---|---|
| `.env` | image, container, port and hostname variables |
| `config/project.yaml` | name, description, repository, registry, image, port, dev/prod hostnames and targets |
| `docker-compose.yml` | image, container_name, port mapping, Caddy hostname, upstream port |
| `docker-compose.dev.yml` | `APP_ENV: development`, port mapping |
| `docker-compose.prod.yml` | `APP_ENV: production` |

Registry and default ports come from constants at the top of the script
(`REGISTRY`, `HARBOR_PROJECT`, `BIND_ADDRESS`, `HOST_PORT`, `CONTAINER_PORT`).

If the template files have changed in ways the script cannot match, it aborts
with an error (`expected exactly one line containing ...`) instead of writing a
partially filled project.

## What it commits

One initial commit (`chore: initialize project from template`) on `main`,
pushed to the new repository. `.env` is kept locally (mode 600) but never
committed — the script verifies that first.

## Notes

- Interactive defaults derive hostnames from the project name
  (`<name>.dev.facuynati.online` / `<name>.facuynati.online`) and targets
  `proxmox-dev` / `proxmox-prod`.
- The `Dockerfile` and GitHub Actions workflows are copied as-is, not modified.
- `SOURCE_REPO` and `SOURCE_BRANCH` can be overridden via environment variables
  for local testing; registry and default ports are constants at the top of the
  script and are changed by editing it.
