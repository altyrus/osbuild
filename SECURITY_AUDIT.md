# Security Audit Report - Public Repository

**Date**: 2025-11-04
**Repository**: https://github.com/altyrus/osbuild
**Status**: ⚠️ Personal Information Found

## Summary

This repository is suitable for public release as infrastructure code, but contains some personal/internal information that should be sanitized before wider distribution.

## ✅ Good Security Practices Found

1. **No Hardcoded Secrets**
   - No passwords, API keys, or tokens in code
   - All sensitive values use GitHub Secrets (properly)
   - `.gitignore` correctly excludes: `*.key`, `*secret*`, `*credentials*`, `.env`

2. **Proper Placeholders**
   - Documentation uses `yourdomain.com`, `YOUR_SERVER`, `yourorg`
   - Example IPs use RFC 1918 private ranges (10.0.10.x)
   - Example MAC addresses use sequential patterns (clearly fake)

3. **Secret Management**
   - Workflow uses `${{ secrets.RCLONE_CONFIG }}` (correct)
   - Documentation warns against baking secrets into images
   - Bootstrap script designed to fetch secrets at runtime

## ⚠️ Personal Information Exposed

### Critical Issues

1. **Git Commit History**
   - **Email**: `scot.gray@altyrus.com` in ALL commits
   - **Name**: `Scot Gray`
   - **Impact**: Permanent in git history, visible on GitHub
   - **Risk Level**: LOW (business email, expected for open source)

2. **Local Filesystem Paths**
   - **Found in**: `NOTES.md`, `claude.md`
   - **Examples**:
     - `/POOL01/software/projects/osbuild` (Linux path)
     - `C:/Users/scot/AppData/Roaming/Code/User/settings.json` (Windows path with username)
   - **Impact**: Reveals local directory structure and username
   - **Risk Level**: MEDIUM (could aid targeted attacks)

3. **Personal Information in Documentation**
   - **Files**: `NOTES.md` (lines 6-8), `claude.md` (lines 698-700, 718)
   - **Contains**:
     - Full name
     - Email address
     - Local filesystem paths
     - Company name (altyrus)
   - **Risk Level**: LOW-MEDIUM (appropriate for personal/company project)

### Detailed Findings

#### NOTES.md
```markdown
Line 6: - **Path**: `/POOL01/software/projects/osbuild`
Line 7: - **GitHub**: https://github.com/altyrus/osbuild
Line 8: - **Owner**: altyrus (Scot Gray - scot.gray@altyrus.com)
```

#### claude.md
```markdown
Line 698: - **Project Location**: `/POOL01/software/projects/osbuild`
Line 700: - **Owner**: altyrus (Scot Gray - scot.gray@altyrus.com)
Line 714: Copy `/POOL01/software/projects/osbuild` to Google Drive
Line 718: Location: `C:/Users/scot/AppData/Roaming/Code/User/settings.json`
```

## 📋 Recommendations

### Option 1: Keep As-Is (Acceptable)
**If this is a personal/company open-source project:**
- ✅ Business email is appropriate for attribution
- ✅ Company name (altyrus) is acceptable branding
- ⚠️ Remove local filesystem paths
- ⚠️ Remove Windows username from paths

### Option 2: Sanitize for Generic Use
**If distributing as generic infrastructure template:**
- Remove/genericize all personal references
- Use placeholder email: `opensource@example.com`
- Use generic paths: `/opt/osbuild` instead of `/POOL01/...`
- Remove company-specific references

### Option 3: Use .github/CODEOWNERS (Recommended)
**Best practice for open source:**
- Keep git history as-is (proper attribution)
- Add `.github/CODEOWNERS` file for official ownership
- Sanitize NOTES.md and claude.md to be generic
- Email remains in git history (standard for open source)

## 🔧 Immediate Actions Required

### High Priority
1. **Remove local filesystem paths** from documentation
   - `/POOL01/software/projects/osbuild` → `/opt/osbuild` or remove
   - `C:/Users/scot/AppData/...` → Remove entirely

### Medium Priority
2. **Decide on attribution strategy**
   - Personal project: Keep name/email (current)
   - Generic template: Sanitize to placeholders
   - Company project: Add LICENSE file with proper attribution

### Low Priority
3. **Consider adding**
   - `SECURITY.md` - Security disclosure policy
   - `CODE_OF_CONDUCT.md` - Community guidelines
   - `.github/CODEOWNERS` - Official ownership

## ✅ No Action Needed

These are **safe** and properly configured:

1. **Example Data**
   - MAC: `dc:a6:32:12:34:56` (clearly sequential example)
   - IPs: `10.0.10.10` (RFC 1918 private range)
   - Domains: `yourdomain.com`, `example.com` (placeholders)

2. **Repository References**
   - `https://github.com/altyrus/osbuild` (public repo URL - expected)
   - `https://github.com/altyrus/k8s-bootstrap.git` (placeholder, doesn't exist yet)

3. **Secret Management**
   - All secrets properly use GitHub Secrets
   - No credentials in code or configs
   - .gitignore properly configured

## 🎯 Conclusion

**Repository is SAFE for public release** with minor sanitization:

**Minimum Required:**
- Remove local filesystem paths from NOTES.md and claude.md

**Recommended:**
- Decide if NOTES.md and claude.md should be:
  - Personal working notes (move to `.gitignore`)
  - Public documentation (sanitize personal info)
  - Removed entirely

**Current Risk Assessment:**
- **Secrets Exposure**: ✅ NONE (excellent)
- **Infrastructure Exposure**: ⚠️ LOW (only example data)
- **Personal Info**: ⚠️ MEDIUM (email in git history, filesystem paths in docs)
- **Overall Risk**: ✅ LOW (acceptable for open-source infrastructure project)

## Next Steps

Please review and choose one:

1. **Sanitize Now** - Remove personal info, make generic template
2. **Keep Personal** - This is your/company's branded project (just remove filesystem paths)
3. **Make Private** - Keep repo private if this concerns you

All options are valid depending on your intent for this repository.
