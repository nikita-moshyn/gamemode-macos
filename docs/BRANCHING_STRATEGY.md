# GameMode — Branching & Release Strategy

## Overview

GameMode follows a Git Flow–inspired branching model with three release channels:

| Channel  | Tag format          | Source branch   | Example           | GitHub Release |
|----------|---------------------|-----------------|-------------------|----------------|
| **Beta** | `v1.2.0-beta.1`    | `develop`       | `v0.3.0-beta.1`  | Pre-release    |
| **RC**   | `v1.2.0-rc.1`      | `release/1.2.0` | `v0.3.0-rc.1`    | Pre-release    |
| **Stable** | `v1.2.0`          | `main`          | `v0.3.0`          | Latest         |

```
feature/* ──► develop ──► release/* ──► main
                 │              │          │
            beta tags       RC tags   stable tags
```

---

## Branches

### `main` — Production

- Always contains the latest stable release.
- Only receives merges from `release/*` branches (via the CI pipeline or manual merge).
- Protected: requires PR or CI bot push.
- Tags: `v1.2.0`, `1.2.0`

### `develop` — Integration

- Default working branch. All feature branches merge here.
- Should always build and pass tests.
- Beta tags are pushed directly from `develop`.
- Tags: `v1.2.0-beta.1`, `v1.2.0-beta.2`, …

### `feature/*` — Feature work

- Branch from: `develop`
- Merge into: `develop` (via PR)
- Naming: `feature/dark-mode`, `feature/hotkey-editor`
- Delete after merge.

### `release/*` — Release stabilization

- Branch from: `develop` when a version is feature-complete.
- Naming: `release/1.2.0`
- Only bug fixes, docs, and polish go here — no new features.
- RC tags are pushed from this branch.
- When stable, merge into `main` **and** back into `develop`.
- Delete after merge.

### `hotfix/*` — Emergency fixes

- Branch from: `main`
- Merge into: `main` **and** `develop`
- Naming: `hotfix/crash-on-launch`
- Tag a new patch version from `main` after merge (e.g. `v1.2.1`).

---

## Release Flow

### 1. Beta release (from `develop`)

When you want early testers to try new features:

```bash
# On develop, after merging features
git tag v0.3.0-beta.1
git push origin v0.3.0-beta.1
```

**CI will:**
- Build, sign, and notarize the app
- Create a GitHub pre-release
- **Will NOT** update `appcast.xml` or merge to `main`

Increment the beta number for subsequent betas: `-beta.2`, `-beta.3`, etc.

### 2. Release Candidate (from `release/*`)

When beta is stable enough and you want final validation:

```bash
# Create release branch from develop
git checkout develop
git checkout -b release/0.3.0

# Fix any remaining issues, then tag
git tag v0.3.0-rc.1
git push origin release/0.3.0 v0.3.0-rc.1
```

**CI will:**
- Build, sign, and notarize the app
- Create a GitHub pre-release
- **Will NOT** update `appcast.xml` or merge to `main`

If fixes are needed, commit to the release branch and tag `-rc.2`, `-rc.3`, etc.

### 3. Stable release (from `main`)

When the RC is validated and ready for all users:

```bash
# Merge release branch into main
git checkout main
git merge --no-ff release/0.3.0

# Tag the stable release
git tag v0.3.0
git push origin main v0.3.0

# Merge back into develop
git checkout develop
git merge --no-ff release/0.3.0
git push origin develop

# Clean up
git branch -d release/0.3.0
git push origin --delete release/0.3.0
```

**CI will:**
- Build, sign, and notarize the app
- Create a GitHub release (marked as Latest)
- Update `appcast.xml` with Sparkle update info
- Commit the updated appcast to `main`

### 4. Hotfix

```bash
git checkout main
git checkout -b hotfix/crash-fix

# Fix the issue, then merge
git checkout main
git merge --no-ff hotfix/crash-fix
git tag v0.3.1
git push origin main v0.3.1

# Also merge into develop
git checkout develop
git merge --no-ff hotfix/crash-fix
git push origin develop
```

---

## CI/CD Pipelines

### PR Check (`.github/workflows/pr.yml`)

| Trigger | Targets | Actions |
|---------|---------|---------|
| Pull request to `main` or `develop` | All PRs | Build (Debug) → Run tests |

- Uses ad-hoc signing (no certificate needed)
- Fails the PR if build or tests fail
- Concurrent runs for the same branch are cancelled

### Release (`.github/workflows/release.yml`)

| Trigger | Actions |
|---------|---------|
| Tag `v*` pushed | Build → Sign → Notarize → Sparkle sign → GitHub Release |

The pipeline auto-detects the channel from the tag:

| Tag pattern | Channel | Prerelease | Update appcast | Merge to main |
|-------------|---------|------------|----------------|---------------|
| `v1.2.0-beta.*` | beta | ✅ | ❌ | ❌ |
| `v1.2.0-rc.*` | rc | ✅ | ❌ | ❌ |
| `v1.2.0` | stable | ❌ | ✅ | ✅ |

---

## Sparkle Auto-Updates

Only **stable** releases are published to `appcast.xml`. Users on the stable channel receive updates automatically via Sparkle.

Beta and RC releases are only available as manual downloads from the GitHub Releases page.

---

## Quick Reference

```
Day-to-day work:
  feature/x → PR → develop

Beta testing:
  develop → tag v1.0.0-beta.1 → push tag

Release prep:
  develop → release/1.0.0 → tag v1.0.0-rc.1 → push tag

Ship it:
  release/1.0.0 → merge to main → tag v1.0.0 → push tag
  release/1.0.0 → merge back to develop → delete branch

Emergency:
  main → hotfix/x → merge to main + develop → tag v1.0.1
```

## Branch Protection Settings

| Branch | Rules |
|--------|-------|
| `main` | Require PR (except CI bot), require status checks to pass |
| `develop` | Require PR, require status checks to pass |

Add `github-actions[bot]` to the branch protection bypass list so the release pipeline can push appcast updates to `main`.
