# Storage Setup Guide

This guide explains how to store your built images with different options optimized for GitHub's free tier.

## Overview

Built images are ~1.7GB each. GitHub free tier has:
- **Artifacts**: 500MB storage, 90-day retention
- **Releases**: Unlimited storage (permanent)

## Storage Options

### Option 1: GitHub Releases (Recommended - Free & Permanent)

**Best for**: Production releases, permanent storage

**How it works**:
1. Tag your commit with a version
2. Workflow automatically creates a release
3. Image files attached to release (unlimited storage)

**Usage**:
```bash
# Create a release
git tag -a v0.1.0 -m "First working build with Kubernetes 1.28"
git push origin v0.1.0

# Workflow automatically:
# 1. Builds the image
# 2. Creates GitHub Release
# 3. Uploads disk.img, checksums, metadata
```

**Download**:
- Go to: https://github.com/altyrus/osbuild/releases
- Download the `.img` file
- Or use CLI: `gh release download v0.1.0`

### Option 2: GitHub Artifacts (Dev Builds)

**Best for**: Testing, temporary storage

**Settings**:
- Retention: 7 days (configurable)
- Automatically deleted after expiration
- Good for CI/CD testing

**Download with CLI**:
```bash
# Download latest build
./scripts/download-artifacts.sh

# Download specific build
./scripts/download-artifacts.sh 19054626373

# Specify download location
./scripts/download-artifacts.sh 19054626373 ./my-images
```

**Download manually**:
1. Go to: https://github.com/altyrus/osbuild/actions
2. Click on a workflow run
3. Scroll to "Artifacts" section
4. Click to download

### Option 3: Google Drive (Automatic Backup)

**Best for**: Team sharing, backup, long-term dev storage

**Setup Steps**:

#### 1. Install rclone locally
```bash
# Linux
curl https://rclone.org/install.sh | sudo bash

# macOS
brew install rclone

# Windows
# Download from https://rclone.org/downloads/
```

#### 2. Configure Google Drive
```bash
# Start configuration
rclone config

# Follow prompts:
# - Type: n (new remote)
# - Name: gdrive
# - Storage: drive (Google Drive)
# - Client ID: (leave blank for default)
# - Client Secret: (leave blank)
# - Scope: drive (full access)
# - Service Account: (leave blank)
# - Edit advanced: n
# - Auto config: y (opens browser)
# - Authorize in browser
# - Team Drive: n
# - Confirm: y

# Test it works
rclone lsd gdrive:
```

#### 3. Export rclone config
```bash
# Show your config (contains auth token)
cat ~/.config/rclone/rclone.conf

# This will show something like:
# [gdrive]
# type = drive
# client_id = ...
# client_secret = ...
# token = {"access_token":"...","token_type":"Bearer",...}
# team_drive =
```

#### 4. Add to GitHub Secrets
1. Copy the **entire contents** of `rclone.conf`
2. Go to: https://github.com/altyrus/osbuild/settings/secrets/actions
3. Click "New repository secret"
4. Name: `RCLONE_CONFIG`
5. Value: Paste the rclone.conf contents
6. Click "Add secret"

#### 5. Done!

Next build will automatically upload to Google Drive:
```
Google Drive/osbuild-images/
├── 2025-11-04-a378488/
│   ├── rpi5-k8s-a378488.img
│   ├── rpi5-k8s-a378488.img.sha256
│   ├── metadata.json
│   └── netboot/
│       └── rootfs.tar.gz
└── 2025-11-05-b1234ac/
    └── ...
```

**Download from Google Drive**:
```bash
# List available builds
rclone ls gdrive:osbuild-images/

# Download specific build
rclone copy gdrive:osbuild-images/2025-11-04-a378488/ ./local-images/

# Download just the disk image
rclone copy gdrive:osbuild-images/2025-11-04-a378488/rpi5-k8s-*.img ./
```

### Option 4: Local Network Storage (NAS/NFS)

**Best for**: Lab environment, local development

You can modify the workflow to also upload to your local NFS server or NAS device:

```yaml
# Add to .github/workflows/build-image.yml
- name: Upload to NAS
  if: github.ref == 'refs/heads/main'
  run: |
    # Mount NFS share
    sudo mount -t nfs YOUR_NAS_IP:/share /mnt/nas

    # Copy files
    cp output/rpi5-k8s-*.img /mnt/nas/osbuild/
    cp output/netboot/rootfs.tar.gz /mnt/nas/osbuild/netboot/

    # Unmount
    sudo umount /mnt/nas
```

## Recommended Strategy

### For Most Users:
1. **Releases**: Tag versions for permanent storage (v0.1.0, v0.2.0, etc.)
2. **Artifacts**: Keep dev builds for 7 days only
3. **Google Drive**: Enable for team sharing and backup

### For Solo Developer:
1. **Releases**: Tag working versions
2. **Local Download**: Use `./scripts/download-artifacts.sh` when needed
3. **Skip Google Drive**: Unless you want backup

### For Team/Production:
1. **Releases**: All production versions
2. **Google Drive**: All dev builds for team access
3. **Artifacts**: Short retention (3-7 days)

## Storage Comparison

| Method | Cost | Retention | Speed | Team Access | Automation |
|--------|------|-----------|-------|-------------|------------|
| GitHub Releases | Free | Permanent | Medium | Public/Private | Auto (tags) |
| GitHub Artifacts | Free* | 7-90 days | Fast | Private | Auto (all builds) |
| Google Drive | Free** | Permanent | Slow | Shareable | Auto (optional) |
| Local Download | Free | As long as you keep | Fast | No | Manual |

\* Limited to 500MB total storage
\*\* Limited to 15GB free tier

## Troubleshooting

### Artifacts quota exceeded
- Reduce retention days in workflow (currently 7)
- Delete old artifacts manually
- Use releases instead for permanent storage

### Google Drive upload fails
- Check RCLONE_CONFIG secret is set correctly
- Verify rclone.conf has valid token
- Token may expire - regenerate with `rclone config reconnect gdrive:`

### Can't download artifacts
- Install GitHub CLI: `gh auth login`
- Make repository public, or be authenticated
- Check artifact hasn't expired

## See Also

- [GitHub Actions Artifacts Documentation](https://docs.github.com/en/actions/using-workflows/storing-workflow-data-as-artifacts)
- [rclone Documentation](https://rclone.org/docs/)
- [GitHub CLI](https://cli.github.com/)
