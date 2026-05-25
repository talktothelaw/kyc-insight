# Releasing — KYCWidget (iOS)

Step-by-step for publishing a new version of **KYCWidget** to
**CocoaPods Trunk** and making it available via **Swift Package Manager**.

## One-time setup

```bash
# Install the CocoaPods CLI if needed.
sudo gem install cocoapods

# Register your CocoaPods Trunk account (replace with your email/name).
pod trunk register you@netapps.com.ng "Your Name" --description="laptop"
# A confirmation link will be emailed — click it before continuing.

# Confirm:
pod trunk me
```

## Repository topology

This project lives on GitLab as the source of truth:

- **GitLab origin (private)**:
  `git@gitlab.com:netapps/kyc/kyc-ios-wiget.git`
- **GitHub mirror (public)**:
  `https://github.com/talktothelaw/kyc-insight.git`

The `.gitlab-ci.yml` job `mirror_to_talktothelaw` pushes every commit and
every tag from GitLab `origin` to the GitHub mirror automatically.
`KYCWidget.podspec`'s `s.source` URL points at the GitHub mirror — that
is the URL CocoaPods Trunk fetches the tagged release from during
`pod trunk push`. The two MUST stay in sync; if you ever change the
GitLab CI `MIRROR_URL`, update the podspec `s.source.:git` in the same
commit.

## Per-release checklist

1. **Bump the version** in the podspec. SPM has no version constant —
   it consumes the git tag directly.

   ```ruby
   # KYCWidget.podspec
   s.version = "0.2.0"
   ```

2. **Update the changelog** (in `CHANGELOG.md` if one is added later,
   or in the release-tag annotation in step 5).

3. **Verify the build is clean**:

   ```bash
   swift build
   swift test
   xcodebuild -scheme KYCWidget \
              -destination 'generic/platform=iOS Simulator' build
   ```

4. **Lint the podspec** (catches metadata, source, license, and
   dependency issues without touching Trunk):

   ```bash
   pod lib lint KYCWidget.podspec --allow-warnings
   ```

   Warnings about the long description or the vendored `External/`
   sources are expected; errors are not. If lint passes, the publish
   step is very unlikely to fail.

5. **Commit and tag**. The tag name MUST match `s.version` exactly —
   CocoaPods Trunk fetches the source by this tag from the GitHub mirror.

   ```bash
   git add -A
   git commit -m "Release 0.2.0"
   git tag 0.2.0
   git push origin main --tags
   ```

   Once the tag is on GitLab:
   - The `mirror_to_talktothelaw` CI job runs and propagates both the
     commit and the tag to GitHub. Wait for it to go green before step 6.
   - SPM consumers can already resolve `0.2.0` from the GitHub mirror.

6. **Publish to CocoaPods Trunk**:

   ```bash
   pod trunk push KYCWidget.podspec --allow-warnings
   ```

   Trunk will:
   - Re-fetch the tag from the GitHub mirror declared in `s.source`.
   - Run `pod spec lint` server-side.
   - Publish to the master spec repo.

   Indexing on cocoapods.org typically takes 15–30 minutes.

## Verification

```bash
# SPM — clean test consumer
mkdir /tmp/spm-check && cd /tmp/spm-check
swift package init --type executable
# Edit Package.swift to add KYCWidget as a dependency:
#   .package(url: "https://github.com/talktothelaw/kyc-insight.git", from: "0.2.0")
swift package resolve

# CocoaPods — clean test consumer (after `pod trunk push` completes
# AND cocoapods.org has indexed the new version).
mkdir /tmp/cp-check && cd /tmp/cp-check
pod init  # then add `pod 'KYCWidget', '~> 0.2.0'` to the Podfile
pod install --repo-update
```

## Troubleshooting

- **`pod trunk push` rejects with "missing license"** — the podspec must
  use `license = { :type => "MIT", :file => "LICENSE" }` AND the LICENSE
  file must be present in the tagged commit. Check both.

- **`pod trunk push` fails fetching the source** — usually means the
  GitLab → GitHub mirror CI job hasn't completed yet, or the
  `s.source.:git` URL in the podspec doesn't match the actual mirror.
  Verify with `git ls-remote <url>` that the tag is visible at the URL
  declared in the podspec.

- **SPM resolve hangs forever** — the GitHub mirror is public over HTTPS;
  if a consumer hangs, check that they're not accidentally pointing at
  the private GitLab URL (`git@gitlab.com:...`) which requires an SSH
  key. Always share the `https://github.com/...` URL with consumers.

- **CocoaPods Trunk is append-only** — a published version cannot be
  deleted, only deprecated (`pod trunk deprecate KYCWidget`). Triple-
  check the version number before step 6.
