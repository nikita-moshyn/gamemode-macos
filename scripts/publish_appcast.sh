#!/bin/bash
# Publish the signed update on main, preserving every channel's current feed.
set -euo pipefail

: "${TAG:?Release tag is required}"
: "${VERSION:?Display version is required}"
: "${ED_SIG:?Sparkle signature is required}"
: "${LENGTH:?Archive length is required}"
: "${RUNNER_TEMP:?Runner temporary directory is required}"

RELEASE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/release.py"
FEED_CHECKOUT="$RUNNER_TEMP/appcast-checkout"

# Every release channel uses source already merged into main. This job updates
# only the shared appcast; the source commit and release tag stay unchanged.
git fetch origin main
python3 "$RELEASE_SCRIPT" validate-source --tag "$TAG"

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
trap 'git worktree remove --force "$FEED_CHECKOUT" 2>/dev/null || true' EXIT

# A concurrent release or normal merge can advance main while we generate the
# feed. Retry from its new head rather than dropping items or forcing a push.
for ATTEMPT in 1 2 3 4 5; do
    git fetch origin main
    git worktree add --detach "$FEED_CHECKOUT" origin/main
    python3 "$RELEASE_SCRIPT" appcast \
        --path "$FEED_CHECKOUT/appcast.xml" \
        --tag "$TAG" --signature "$ED_SIG" --length "$LENGTH"
    git -C "$FEED_CHECKOUT" add appcast.xml
    if ! git -C "$FEED_CHECKOUT" diff --cached --quiet; then
        git -C "$FEED_CHECKOUT" commit -m "chore: update appcast.xml for $VERSION"
    fi

    if git -C "$FEED_CHECKOUT" push origin HEAD:main; then
        exit 0
    fi
    git worktree remove --force "$FEED_CHECKOUT"
    echo "Feed push failed (attempt $ATTEMPT/5); retrying from current main."
done

echo "ERROR: Could not publish appcast.xml. Check RELEASE_PUBLISH_TOKEN permissions and main's rulesets."
exit 1
