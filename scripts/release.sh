#!/usr/bin/env bash
# release.sh — atomic version bump + commit + tag + push for the iOS SDK.
#
# Usage:    scripts/release.sh <version>
# Example:  scripts/release.sh 0.2.2
#
# Edits KYCWidget.podspec to set `s.version = "<version>"`, commits the
# change, tags it, and pushes main + the new tag. The GitLab
# `mirror_to_talktothelaw` CI job propagates the tag to the GitHub mirror
# that CocoaPods Trunk fetches from. SPM consumers can resolve the tag
# immediately after the mirror job goes green.
#
# CocoaPods Trunk publish is intentionally NOT automated — Trunk uses your
# personal `pod trunk register` credentials and is append-only. After this
# script finishes and the mirror job goes green, run manually:
#
#     pod trunk push KYCWidget.podspec --allow-warnings

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version>     e.g. $0 0.2.2" >&2
    exit 2
fi
version="$1"

# Reject anything that isn't strict semver — CocoaPods Trunk accepts loose
# strings but pinning hosts (e.g. consumer Podfiles using `'~> 0.2'`)
# require a strict pattern.
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "error: '${version}' is not a valid semver (e.g. 0.2.2 or 0.2.2-rc.1)" >&2
    exit 2
fi

# Refuse to release with uncommitted edits — would otherwise be silently
# rolled into the release commit.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree has uncommitted changes — commit or stash first" >&2
    git status --short >&2
    exit 2
fi

# Tag must not exist locally or on origin (Trunk is append-only — re-using
# a version is a permanent mistake; this catches a stale local tag too).
if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
    echo "error: tag '${version}' already exists locally; delete with: git tag -d ${version}" >&2
    exit 2
fi
if git ls-remote --exit-code --tags origin "refs/tags/${version}" >/dev/null 2>&1; then
    echo "error: tag '${version}' already exists on origin — Trunk is append-only, pick a new version" >&2
    exit 2
fi

# Bump the podspec version — match the single `s.version = "..."` line.
podspec_file="KYCWidget.podspec"
if [[ ! -f "$podspec_file" ]]; then
    echo "error: $podspec_file not found — run from the repo root" >&2
    exit 2
fi
tmp="$(mktemp)"
awk -v v="$version" '
    /^[[:space:]]*s\.version[[:space:]]*=[[:space:]]*"/ {
        sub(/"[^"]+"/, "\"" v "\""); seen=1
    }
    { print }
    END { if (!seen) { print "no s.version line found" > "/dev/stderr"; exit 1 } }
' "$podspec_file" > "$tmp"
mv "$tmp" "$podspec_file"

# Sanity check the edit landed.
if ! grep -qE "^[[:space:]]*s\.version[[:space:]]*=[[:space:]]*\"${version}\"" "$podspec_file"; then
    echo "error: version edit failed — $podspec_file unchanged or malformed" >&2
    exit 1
fi

git add "$podspec_file"
git commit -m "Release ${version}"
git tag "${version}"

# Push commit + tag together so CI + the mirror see them atomically.
git push origin HEAD --tags

cat <<EOF

Released ${version}. Next steps:

  1. Wait for the GitLab \`mirror_to_talktothelaw\` CI job to push the tag
     to https://github.com/talktothelaw/kyc-insight.git (SPM consumers can
     already resolve from that URL once the mirror lands).
  2. Then run from this directory:

         pod trunk push KYCWidget.podspec --allow-warnings

  3. cocoapods.org typically indexes the new version in 15–30 minutes.
EOF
