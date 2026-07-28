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

## Beta releases

Pass `--beta` to publish to the beta channel instead:

```sh
scripts/release.sh --beta 1.2.0-beta.1 6 ~/Desktop/meeting-notes-1.2.0-beta.1.md
```

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
