# Reboot App Store

**An app store for jailbroken iPods on iOS 6 – installs and updates apps straight from GitHub.**

Cydia still works on an iPod touch 4, but most of its repos are dead and nothing new shows up there. Reboot is a small store for the apps in this organization: open it, tap *Install*, and the app appears on the home screen a few seconds later. Updates show up as soon as a new release is published here.

## How it works

- **Catalog:** the store reads [`apps.json`](apps.json) from this repo. It first asks GitHub for the current commit of `main` and then loads the catalog at exactly that commit, so a new app or update is visible immediately instead of after the 5-minute CDN cache.
- **No API rate limit trouble:** the version, download URL, size and SHA-256 of every release are written into the catalog when it is published. The iPod never has to query the GitHub API per app (unauthenticated clients only get 60 requests an hour, shared by every device on the same connection).
- **Real TLS on iOS 6:** iOS 6 can no longer talk to GitHub on its own. Reboot brings its own [mbedTLS](https://github.com/Mbed-TLS/mbedtls) with a bundled CA list and refuses any connection whose certificate does not verify.
- **Checked packages:** every `.deb` is checked against the SHA-256 from the catalog before anything is installed.
- **Tiny root helper:** installing needs root, so a small setuid helper (`src/rbhelper.c`) does the `dpkg` part and nothing else. It only accepts packages from the store's own download folder, copies them to a root-only folder before checking them, only installs packages in the `de.mesh.*` namespace, stops a running copy of the app first and finishes with `dpkg --configure -a` so an interrupted install never leaves a half-configured app behind.
- German and English, follows the device language – including the app descriptions.

## Adding an app

Every app has its own repo with a `reboot.json` and GitHub releases containing the `.deb`. Add an entry to `apps.json` and it shows up in every store on the next refresh.

## Install

Download the `.deb` from the [latest release](https://github.com/SecondTrack/reboot/releases/latest), copy it to the iPod and run `dpkg -i` as root, then `uicache`. After that, Reboot updates itself.

Build it yourself with [Theos](https://theos.dev): `make package`.

## License

GPL-3.0 – see [LICENSE](LICENSE). mbedTLS under `vendor/` keeps its own license.
Not affiliated with Apple. iPod is a trademark of Apple Inc.
