---
name: release
description: Build, sign, notarize, and publish a Meeting Notes release
argument-hint: "VERSION BUILD [RELEASE_NOTES_FILE]"
allowed-tools: Bash, Read, Glob, Grep
---

# Meeting Notes Release

Build, sign, notarize, and publish a release of Meeting Notes as a DMG with Sparkle auto-update support.

## Arguments

- `VERSION` — Semantic version, e.g. `0.2.0`
- `BUILD` — Integer build number, e.g. `2`. Must increase with every release.
- `RELEASE_NOTES_FILE` — Optional Markdown file with release notes.

## Prerequisites Check

Before running the release script, verify these prerequisites:

1. **Clean checkout**: `git status --porcelain` must be empty. Commit or stash everything first; the script commits the version bump and appcast itself.

2. **notarytool keychain profile**: Run `xcrun notarytool history --keychain-profile "notarytool" 2>&1 | head -3` to check. If missing, tell the user to run:
   ```
   xcrun notarytool store-credentials "notarytool" --apple-id APPLE_ID --team-id 6DA7MK99T2 --password APP_SPECIFIC_PASSWORD
   ```

3. **Developer ID certificate**: Run `security find-identity -v -p codesigning | grep "Developer ID Application"`. Must show `Andre Foeken (6DA7MK99T2)`.

4. **Sparkle tools**: Verify `generate_appcast` exists at `.build/artifacts/sparkle/Sparkle/bin/`. If missing, run `swift package resolve` first.

5. **Sparkle signing key**: `generate_appcast` reads the EdDSA private key from the login keychain under the account `meeting-notes-menu`. If it is missing, restore it from 1Password before releasing; never regenerate it, or existing installs cannot verify updates.

6. **GitHub CLI**: `gh auth status` must succeed for account `foeken`.

## Release Process

If all prerequisites pass, confirm with the user:
- The version and build number that will be released
- Remind them the release is published to `foeken/meeting-notes` on GitHub and the appcast is committed to `main`

Then run the release script:

```bash
MEETING_NOTES_NOTARY_PROFILE=notarytool ./scripts/release.sh VERSION BUILD [RELEASE_NOTES_FILE]
```

The script runs these steps automatically:
1. Set `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`
2. Build and sign `Meeting Notes.app` with `Developer ID Application`
3. Notarize the app with Apple and staple the ticket
4. Create a DMG with an Applications symlink, notarize, and staple it
5. Regenerate `appcast.xml` with an embedded, Sparkle-signed entry
6. Commit the version bump plus appcast and push to `main`
7. Create the GitHub Release `vVERSION` with the DMG attached

## After Release

Report the results to the user:
- Version and build number
- Download URL on GitHub Releases: `https://github.com/foeken/meeting-notes/releases/tag/vVERSION`
- Appcast URL: `https://raw.githubusercontent.com/foeken/meeting-notes/main/appcast.xml`

## Troubleshooting

- **"missing Sparkle tool"**: Run `swift package resolve` so SPM fetches the Sparkle artifact containing `generate_appcast`.
- **Notarization fails**: Check the `notarytool` keychain profile and that the Developer ID certificate is valid.
- **"release from a clean checkout"**: Commit or stash local changes first.
- **GitHub release already exists**: The script uploads the new DMG to the existing `vVERSION` release with `--clobber`; bump the version if that is not intended.
- **Appcast signing key prompt**: The EdDSA key must be in the login keychain under account `meeting-notes-menu`.

## Key Files

- `scripts/release.sh` — The release automation script
- `Resources/Info.plist` — App version fields plus Sparkle config (SUFeedURL, SUPublicEDKey)
- `appcast.xml` — Sparkle feed, committed to `main` in this repo
