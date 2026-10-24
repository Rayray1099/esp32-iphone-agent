# iPhone app updates

Settings → App 更新 checks a small release manifest over Wi-Fi. It compares
integer build numbers and the installed bundle identifier. A newer release
can be downloaded to a temporary IPA, checked against its published byte count
and SHA-256, and shared with LCSign (or saved to Files for import).

iOS installs a signed app bundle. The app cannot replace native Swift code
using an ESP32-style binary update. LCSign must sign and install the IPA using
the existing signing identity and bundle identifier. Keep the installed app
in place to preserve its data. Signing and the iOS installation confirmation
remain outside this app; sharing the file does not prove installation.

The updater uses no GitHub login or API key and checks only when requested.
It accepts package URLs only from this repository's HTTPS release downloads.
Its checksum detects incomplete or altered downloads; it is not a separate
code-signing trust root. GitHub HTTPS and the configured signing identity are
still trusted. Cellular access is disabled for update checks and downloads.

Publish the tested original unsigned IPA and update.json under the ios-latest
prerelease, with these fields: bundleID, version, build, url, bytes, sha256,
notes. Do not publish the signing certificate, API credentials, user traces,
or a private provisioning profile. Update.json and the IPA must describe the
same build. The release download address is in AppUpdater.manifestURL.

## Build usage

Automatic CI runs lightweight host/server checks for relevant changes only.
Feature PRs no longer get duplicate push CI. Firmware, emulation and simulator
matrix checks run only through the manual CI workflow. The manual iOS device
workflow can run iPhone tests and package one device IPA in the same macOS job.
Both workflows cancel superseded runs, have time limits, and retain temporary
artifacts for three days. A release download reuses the published binary and
does not start another build.
