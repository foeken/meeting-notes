# Publishing a release

Public releases require a Developer ID Application certificate, a configured
`notarytool` Keychain profile, the `meeting-notes-menu` Sparkle signing key, and
authenticated GitHub CLI access. Signed archives are attached to GitHub Releases,
while `appcast.xml` is versioned alongside the source. Private signing material
never enters the repository.

```sh
export MEETING_NOTES_NOTARY_PROFILE="meeting-notes-menu"
scripts/release.sh 0.3.0 3 ~/Desktop/meeting-notes-0.3.0.md
```

The script updates both bundle version fields, builds and signs the app,
submits it for notarization, staples the ticket, generates an EdDSA-signed
appcast, commits the version and feed, and uploads the archive to a GitHub Release.

Automatic update checks and the standard update UI are provided by Sparkle.
Published builds read their signed appcast over HTTPS from this repository;
the update signing key remains in the release Mac's Keychain.
