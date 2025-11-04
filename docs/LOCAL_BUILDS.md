# Local Build Options

This guide covers different ways to build images locally and alternatives to GitHub Actions.

## Option 1: act - Run GitHub Actions Locally

**Best for**: Testing workflows, saving GitHub Actions minutes, development

### Install act

```bash
# Linux/WSL
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# macOS
brew install act

# Windows (PowerShell)
choco install act-cli
# or
scoop install act
```

### Basic Usage

```bash
# Run the workflow locally
cd /POOL01/software/projects/osbuild
act

# Run specific workflow
act -W .github/workflows/build-image.yml

# Run specific job
act -j build-image

# Run on push event
act push

# Run manually triggered workflow
act workflow_dispatch

# Dry run (see what would run)
act -n
```

### Configure act

Create `.actrc` in project root:

```bash
# Use larger Docker image with more tools
-P ubuntu-latest=catthehacker/ubuntu:full-latest

# Set secrets (don't commit this file!)
-s RCLONE_CONFIG="$(cat ~/.config/rclone/rclone.conf)"

# Use specific Docker platform
--container-architecture linux/amd64
```

### Limitations

**What works:**
- ✅ Most GitHub Actions steps
- ✅ Docker containers
- ✅ Environment variables
- ✅ Secrets (via -s flag)
- ✅ Matrix builds

**What doesn't work:**
- ❌ Some GitHub-specific features (releases, artifacts upload)
- ❌ ARM64 emulation (QEMU) can be slow
- ❌ Requires Docker with good disk space (~20GB for build)

### Example: Run Build Locally

```bash
# Install act
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Run the build workflow
act push -W .github/workflows/build-image.yml

# Or run with secrets
act push \
  -s GITHUB_TOKEN="$(gh auth token)" \
  -s RCLONE_CONFIG="$(cat ~/.config/rclone/rclone.conf)"
```

**Expected time**: 15-30 minutes (depends on your hardware)

## Option 2: Self-Hosted GitHub Actions Runner ⭐⭐ (Best for Production)

**Best for**: Using your own hardware permanently, large builds, saving costs

### Why Self-Hosted Runners?

- ✅ **Free** - No Actions minutes consumed
- ✅ **Faster** - Your hardware, local cache
- ✅ **More resources** - RAM, CPU, disk as much as you have
- ✅ **Works with free tier** - Unlimited minutes on self-hosted runners
- ✅ **Full compatibility** - 100% GitHub Actions features work

### Setup Self-Hosted Runner

#### 1. On Linux Server/Workstation

```bash
# Create runner directory
mkdir -p ~/actions-runner && cd ~/actions-runner

# Download latest runner
curl -o actions-runner-linux-x64-2.311.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-x64-2.311.0.tar.gz

# Extract
tar xzf ./actions-runner-linux-x64-2.311.0.tar.gz

# Get registration token from GitHub
# Go to: https://github.com/altyrus/osbuild/settings/actions/runners/new

# Configure runner (use token from GitHub)
./config.sh --url https://github.com/altyrus/osbuild --token YOUR_TOKEN

# Install as service (optional, for auto-start)
sudo ./svc.sh install
sudo ./svc.sh start

# Or run interactively
./run.sh
```

#### 2. On Windows

```powershell
# Create runner directory
mkdir actions-runner; cd actions-runner

# Download runner
Invoke-WebRequest -Uri https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-win-x64-2.311.0.zip -OutFile actions-runner-win-x64-2.311.0.zip

# Extract
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory("$PWD/actions-runner-win-x64-2.311.0.zip", "$PWD")

# Get token from GitHub: https://github.com/altyrus/osbuild/settings/actions/runners/new

# Configure
./config.cmd --url https://github.com/altyrus/osbuild --token YOUR_TOKEN

# Run as service
./svc.cmd install
./svc.cmd start

# Or run interactively
./run.cmd
```

#### 3. Using Docker (Easiest)

```bash
# Pull official runner image
docker pull myoung34/github-runner:latest

# Run runner container
docker run -d \
  --name github-runner \
  --restart always \
  -e REPO_URL="https://github.com/altyrus/osbuild" \
  -e RUNNER_NAME="docker-runner" \
  -e RUNNER_TOKEN="YOUR_TOKEN" \
  -e RUNNER_WORKDIR="/tmp/runner" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/runner:/tmp/runner \
  myoung34/github-runner:latest

# View logs
docker logs -f github-runner
```

### Update Workflow to Use Self-Hosted Runner

```yaml
# .github/workflows/build-image.yml
jobs:
  build-image:
    runs-on: self-hosted  # Changed from ubuntu-latest
    # Rest stays the same...
```

### Benefits

**Free tier users:**
- ✅ Unlimited minutes on self-hosted runners
- ✅ Artifacts still work (2GB limit)
- ✅ Releases still work (unlimited for public repos)

**Your hardware:**
- Use your powerful workstation
- Keep build cache locally
- Faster builds with local storage
- No waiting for GitHub runners

## Option 3: Pure Docker Build

**Best for**: Simple, reproducible builds without GitHub Actions

### Create Standalone Docker Build

```bash
# Create Dockerfile for building
cat > Dockerfile.builder <<'EOF'
FROM ubuntu:22.04

# Install build dependencies
RUN apt-get update && apt-get install -y \
    qemu-user-static \
    qemu-utils \
    kpartx \
    parted \
    wget \
    curl \
    jq \
    xz-utils \
    git

# Copy build scripts
COPY image-build /workspace/image-build
COPY scripts /workspace/scripts

WORKDIR /workspace

# Build script
CMD ["/bin/bash"]
EOF

# Build the builder image
docker build -f Dockerfile.builder -t osbuild-builder .

# Run build in container
docker run --privileged -v $(pwd)/output:/workspace/output osbuild-builder \
  /workspace/scripts/build-local.sh
```

### Or Use docker-compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  builder:
    build:
      context: .
      dockerfile: Dockerfile.builder
    privileged: true
    volumes:
      - ./output:/workspace/output
      - ./image-build/cache:/workspace/image-build/cache
    environment:
      - K8S_VERSION=1.28.0
    command: /workspace/scripts/build-local.sh
```

Run with:
```bash
docker-compose up
```

## Option 4: Native Local Build (Current)

**Best for**: Simple, no Docker overhead, full control

Already implemented: `./scripts/build-local.sh`

```bash
# Just run it
./scripts/build-local.sh

# With custom K8s version
./scripts/build-local.sh 1.29.0
```

## Comparison Matrix

| Method | Cost | Speed | Compatibility | Setup Time | Best For |
|--------|------|-------|---------------|------------|----------|
| **GitHub Actions** | Minutes limited | Medium | 100% | 0 min | Testing, CI/CD |
| **act (local)** | Free | Fast* | 95% | 5 min | Testing workflows |
| **Self-hosted Runner** | Free | Fast | 100% | 15 min | Production builds |
| **Docker Build** | Free | Fast | N/A | 30 min | Reproducible builds |
| **Native Local** | Free | Fastest | N/A | 0 min | Quick iteration |

*Depends on hardware

## Recommended Strategy

### For Your Situation (Free Tier):

**Best approach**: **Self-hosted runner on your workstation**

Why:
1. ✅ Free unlimited builds
2. ✅ Uses your powerful hardware
3. ✅ 100% GitHub Actions compatibility
4. ✅ Artifacts and releases still work
5. ✅ Can upgrade to paid tier later without changes

**Setup time**: 15 minutes
**Ongoing effort**: Zero (runs as service)

### Quick Start: Self-Hosted Runner

```bash
# 1. Create runner directory
mkdir ~/actions-runner && cd ~/actions-runner

# 2. Get setup token from:
# https://github.com/altyrus/osbuild/settings/actions/runners/new

# 3. Download and configure (use token from web UI)
curl -o runner.tar.gz -L https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-x64-2.311.0.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/altyrus/osbuild --token YOUR_TOKEN

# 4. Install as service
sudo ./svc.sh install
sudo ./svc.sh start

# 5. Update workflow (one line change)
# In .github/workflows/build-image.yml:
# Change: runs-on: ubuntu-latest
# To:     runs-on: self-hosted

# 6. Done! Push to trigger build on your hardware
```

## Hybrid Approach (Recommended)

Use both:

1. **Self-hosted runner** for heavy builds (image creation)
2. **GitHub-hosted** for light tasks (linting, tests)

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest  # Fast, GitHub-hosted
    steps:
      - name: Lint shell scripts
        run: shellcheck scripts/*.sh

  build-image:
    runs-on: self-hosted  # Heavy, your hardware
    needs: lint
    steps:
      - name: Build image
        run: # ... your build steps
```

## Troubleshooting

### act Issues

```bash
# Not enough disk space
docker system prune -a

# ARM64 build too slow
# Use native build instead: ./scripts/build-local.sh

# Missing tools in container
# Use larger image: -P ubuntu-latest=catthehacker/ubuntu:full-latest
```

### Self-hosted Runner Issues

```bash
# Runner offline
sudo systemctl status actions.runner.*
sudo systemctl restart actions.runner.*

# Update runner
cd ~/actions-runner
sudo ./svc.sh stop
./config.sh remove
# Download new version and reconfigure
sudo ./svc.sh install
sudo ./svc.sh start

# View logs
journalctl -u actions.runner.* -f
```

## Cost Analysis

### GitHub Free Tier
- Actions minutes: 2,000/month
- Your image build: ~10 minutes per build
- **Max builds**: ~200/month

### Self-Hosted Runner (Your Hardware)
- Actions minutes: **Unlimited**
- Your image build: ~10 minutes
- **Max builds**: Unlimited (hardware dependent)
- **Cost**: $0/month (just electricity)

### Break-Even Point
If you build more than **200 images/month**, self-hosted is better.
Even for occasional builds, self-hosted gives you:
- Faster builds (local caching)
- No waiting for runners
- More resources available

## Next Steps

Choose your approach:

1. **Quick test**: Run `./scripts/build-local.sh` right now
2. **Try act**: Install and run `act push` to test workflow locally
3. **Set up self-hosted runner**: Follow guide above (15 minutes)
4. **Upgrade GitHub plan**: If you need hosted runners with more resources

All methods produce identical images - choose what fits your workflow!
