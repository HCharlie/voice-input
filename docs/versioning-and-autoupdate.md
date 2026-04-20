# Versioning & Auto-Update Design

## Overview

This document covers the strategy for adding versioning and in-app auto-update to VoiceInput. The goal is a VS Code-style experience: the app periodically checks for new releases, shows a non-intrusive dialog, and installs the update with one click — without the user having to rerun `make install` or manually download anything.

---

## 1. Versioning Scheme

### Version numbers

Use **Semantic Versioning** (`MAJOR.MINOR.PATCH`):

| Field | Key | Example | Meaning |
|---|---|---|---|
| User-visible version | `CFBundleShortVersionString` | `1.2.0` | What users and the update checker see |
| Build number | `CFBundleVersion` | `7` | Monotonically increasing integer; used internally by the OS |

**Current state:** both fields are `1.0` — need to split them into `1.0.0` / `1`.

### Bump rules

- `PATCH` — bug fixes, minor polish (e.g. `1.0.1`)
- `MINOR` — new features, backwards-compatible (e.g. `1.1.0`)
- `MAJOR` — breaking changes or major rewrites (e.g. `2.0.0`)

Build number increments on every release regardless of version type.

### Git tagging convention

Every release is tagged: `v1.2.0` (with the `v` prefix, matching GitHub Releases convention).

---

## 2. Update Mechanism

### Recommended: Custom GitHub Releases checker (no external dependencies)

Rather than pulling in a large framework like Sparkle, VoiceInput uses the **GitHub Releases API** directly. This keeps the codebase lean and avoids framework maintenance overhead while covering everything the app needs.

**How it works:**

```
App launch (delayed 30s) ──▶ GET /repos/HCharlie/voice-input/releases/latest
                                       │
                            ┌──────────┴──────────┐
                         up to date          newer version
                            │                    │
                          done           show update dialog
                                               │
                                    ┌──────────┴──────────┐
                                 "Later"              "Install"
                                    │                    │
                                  done         download .zip asset
                                                         │
                                               extract VoiceInput.app
                                                         │
                                               replace /Applications/VoiceInput.app
                                                         │
                                                     relaunch
```

**Version comparison:** compare `tag_name` from the API response (e.g. `v1.2.0`) against `CFBundleShortVersionString` embedded in the running app. Parse as semver tuples; install if remote is strictly newer.

**Check frequency:**
- Once on launch (after a 30-second startup delay, so it doesn't compete with permission prompts)
- Via "Check for Updates..." menu item (immediate, user-triggered)

**No background polling loop** — checking once per launch is sufficient for a tool like this. Users who want immediate updates can use the menu item.

### Why not Sparkle?

[Sparkle](https://sparkle-project.org) is the industry-standard macOS update framework and is the right choice if you want:
- EdDSA signature verification of downloaded updates (tamper protection)
- Delta updates (only download the diff)
- A mature, tested installation flow

The trade-offs for this project:
- Requires hosting an `appcast.xml` feed and keeping it updated
- Requires generating and safeguarding EdDSA private keys
- Adds a large framework dependency (~10 MB)
- Needs special entitlements and sandbox considerations

For a personal/open-source project distributed via GitHub, the custom approach is simpler and sufficient. **Sparkle remains the right upgrade path** if VoiceInput ever moves to wider distribution.

---

## 3. The Permission Persistence Problem

This is the hardest part of the design.

### Why permissions get revoked

macOS stores Accessibility permissions in its TCC (Transparency, Consent, and Control) database keyed by **bundle identifier + code signing requirement**. When the app binary changes (new build), the code hash changes. On macOS 13+, TCC invalidates the permission entry because the binary no longer matches what the user originally approved.

The current build uses **ad-hoc code signing** (`codesign --sign -`). Ad-hoc signing is per-machine and per-binary — every new build produces a different signature. This means every update, even with the same bundle ID, will cause macOS to revoke the Accessibility permission.

### Solutions (ranked by quality)

| Option | Permissions survive update? | Complexity | Cost |
|---|---|---|---|
| Apple Developer certificate (hardened runtime) | ✅ Yes | Medium | $99/year |
| Same ad-hoc key, preserved across builds | ❌ No (hash still changes) | — | — |
| Accept revocation, guide the user | ⚠️ No, but recovery is one click | Low | Free |

### Recommended approach: Accept + guide

Without an Apple Developer certificate, permissions will be revoked after each update. The pragmatic solution is to make recovery frictionless:

1. The app already calls `AXIsProcessTrustedWithOptions` on launch and polls every 2 seconds until permission is granted.
2. After an update, the app relaunches, detects the missing permission, and shows the existing Accessibility alert — which opens System Settings directly.
3. Enhance this alert slightly: add a message like "VoiceInput was updated. Please re-grant Accessibility access (this only happens after updates)."

This is a one-time, 5-second action per update. Users of comparable unsigned tools (e.g. Karabiner-Elements before signing) accept this pattern.

### Long-term: Apple Developer certificate

If/when you get an Apple Developer ID certificate:
- Sign with `codesign --sign "Developer ID Application: Your Name (TEAMID)"` and `--options runtime` (hardened runtime)
- Notarize with `xcrun notarytool`
- Permissions persist across updates automatically
- Users don't see the Gatekeeper "unidentified developer" warning on first launch

---

## 4. Implementation Plan

### Phase 1 — Versioning (small, do first)

- [ ] Update `Info.plist`: set `CFBundleShortVersionString` to `1.0.0`, `CFBundleVersion` to `1`
- [ ] Add `SUFeedURL` key to `Info.plist` (can be empty for now, used later by Sparkle if adopted)
- [ ] Add a `Version` computed property in Swift that reads `CFBundleShortVersionString` from the bundle
- [ ] Show version in the menu bar: add a disabled "VoiceInput 1.0.0" item at the top of the menu
- [ ] Add `make release VERSION=x.y.z` target to Makefile that bumps both plist fields and creates a git tag

### Phase 2 — Update checker

- [ ] Create `UpdateChecker.swift`: calls `https://api.github.com/repos/HCharlie/voice-input/releases/latest`, decodes JSON, compares `tag_name` to running version
- [ ] Show a native `NSAlert`-based dialog with the version number and release notes (from `body` in the API response)
- [ ] On "Install": download the `.zip` asset, unzip to a temp directory, move `VoiceInput.app` to `/Applications`, relaunch
- [ ] Add "Check for Updates..." menu item (below the version label)
- [ ] Add the background check on launch (delayed, skipped in debug builds)
- [ ] Handle errors gracefully: network failure, asset not found, disk write permission denied

### Phase 3 — Release workflow (GitHub Actions)

- [ ] Create `.github/workflows/release.yml`: triggers on `push` to tags matching `v*.*.*`
- [ ] Workflow steps:
  1. `swift build -c release`
  2. Assemble `.app` bundle (same as Makefile)
  3. Ad-hoc codesign
  4. Zip: `zip -r VoiceInput-v1.x.x.zip VoiceInput.app`
  5. `gh release create v1.x.x --generate-notes VoiceInput-v1.x.x.zip`
- [ ] After workflow runs, the release is live on GitHub and the update checker will find it

### Phase 4 — Post-update permission guidance (enhancement)

- [ ] After relaunch, detect that Accessibility permission was revoked
- [ ] Show a targeted alert: "VoiceInput updated successfully. Please re-grant Accessibility access to continue using the app." with a direct link to System Settings
- [ ] (Optional) Show a macOS notification: "VoiceInput X.Y.Z installed"

---

## 5. Key Implementation Details

### Downloading and replacing the app

The app is running from `/Applications/VoiceInput.app` when it initiates the update. The replacement flow:

```
1. Download zip to $TMPDIR/VoiceInput-update/VoiceInput-vX.Y.Z.zip
2. Unzip to $TMPDIR/VoiceInput-update/VoiceInput.app
3. Move (atomic where possible) /Applications/VoiceInput.app → Trash
4. Move $TMPDIR/VoiceInput-update/VoiceInput.app → /Applications/VoiceInput.app
5. xattr -cr /Applications/VoiceInput.app (clear quarantine)
6. NSWorkspace.shared.openApplication(at: URL, configuration: ...) to relaunch
7. NSApp.terminate(nil)
```

Step 3 uses `FileManager.trashItem(at:resultingItemURL:)` rather than deletion, so the old version is recoverable from the Trash if something goes wrong.

Step 4 may require authorization if `/Applications` is not writable by the current user. On most Macs, `/Applications` is writable by the admin user, so this is typically fine. If it fails, fall back to showing an error with instructions to run `make install`.

### Semver comparison

Parse `v1.2.3` → `(1, 2, 3)` tuple. Compare component by component: major first, then minor, then patch. Only install if the remote version is **strictly greater than** the running version — never downgrade.

### GitHub API rate limits

The unauthenticated GitHub API allows 60 requests/hour per IP. One request per launch is well within this limit. No auth token needed.

### Release notes in the dialog

The GitHub Releases API returns a `body` field with the release description (Markdown). Render it as plain text in the `NSAlert.informativeText` (truncated to ~500 characters with a "See full release notes" link to the GitHub release page).

---

## 6. File Structure After Implementation

```
Sources/VoiceInput/
  AppDelegate.swift          — adds version label + "Check for Updates..." menu item
  UpdateChecker.swift        — new: GitHub API check + download/install flow
Info.plist                   — CFBundleShortVersionString = 1.0.0, CFBundleVersion = 1
Makefile                     — adds `release` target
.github/
  workflows/
    release.yml              — new: build + publish GitHub Release on tag push
```

---

## 7. Future Considerations

- **Sparkle migration**: if the project gains more users, migrate to Sparkle 2 for EdDSA-verified downloads and delta updates. The update-checker API surface (`checkForUpdates()`, delegate callbacks) can be kept compatible.
- **Apple Developer signing**: the single highest-impact improvement for user experience — eliminates the post-update permission re-grant entirely.
- **Homebrew Cask**: publish a Cask so users can `brew install --cask voice-input` and `brew upgrade` handles updates. Complements rather than replaces the in-app updater.
- **Automatic update (no dialog)**: some apps silently update in the background and notify after. This is possible but intrusive for a tool that requires Accessibility permission; the dialog approach is safer.
