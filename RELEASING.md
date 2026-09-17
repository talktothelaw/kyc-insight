# Releasing — iOS

There is no release process. **Merging to `main` is the release.**

```
merge to main
      ↓
GitLab CI: validate   (swift build + swift test)
      ↓
GitLab CI: mirror     (push main to the GitHub repo consumers resolve from)
      ↓
consumers: swift package update  /  pod update KYCWidget
```

No tags, no version bump, no `pod trunk push`, nothing to run by hand.

## What consumers depend on

```swift
.package(url: "https://github.com/talktothelaw/kyc-insight.git", branch: "main")
```

```ruby
pod 'KYCWidget',
    :git => 'https://github.com/talktothelaw/kyc-insight.git',
    :branch => 'main'
```

## Consequences worth knowing

**Main is live.** Anything merged reaches consumers on their next update, with
no version for them to hold back on. `validate` runs `swift build` and
`swift test` before the mirror job, so a red build is never mirrored — but it
only protects what the tests cover.

**`validate` needs a macOS runner** tagged `macos`. Without one the job never
runs and the mirror is ungated, which removes the only thing standing between
a broken commit and every consumer app. Set `SKIP_IOS_VALIDATE=true` to
deliberately bypass it; leaving it permanently skipped defeats the design.

**Rolling back means merging a revert.** There is no earlier tag for a
consumer to pin to. If you need a version someone can hold, cut a tag by hand
— SPM and CocoaPods both still resolve tags, and the mirror still pushes them.

**`s.version` in `KYCWidget.podspec` is informational.** Nothing resolves
against it. Bump it only to mark a new release line, matching `releaseLine`
in the Android SDK's `sdk/build.gradle.kts`.

## Verifying a release landed

```bash
git ls-remote https://github.com/talktothelaw/kyc-insight.git refs/heads/main
```

The SHA should match what you merged. Consumers get it on their next update.
