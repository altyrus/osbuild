FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install all build dependencies
RUN apt-get update && apt-get install -y \
    qemu-user-static \
    qemu-utils \
    debootstrap \
    kpartx \
    parted \
    wget \
    curl \
    jq \
    xz-utils \
    fdisk \
    dosfstools \
    e2fsprogs \
    git \
    sudo \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /workspace

# Copy project files
COPY image-build /workspace/image-build
COPY scripts /workspace/scripts

# Make scripts executable
RUN chmod +x /workspace/scripts/*.sh && \
    chmod +x /workspace/image-build/scripts/*.sh

# Create output directory
RUN mkdir -p /workspace/output

# Set environment variables with defaults
ENV K8S_VERSION=1.28.0
ENV IMAGE_VERSION=docker-build
ENV RASPIOS_VERSION=2024-07-04-raspios-bookworm-arm64-lite

# Entry point runs the build
CMD ["/workspace/scripts/docker-entrypoint.sh"]
