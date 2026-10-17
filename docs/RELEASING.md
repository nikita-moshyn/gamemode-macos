# Releases

Releases run manually through [GitHub Actions](https://github.com/nikita-moshyn/gamemode-macos/actions/workflows/release.yml). Pushing a tag alone doesn't publish a build.

## Branches

| Branch | Purpose | Releases |
|--------|---------|----------|
| `develop` | Reviewed changes and beta testing | Beta and release candidates |
| `main` | Stable source and the trusted release workflow | Stable |
| Contributor branches | Individual changes, merged into `develop` | None |

The source commit must already be merged into `develop` for beta/RC or `main` for stable. An older tested commit remains releasable after the branch advances. Promote stable code with a `develop` to `main` PR, then merge `main` back into `develop`. Merge hotfixes back into `develop` too.

## Publish a release

1. Merge and test the source on the appropriate branch.
2. Fetch the branches and copy the full source commit SHA:

   ```bash
   git fetch origin main develop
   git rev-parse origin/develop
   ```

   Use `origin/main` for a stable release.

3. Open **Actions > Release > Run workflow**. Select **main** as the workflow branch. The `source_commit` input selects the application code separately.
4. Fill in the inputs below. Leave `publish` unchecked for a signed build you can download and inspect without publishing.
5. Approve the protected `release` environment when prompted, then check the run and download its artifact.
6. To publish, start a run with the same source and version and enable `publish`. Confirm the GitHub release and appcast entry afterward.

| Input | Value |
|-------|-------|
| `version` | Three numbers, such as `0.2.0`, without `v` or a channel suffix |
| `channel` | `beta`, `rc`, or `stable` |
| `number` | A positive beta/RC number, such as `3`; ignored for stable |
| `source_commit` | The full 40-character lowercase commit SHA |
| `publish` | Whether to publish the GitHub release, tag, and Sparkle update |

These inputs produce tags such as `v0.2.0-beta.3`, `v0.2.0-rc.3`, or `v0.2.0`. Branch names and short SHAs aren't accepted as the source.

## Build and publication

Every new build runs tests, builds Release, signs with Developer ID, notarizes and staples the app, and verifies the Sparkle archive signature. The artifact is named `release-<run_id>` and contains:

- `GameMode-<version>.zip`, containing the app.
- `release.json`, recording the source commit, version, channel, SHA-256 checksum, archive length, and Sparkle signature.

Artifacts are retained for 90 days, subject to repository limits. Signing and notarization credentials are required even when `publish` is unchecked.

With `publish` enabled, the workflow creates or verifies the source tag, creates or resumes a draft release, uploads and verifies its assets, and publishes it. Beta and RC releases are prereleases; stable releases are marked Latest.

The feed job then downloads and verifies the published archive before updating only `appcast.xml` on `main`. The archive is available before Sparkle advertises it. Publication doesn't merge application code.

Record each published release in the [changelog](../CHANGELOG.md) with its publication date, user-visible changes, and release link. Keep beta and stable entries separate and include only changes that shipped.

A new run after a build-only run builds again. The publish input can't be changed on a rerun. Once a release exists, later runs for the same version and source verify and reuse its assets.

## Retry a failed run

Use **Re-run failed jobs** for a transient failure. **Re-run all jobs** also preserves completed artifacts and published assets.

| Failure point | Retry behavior |
|---------------|----------------|
| Before a completed artifact exists | The same source and version can be rebuilt |
| After this run's artifact exists | The archive is verified and reused without overwriting it |
| During draft uploads | Missing assets are uploaded from the saved artifact; complete assets must match |
| After publication, before the feed update | Rerun the feed job; it verifies the published archive without rebuilding |
| During a repeated feed update | Identical metadata is a no-op and keeps the original publication date |

An incomplete draft without an accessible build artifact requires a rerun of the original workflow. Empty GitHub `starter` assets left by a failed upload can be removed only while the release is a draft.

Conflicting tags, asset bytes, or feed entries stop the run. Tags aren't moved and published assets aren't replaced. An existing legacy tag without the `v` prefix also reserves that version.

Source or workflow fixes need a new run. An unpublished version can be reused if no tag or release exists. Once a tag exists, use a new version for different code.

Release jobs share a concurrency group and don't cancel a running publisher. GitHub can replace an older pending run with a newer pending run, so check the Actions queue before submitting another. Feed pushes retry against the latest `main` without force-pushing or dropping other channel entries.

## Feature flags

[Config/FeatureFlags.xcconfig](../Config/FeatureFlags.xcconfig) supplies conditions to the app and test targets.

| Configuration | Channel | Conditions | Displays |
|---------------|---------|------------|----------|
| Debug | Any | `DEBUG` and all `GAMEMODE_BETA_FEATURES`; `GAMEMODE_BETA` only on beta | Included |
| Release | `stable` | No beta feature conditions | Excluded |
| Release | `rc` | Same feature conditions as stable | Excluded |
| Release | `beta` | `GAMEMODE_BETA FEATURE_DISPLAYS` | Included |

All distributed builds use Release. Xcode runs Debug by default and includes beta features for local development. `./build.sh` builds Release and defaults to stable:

```bash
./build.sh --channel stable CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
./build.sh --channel beta CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
./build.sh --channel rc CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
```

For direct `xcodebuild` calls, set `GAMEMODE_CHANNEL` to `stable`, `beta`, or `rc`. Add beta feature conditions to `GAMEMODE_BETA_FEATURES` and guard both UI and effect entry points.

CI clears `GAMEMODE_DEBUG_FEATURES` when running Debug tests so each channel is tested with its shipped feature set. The stable/beta matrix builds Release and runs Swift tests; the required aggregate check is named **build**. Feed-only pushes skip checks.

Displays includes refresh rate management and its Low Power Mode controls. Stable and RC Release builds exclude the view and activation paths, including changes requested by saved preferences. A remembered Displays destination falls back to General. Display preferences are retained, and recovery remains compiled in every channel.

## Sparkle versions and channels

Installed apps use this shared feed URL:

`https://raw.githubusercontent.com/nikita-moshyn/gamemode-macos/main/appcast.xml`

Keep that URL and the existing Sparkle signing key. GitHub's Latest and prerelease labels don't control Sparkle's selection; feed channels and comparable build versions do.

| Tag | Display version | Bundle/feed build version | Sparkle channel |
|-----|-----------------|---------------------------|-----------------|
| `v0.2.0-beta.1` | `0.2.0-beta.1` | `0.2.0b1` | `beta` |
| `v0.2.0-beta.2` | `0.2.0-beta.2` | `0.2.0b2` | `beta` |
| `v0.2.0-rc.1` | `0.2.0-rc.1` | `0.2.0rc1` | `rc` |
| `v0.2.0` | `0.2.0` | `0.2.0` | Omitted for stable |

Sparkle ignores the part after a hyphen when comparing versions. Use the build versions above to preserve beta, RC, then stable ordering within a base version.

**Receive beta updates** defaults to off. Enabling it allows beta and RC alongside stable updates; manual checks use the same choice. Changing it resets Sparkle's update cycle while respecting the automatic-check preference. Installing a beta manually doesn't opt the user into future betas.

Turning the preference off doesn't downgrade the installed app. A newer stable release is needed for the next stable update. Use a beta base version above the current stable version; for example, after `0.1.1`, use `0.1.2-beta.1` or higher. Apps without the beta preference need a stable update containing it before users can opt in.

## Repository configuration

The workflow expects the following setup:

1. The release workflow and scripts are on `main`; the source being released includes the channel build configuration and bundle metadata.
2. `main` and `develop` require the **build** check. Changes to the release workflow are protected. Runs and reruns are accepted only from the repository owner, with the workflow on `main`.
3. A GitHub environment named `release` allows the `main` workflow branch. Configure the owner as the required reviewer and allow self-review for solo releases. Availability depends on the account and repository visibility.
4. The environment contains the secrets below. Keep signing secrets at environment scope and remove any repository-level duplicates.
5. `RELEASE_PUBLISH_TOKEN` can create tags and releases and push feed commits to `main` under the active rulesets. The default workflow token has read-only repository permissions.
6. Enable **Private vulnerability reporting** under **Settings > Advanced Security** so the [security policy](../SECURITY.md) leads to a working private report form. See [GitHub's setup instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).

| Secret | Purpose |
|--------|---------|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded Developer ID signing certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | Certificate password |
| `NOTARIZATION_APPLE_ID` | Apple ID for notarization |
| `NOTARIZATION_PASSWORD` | App-specific notarization password |
| `NOTARIZATION_TEAM_ID` | Apple developer team |
| `SPARKLE_PRIVATE_KEY` | Existing private key used to sign update archives |
| `RELEASE_PUBLISH_TOKEN` | GitHub publication and feed push credentials |

Build and signing jobs use the `xcode-27` runner label. Preparation, publication, and feed jobs use `ubuntu-latest`. Release tools come from the workflow commit; application code comes from `source_commit`.

When configuring release delivery, download and inspect a build with `publish` unchecked first. Verify an installed beta-to-stable update with real builds too. Local tests don't verify the live environment secrets, runner, or repository rulesets.
