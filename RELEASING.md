# Publishing a release

Public releases require a Developer ID Application certificate, a configured
`notarytool` Keychain profile, the `meeting-notes-menu` Sparkle signing key, and
authenticated GitHub CLI access. Signed archives are attached to GitHub Releases,
while `appcast.xml` is versioned alongside the source. Private signing material
never enters the repository.

`MEETING_NOTES_NOTARY_PROFILE` names the `notarytool` Keychain profile, which is
separate from the Sparkle signing key account. Check which profiles exist with
`xcrun notarytool history --keychain-profile <name>`, and create one with
`xcrun notarytool store-credentials`.

```sh
export MEETING_NOTES_NOTARY_PROFILE="notarytool"
scripts/release.sh 0.3.0 3 ~/Desktop/meeting-notes-0.3.0.md
```

The script updates both bundle version fields, builds and signs the app,
submits it for notarization, staples the ticket, generates an EdDSA-signed
appcast, commits the version and feed, and uploads the archive to a GitHub Release.

Automatic update checks and the standard update UI are provided by Sparkle.
Published builds read their signed appcast over HTTPS from this repository;
the update signing key remains in the release Mac's Keychain.

## Beta releases

Use `scripts/release-beta.sh` to publish to the beta channel:

```sh
scripts/release-beta.sh 1.2.0-beta.1 6 ~/Desktop/meeting-notes-1.2.0-beta.1.md
```

It wraps `scripts/release.sh --beta` and refuses a version without a prerelease
suffix, or a build number already published in either feed. `--beta` still works
directly if you need to bypass those checks.

Two feeds are published side by side:

| Feed | Contains | Read by |
| --- | --- | --- |
| `appcast.xml` | Stable releases only | Every installation by default |
| `appcast-beta.xml` | Betas **and** stable releases | Macs set to the beta channel |

A stable release is written to *both* feeds, so a beta tester keeps receiving
stable releases rather than being stranded on an ageing test build. Beta entries
carry `<sparkle:channel>beta</sparkle:channel>`, so a stable updater ignores
them even if it ever read that feed. Both mechanisms are applied together, and
the build number must keep increasing across channels because Sparkle orders
updates by it.

A beta version may carry a prerelease suffix (`1.2.0-beta.1`) so it can ship
ahead of the stable version it becomes. Beta releases are marked as
prereleases on GitHub.

Users choose their channel in **Settings → General → Update channel**. New
installations default to stable. Switching back to stable does not uninstall a
beta that is already running; the next stable release replaces it.
