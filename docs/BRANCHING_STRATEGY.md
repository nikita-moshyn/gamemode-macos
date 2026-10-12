# GameMode — Branching & Release Strategy

## Branches and channels

GameMode uses two long-lived source branches:

| Branch | Purpose | Published releases |
|--------|---------|--------------------|
| `develop` | Latest integrated development, including work being tested | Beta and optional RC tags |
| `main` | Latest code promoted for stable users | Stable tags |
| Feature branches | One feature or fix, starting from `develop` | None; merge into `develop` first |

```text
feature/* ── PR + checks ──► develop ── PR + checks ──► main
                              │                        │
                        beta / RC tags             stable tags
                              │                        │
                       opted-in testers             all users
```

During early development, work can remain on `develop` across many beta releases. Promote to `main` when a version is ready for stable users. Later, use the same workflow for each release cycle. A separate `release/*` branch is not needed for this solo project.

Merging code runs checks. **Pushing a release tag publishes a build.** Each tag permanently identifies the source snapshot used for that release; moving a branch does not change an existing tagged build.

## Day-to-day development

1. Start a feature branch from the latest `develop`.
2. Implement the change and open a PR into `develop`.
3. Merge when build and tests pass.
4. Keep integrating features and fixes into `develop` until ready for a beta.

For small changes during solo development, committing directly to `develop` is also possible if repository rules permit it. Branch pushes run the same checks. PRs remain useful for reviewing your own changes.

## Beta releases

Tag a tested commit already merged into `develop`:

```bash
git switch develop
git pull --ff-only origin develop
git tag -a v0.2.0-beta.1 -m "GameMode 0.2.0 beta 1"
git push origin v0.2.0-beta.1
```

The pipeline validates the source, builds, signs, notarizes, and publishes a GitHub prerelease. It adds a `beta` item to the shared Sparkle feed on `main`. Only users who enable **Receive beta updates** can receive this update.

For subsequent betas, merge fixes/features into `develop` and create `v0.2.0-beta.2`, `v0.2.0-beta.3`, and so on. Publishing the feed changes only `appcast.xml` on `main`; it does not promote development code.

Optional release candidates use the same branch and audience: `v0.2.0-rc.1`, `v0.2.0-rc.2`, etc. When testing an RC, pause new feature merges until the stable promotion is complete, so stable users receive the tested code.

## Stable releases

1. Finish testing a beta or RC on `develop`.
2. Open and merge a **`develop` → `main` PR** after checks pass. Use a merge commit to retain branch history.
3. Tag the resulting stable source on `main`:

```bash
git switch main
git pull --ff-only origin main
git tag -a v0.2.0 -m "GameMode 0.2.0"
git push origin v0.2.0
```

The pipeline builds the tagged commit, creates a stable GitHub release, marks it as Latest, and publishes a default-channel Sparkle item for all users. It never merges source code into `main`; promotion must happen before tagging.

Afterward, merge `main` back into `develop` through a PR. This brings back the promotion history, current feed, and any stable fixes before the next development cycle. Continue with tags such as `v0.3.0-beta.1` on `develop`.

## Hotfixes

For an urgent stable-only fix:

1. Create a hotfix branch from `main`.
2. Merge its PR into `main` after checks pass.
3. Tag the new patch version on `main`, for example `v0.2.1`.
4. Merge `main` back into `develop` through a PR so the next beta includes the fix.

## CI pipelines

### Checks (`.github/workflows/pr.yml`)

- PRs into `main` or `develop`: validate release tooling, build Debug, and run Swift tests.
- Source pushes to `main` or `develop`: run the same checks.
- Feed-only pushes are skipped to avoid rebuilding after every publication.
- The required check is named **`build`**. Superseded checks on the same branch/event are cancelled.

### Release (`.github/workflows/release.yml`)

| Tag | Required source | GitHub release | Sparkle channel |
|-----|-----------------|----------------|-----------------|
| `v0.2.0-beta.1` | Commit already on `develop` | Prerelease | `beta` |
| `v0.2.0-rc.1` | Commit already on `develop` | Prerelease | `rc` |
| `v0.2.0` | Commit already on `main` | Latest stable | Default; no channel label |

The `v` prefix is recommended; unprefixed tags are also accepted. Tags must contain three numeric components and, for prereleases, a positive beta/RC number. Invalid tags fail validation rather than falling back to stable.

Git tags identify commits, not branches. The pipeline verifies that the tagged commit is reachable from the required remote source branch. This also supports annotated tags and a source branch that has advanced since tagging. A stable tag on unpromoted development code is rejected before building or publishing.

Every release goes through source validation → tooling checks → Swift tests → Release build → Developer ID signing → Apple notarization → Sparkle EdDSA signing and verification → GitHub release → feed publication. The archive is available before its feed entry is published. Packaging selects the Release app explicitly, keeping the Debug test host out of the published archive.

## Sparkle updates

The shared feed stays at:

`https://raw.githubusercontent.com/nikita-moshyn/gamemode-macos/main/appcast.xml`

**Settings → General → Updates → Receive beta updates** defaults to off for new and existing installs. Off allows stable updates; on adds both beta and RC updates while retaining stable updates. The choice persists across launches. Manual checks use the same selection, and changing it resets Sparkle's update cycle while respecting the user's automatic-check preference. Installing a beta manually does not opt the user in automatically.

Turning the toggle off keeps the installed version until a newer stable build is available. It does not downgrade the app. A beta cannot replace a newer stable build, even when opted in.

### Version ordering

Sparkle's standard comparator ignores text after a hyphen. Tags are used for display versions and asset names; comparable build versions are written into `CFBundleVersion` and the feed's `sparkle:version`:

| Tag | Display version | Build version |
|-----|-----------------|---------------|
| `v0.2.0-beta.1` | `0.2.0-beta.1` | `0.2.0b1` |
| `v0.2.0-beta.2` | `0.2.0-beta.2` | `0.2.0b2` |
| `v0.2.0-rc.1` | `0.2.0-rc.1` | `0.2.0rc1` |
| `v0.2.0` | `0.2.0` | `0.2.0` |

This orders beta 1 → beta 2 → RC → stable correctly. Use a base version above the current stable release: after `0.1.1`, use `0.1.2-beta.1` or a higher version. Previously published `0.0.1-beta.*` builds cannot update stable `0.1.1` users.

### Initial rollout

You can test these changes in beta builds on `develop` during the early development stage. Existing stable versions have no beta toggle, so those users need a stable release containing it before they can opt in to future betas.

For example: test `v0.1.2-beta.1` on `develop`, promote and publish `v0.1.2` on `main`, then publish `v0.1.3-beta.1` on `develop`. Existing releases are not added to the feed retroactively.

## Publication validation

- `scripts/release.py` validates source ancestry, tags, bundle versions, channel labels, archive URLs, signature encoding, and archive lengths. It rejects beta/RC entries without their channel label and stable entries pointing to beta ZIPs.
- `scripts/verify_update.swift` verifies the final ZIP's signature against the app's embedded `SUPublicEDKey` and checks its actual length.
- `scripts/publish_appcast.sh` reads the latest feed from `origin/main` in a temporary checkout and changes only `appcast.xml`. All channel entries are preserved; rerunning a tag replaces its entry. Concurrent pushes retry without force-pushing.
- Tests cover wrong-source tags, explicit source promotion, feed preservation, push retries, signatures, preference migration, persistence, opt-out, and actual Sparkle version ordering.

Run local release checks with:

```bash
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/release.py validate-appcast appcast.xml
```

## Protected branches and publisher access

Keep both `main` and `develop` protected with the **`build`** check. For solo development, a mandatory second-person approval is unnecessary; PRs still provide a reviewable record. This is a recommended setting, not a change made to the live repository rules.

The release workflow requires an Actions repository secret named **`RELEASE_PUBLISH_TOKEN`**. Checkout uses it to push feed commits. Its account/app must have repository write permissions and permission to bypass every active ruleset protecting `main`; the default `GITHUB_TOKEN` is insufficient for the current rules.

As checked on 12 October 2026, the active **Branch protection** and **Protect main and develop** rulesets allow the repository administrator role to bypass their rules, but have no GitHub Actions app bypass. An appropriately scoped administrator token can publish without changing these protections. Configure it in [repository Actions secrets](https://github.com/nikita-moshyn/gamemode-macos/settings/secrets/actions). Never commit or paste the token into source code.

The workflow fails before building if the secret is absent. Its ability to push under live rules must be confirmed by an actual release run with the configured token.
