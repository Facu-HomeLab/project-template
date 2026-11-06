# Project Name

Project description.

## Overview

Describe the purpose and functionality of this application.

## Technology Stack

Document the technologies used by this project.

## Requirements

- Docker
- Docker Compose v2
- Git

Additional requirements depend on the application stack.

## Configuration

Project configuration is maintained in:

`config/project.yaml`

Environment variables are documented in:

`.env.example`

Never commit credentials or production secrets.

## Creating a New Project from Template

Use the `generate_template.sh` script to create a new project repository
from this template. The script handles repository creation, template
variable substitution, and initial commit.

### Quick Start (One-liner)

Run directly without cloning:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Facu-HomeLab/project-template/refs/heads/main/scripts/generate_template.sh)"
```

### Prerequisites

- GitHub CLI (`gh`) authenticated with access to the `Facu-HomeLab` organization
- Git
- Docker (optional, for validating generated Docker Compose files)

### Interactive Mode

Run without arguments to be prompted for each value with defaults:

```bash
./scripts/generate_template.sh
```

### CLI Mode

Provide all required options directly:

```bash
./scripts/generate_template.sh \
  --name my-project \
  --description "My project description" \
  --dev-hostname my-project.dev.facuynati.website \
  --prod-hostname my-project.facuynati.website \
  --dev-target proxmox-dev \
  --prod-target proxmox-prod
```

### Options

| Option | Description |
|--------|-------------|
| `--name` | Project/repository name (letters, numbers, `.`, `_`, `-`) |
| `--description` | Project description |
| `--dev-hostname` | Development hostname (no scheme/path/port) |
| `--prod-hostname` | Production hostname (no scheme/path/port) |
| `--dev-target` | Development deployment target |
| `--prod-target` | Production deployment target |
| `-h, --help` | Show help |

### What the Script Does

1. Validates prerequisites and GitHub access
2. Creates a private GitHub repository under `Facu-HomeLab`
3. Clones the template source
4. Generates project-specific files:
   - `.env` with registry, image, and network configuration
   - `config/project.yaml` with project metadata and deployment config
   - `docker-compose.yml`, `.dev.yml`, `.prod.yml` with baked values
5. Validates Docker Compose syntax (if Docker is available)
6. Commits and pushes to the new repository

### Output

On success, the script prints:
- Repository URL
- Local project path
- Generated files (`.env`, `config/project.yaml`, Docker Compose files)

## Local Development

1. Clone the repository.
2. Configure the required environment variables.
3. Build the application image using its Dockerfile.
4. Start the application using Docker Compose.

Example:

```bash
cp .env.example .env

docker compose \
  -f deploy/docker-compose.yml \
  -f deploy/docker-compose.dev.yml \
  up -d --build
```

Note: The Dockerfile must be implemented for the selected
technology before building the application.

## Deployment

Deployment is managed through GitHub Actions.

The deployment pipeline:

1. Runs CI checks.
2. Builds the Docker image.
3. Pushes the image to Harbor.
4. Deploys using Docker Compose.

Development and production deployments are configured
through their respective workflows.

## Healthcheck

Configure the application health endpoint according
to the implementation in `config/project.yaml`.

## License

Specify the project license.
