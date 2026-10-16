# GameMode — Branching & Release Strategy

## Branches and channels

| Branch | Purpose | Release channels |
|--------|---------|------------------|
| `develop` | Integrated development and beta testing | Beta, optional RC |
| `main` | Code promoted for stable users; trusted release workflow | Stable |
| Feature branches | Work reviewed and merged into `develop` | None |

PRs and source pushes run checks. Releases start manually from **Actions → Release → Run workflow**. Pushing a tag does not publish a build.

A release's source commit must already be merged into the appropriate branch. The workflow verifies ancestry, so an older tested commit remains releasable after the branch advances. Promote stable code with a `develop` → `main` PR before releasing it, then merge `main` back into `develop`. Hotfixes go through `main` and are merged back into `develop` afterward.

## Run a release

The updated workflow must first be merged into `main`. Always choose **main** in GitHub's workflow branch selector; the source input independently selects the application code.

| Input | Example | Meaning |
|-------|---------|---------|
| Version | `0.2.0` | Three numeric components, no `v` or channel suffix |
| Channel | `beta` | `beta`, `rc`, or `stable` |
| Beta/RC number | `3` | Positive integer; ignored for stable |
| Source commit | Full 40-character lowercase SHA | Exact commit already on `develop` (beta/RC) or `main` (stable) |
| Publish | Unchecked by default | Create the GitHub release/tag and advertise it in Sparkle |

These inputs generate `v0.2.0-beta.3`, `v0.2.0-rc.3`, or `v0.2.0`. Use `git rev-parse origin/develop` or `git rev-parse origin/main` after fetching to obtain a source SHA. Branch names and short SHAs are deliberately rejected: every retry must build the same source.

With **Publish unchecked**, the workflow tests, builds, signs, notarizes, and uploads a downloadable Actions artifact. It creates no Git tag, GitHub release, or feed entry. Signing/notarization secrets are still required. The artifact contains the app ZIP and `release.json`, recording the source commit, version/channel, SHA-256 checksum, length, and Sparkle signature. Artifacts are retained for 90 days, subject to repository retention limits.

With **Publish checked**, the workflow also:

1. Creates the tag at the exact built commit, or verifies an existing tag points there.
2. Creates or resumes a draft GitHub release.
3. Uploads missing assets and verifies their bytes from GitHub.
4. Publishes the release. Beta/RC releases are prereleases and are not marked Latest; stable releases are marked Latest.
5. Downloads and verifies the published archive, then updates only `appcast.xml` on `main`.

The archive is available before its feed entry is advertised. Publication does not merge application code. A new run after a build-only run builds again; the publish checkbox cannot be changed on a rerun. Once a release exists, subsequent runs for that same version/commit reuse its assets instead of rebuilding them.

## Retry behavior

Use **Re-run failed jobs** for transient failures. **Re-run all jobs** is also safe:

- Before a completed artifact exists, a failed build can rebuild the same source/version.
- Once this run's `release-<run_id>` artifact exists, reruns verify and reuse it. The artifact is never overwritten.
- A partial draft release resumes uploads from that saved artifact. Existing complete assets must match exactly. Empty GitHub `starter` assets from failed uploads may be removed only while the release is a draft.
- If publication succeeded but the feed job failed, rerun the feed job. It downloads the published ZIP and manifest and updates the feed without rebuilding or changing release assets.
- A repeated feed update with identical metadata is a no-op, preserving the original publication date.
- A new run for an existing version reuses complete release assets. An incomplete draft without an accessible build artifact fails with instructions to rerun the original workflow.
- A tag pointing to another commit, conflicting asset bytes, or conflicting feed entry fails. No tag is moved and no published asset is replaced. An existing unprefixed legacy tag also reserves that version.

A source or workflow fix requires a **new run**; rerunning an old workflow keeps the old workflow/source commits. If no tag/release exists, the unpublished version can be reused. Once a tag exists, it stays attached to its original source; use a new version for different code.

Release workflows share a concurrency group and do not cancel a running publisher. GitHub may replace an older pending run with a newer pending run; inspect the Actions queue before submitting multiple releases. Feed pushes also retry from the latest `main` without force-pushing, preserving other channel entries and normal merges.

Enabling GitHub immutable releases is recommended. Draft assets can be completed before publication; published releases remain read-only to this tooling regardless of that repository setting.

## Beta-only features

`Config/FeatureFlags.xcconfig` is the shared feature list for both the app and its test target:

| Build channel | Compilation conditions | Displays |
|---------------|------------------------|----------|
| `stable` (default) | No beta feature conditions | Excluded |
| `rc` | Same feature conditions as stable | Excluded |
| `beta` | `GAMEMODE_BETA FEATURE_DISPLAYS` | Included |

All distributed channels use the optimized **Release** configuration. Debug versus Release controls optimization/debugging; `GAMEMODE_CHANNEL` independently controls feature availability. The workflow derives the channel once from its validated inputs and verifies the built bundle records that channel.

Local builds:

```bash
./build.sh --channel beta CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
./build.sh --channel stable CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
./build.sh --channel rc CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
```

For direct `xcodebuild` calls, pass `GAMEMODE_CHANNEL=beta`, `stable`, or `rc`. Xcode defaults to stable. Additional feature conditions belong in the checked-in channel lists; wrap the feature's UI and effect entry points with `#if FEATURE_NAME`.

Displays includes refresh-rate management and its Low Power Mode controls. Stable and RC builds omit the Displays view and refresh-rate activation entry point, reject navigation to it, and do not schedule or apply display/power changes from saved preferences. A remembered Displays destination falls back to General. Persisted display preferences are retained for future beta installs. Restoration and journal handling remain compiled in every channel so a stable build can recover settings changed by a previous beta.

The **Receive beta updates** preference is separate from compilation conditions. Enabling it allows newer beta binaries to be offered; it cannot enable code absent from the installed binary. Installing a beta manually does not opt a user into future beta updates automatically.

## Sparkle versions and channels

Keep the shared feed URL embedded in existing apps:

`https://raw.githubusercontent.com/nikita-moshyn/gamemode-macos/main/appcast.xml`

Sparkle uses this feed to select updates. GitHub's Latest/prerelease labels do not select Sparkle updates. The release script writes both the comparable build version and channel into each feed entry:

| Tag | Display version | Bundle/feed build version | Sparkle channel |
|-----|-----------------|---------------------------|-----------------|
| `v0.2.0-beta.1` | `0.2.0-beta.1` | `0.2.0b1` | `beta` |
| `v0.2.0-beta.2` | `0.2.0-beta.2` | `0.2.0b2` | `beta` |
| `v0.2.0-rc.1` | `0.2.0-rc.1` | `0.2.0rc1` | `rc` |
| `v0.2.0` | `0.2.0` | `0.2.0` | Default, channel omitted |

This retains the existing ordering: beta 1 → beta 2 → RC → stable. Sparkle's comparator ignores the portion following a hyphen, so display versions must not replace these comparable build versions.

**Receive beta updates** defaults to off. Off allows stable updates; on adds beta and RC while retaining stable updates. The choice persists across launches. Manual checks use the same selection. Changing the choice resets Sparkle's update cycle while respecting the user's automatic-check preference.

Turning beta updates off keeps the installed app until a newer stable release exists; it does not downgrade. Use a base version above the current stable release: after `0.1.1`, use `0.1.2-beta.1` or higher. Previously published `0.0.1-beta.*` versions cannot update stable `0.1.1` users. Older stable apps without the beta preference need a stable release containing it before users can opt in.

## CI and local validation

PRs into `main`/`develop` and source pushes run a stable/beta matrix. Each builds Release and runs Swift tests in Debug with that channel's flags. The aggregate required check remains named **build**. Feed-only pushes are skipped.

Release tooling tests cover source ancestry, input validation, manifest integrity, partial publication failures (including failures after the server accepted a request), immutable assets/tags, feed preservation, retries, and signature verification. Swift tests cover channel preferences, feature availability, saved settings, navigation, and recovery.

```bash
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/release.py validate-appcast appcast.xml
```

The signing pipeline uses `./build.sh` and the pinned Swift package lockfile. Release tooling is checked out from the workflow commit separately from the requested application source. Source commits must include the channel build configuration and bundle metadata introduced with this workflow.

## Repository setup

Before the first manual release:

1. Merge this workflow and its scripts into `main`, and bring the build/feature changes into the branch being released.
2. Keep `main` and `develop` protected with the **build** check. Protect changes to the release workflow. The workflow accepts runs and reruns only from the repository owner, with the workflow itself on `main`.
3. Create an environment named **release**, restricted to the `main` workflow branch. Make the owner its only required reviewer and leave self-review allowed for solo releases. Disable administrator bypass if desired. Required-reviewer availability depends on GitHub plan and repository visibility. Environment protection applies to the workflow ref; the prepare job separately validates the requested application source SHA.
4. Store `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `NOTARIZATION_APPLE_ID`, `NOTARIZATION_PASSWORD`, `NOTARIZATION_TEAM_ID`, `SPARKLE_PRIVATE_KEY`, and `RELEASE_PUBLISH_TOKEN` in that environment. Remove repository-level duplicates when migrating secrets so other workflows cannot obtain them through that scope.
5. Give the publishing token permission to create tags/releases and push feed commits to `main` under every active ruleset. It is used only by publish/feed jobs. The default workflow token has read-only repository permissions. Keep the existing Sparkle signing key so installed apps can verify new releases.
6. Run with Publish unchecked first. Download and inspect the signed app. Then publish a new beta and verify a beta-to-stable update cycle with actual installed builds.

Signing/build jobs use the existing `xcode-27` runner label. Preparation/publication/feed jobs use `ubuntu-latest`. GitHub environment settings, secret migration, and live publication are separate from these repository changes; a successful local test does not establish that production credentials or rulesets are configured correctly.
