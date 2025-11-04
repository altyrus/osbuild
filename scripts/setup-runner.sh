#!/bin/bash
#
# setup-runner.sh - Quick setup for GitHub Actions self-hosted runner
#
# This script automates the setup of a self-hosted GitHub Actions runner
# on your local machine, allowing unlimited free builds.
#
# Usage: ./setup-runner.sh
#

set -euo pipefail

RUNNER_VERSION="2.311.0"
REPO_URL="https://github.com/altyrus/osbuild"

echo "=========================================="
echo "GitHub Actions Self-Hosted Runner Setup"
echo "=========================================="
echo ""
echo "This will set up a self-hosted runner for unlimited free builds."
echo ""

# Check if running on supported OS
if [[ "$(uname -s)" == "Linux" ]]; then
    PLATFORM="linux"
    ARCH="x64"
    RUNNER_FILE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
elif [[ "$(uname -s)" == "Darwin" ]]; then
    PLATFORM="osx"
    ARCH="x64"
    RUNNER_FILE="actions-runner-osx-x64-${RUNNER_VERSION}.tar.gz"
else
    echo "Unsupported OS. Please set up manually:"
    echo "https://github.com/altyrus/osbuild/settings/actions/runners/new"
    exit 1
fi

# Create runner directory
RUNNER_DIR="${HOME}/actions-runner"
echo "Creating runner directory: ${RUNNER_DIR}"
mkdir -p "${RUNNER_DIR}"
cd "${RUNNER_DIR}"

# Download runner if not already present
if [[ ! -f "${RUNNER_FILE}" ]]; then
    echo ""
    echo "Downloading GitHub Actions runner..."
    curl -o "${RUNNER_FILE}" -L \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_FILE}"

    echo "Extracting runner..."
    tar xzf "${RUNNER_FILE}"
else
    echo "Runner already downloaded"
fi

# Check if already configured
if [[ -f ".runner" ]]; then
    echo ""
    echo "⚠️  Runner already configured in this directory."
    echo "To reconfigure, first remove the existing runner:"
    echo "  cd ${RUNNER_DIR}"
    echo "  ./config.sh remove"
    echo ""
    exit 0
fi

echo ""
echo "=========================================="
echo "⚠️  ACTION REQUIRED"
echo "=========================================="
echo ""
echo "To complete setup, you need a registration token from GitHub."
echo ""
echo "1. Open this URL in your browser:"
echo "   ${REPO_URL}/settings/actions/runners/new"
echo ""
echo "2. Copy the token that appears (starts with 'A....')"
echo ""
echo -n "3. Paste the token here and press Enter: "
read -r TOKEN

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: No token provided"
    exit 1
fi

echo ""
echo "Configuring runner..."
./config.sh \
    --url "${REPO_URL}" \
    --token "${TOKEN}" \
    --name "$(hostname)-runner" \
    --labels "self-hosted,${PLATFORM},${ARCH}" \
    --unattended

echo ""
echo "=========================================="
echo "✅ Runner configured successfully!"
echo "=========================================="
echo ""
echo "You have two options to run the runner:"
echo ""
echo "Option 1: Run as a service (recommended)"
echo "  sudo ./svc.sh install"
echo "  sudo ./svc.sh start"
echo "  # Runner will start automatically on boot"
echo ""
echo "Option 2: Run interactively (for testing)"
echo "  ./run.sh"
echo "  # Press Ctrl+C to stop"
echo ""
echo -n "Would you like to install as a service now? (y/N): "
read -r INSTALL_SERVICE

if [[ "${INSTALL_SERVICE}" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Installing as service..."
    sudo ./svc.sh install

    echo "Starting service..."
    sudo ./svc.sh start

    echo ""
    echo "✅ Runner installed and started as a service"
    echo ""
    echo "Useful commands:"
    echo "  sudo systemctl status actions.runner.*    # Check status"
    echo "  sudo systemctl stop actions.runner.*      # Stop runner"
    echo "  sudo systemctl start actions.runner.*     # Start runner"
    echo "  journalctl -u actions.runner.* -f         # View logs"
else
    echo ""
    echo "ℹ️  To run the runner manually:"
    echo "  cd ${RUNNER_DIR}"
    echo "  ./run.sh"
fi

echo ""
echo "=========================================="
echo "Next Steps"
echo "=========================================="
echo ""
echo "1. Update your workflow to use self-hosted runner:"
echo "   Edit: .github/workflows/build-image.yml"
echo "   Change: runs-on: ubuntu-latest"
echo "   To:     runs-on: self-hosted"
echo ""
echo "2. Push a commit to trigger a build on your hardware"
echo ""
echo "3. Monitor builds at:"
echo "   ${REPO_URL}/actions"
echo ""
echo "Benefits:"
echo "  ✅ Unlimited free builds"
echo "  ✅ Uses your hardware (faster with local cache)"
echo "  ✅ No GitHub Actions minutes consumed"
echo ""
