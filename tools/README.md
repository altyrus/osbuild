# OSBuild Tools

This directory contains compiled binaries needed for the build process.

## e2fsprogs-1.47.1

The build process requires e2fsprogs 1.47+ to handle Raspberry Pi OS Trixie's newer ext4 features, specifically `FEATURE_C12` (orphan_file).

Ubuntu 22.04 LTS ships with e2fsprogs 1.46.5 which does not support this feature, causing errors when attempting to resize the filesystem:
```
/dev/mapper/loopXp2 has unsupported feature(s): FEATURE_C12
e2fsck: Get a newer version of e2fsck!
```

### Installation

If the binaries are not present, they will be automatically detected during build, and you'll receive instructions to compile them.

To compile and install e2fsprogs 1.47.1:

```bash
cd /tmp
wget https://sourceforge.net/projects/e2fsprogs/files/e2fsprogs/v1.47.1/e2fsprogs-1.47.1.tar.gz
tar -xzf e2fsprogs-1.47.1.tar.gz
cd e2fsprogs-1.47.1
./configure
make -j$(nproc)

# Copy binaries to osbuild tools directory (from the osbuild project root)
# Adjust the path if your osbuild directory is elsewhere
mkdir -p ~/osbuild/tools/e2fsprogs-1.47.1/bin
cp e2fsck/e2fsck resize/resize2fs misc/tune2fs ~/osbuild/tools/e2fsprogs-1.47.1/bin/
```

### Binaries Included

- **e2fsck** - Filesystem checker with FEATURE_C12 support
- **resize2fs** - Filesystem resizer with FEATURE_C12 support
- **tune2fs** - Filesystem tuning utility

### Why Not System-Wide Installation?

Installing e2fsprogs 1.47 system-wide on Ubuntu 22.04 requires upgrading libc6 and other core libraries, which can cause dependency conflicts and system instability. Using locally compiled binaries in the project directory is safer and keeps the system packages intact.

### Version Information

- **e2fsprogs Version**: 1.47.1 (20-May-2024)
- **Compiled for**: Ubuntu 22.04 LTS (Jammy Jellyfish)
- **Purpose**: Raspberry Pi OS Trixie (Debian 13) filesystem support
