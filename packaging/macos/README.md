# Mac release preparation

Requires macOS 26+, Xcode 27 and Python 3. Build a universal (Apple silicon and Intel) Release candidate:

```sh
python3 packaging/macos/prepare-release.py
```

The ignored `dist/macos/` directory receives a zip, corresponding Apple source archive, build metadata
and SHA-256 checksums. The app contains the license, attribution and privacy notice. It is signed ad hoc
and labelled `local`: use it for local testing, not as a public Mac download. No upload or installation occurs.

For distribution, install a **Developer ID Application** certificate and its private key, then run:

```sh
python3 packaging/macos/prepare-release.py --identity 'Developer ID Application: Your Name (TEAMID)'
```

The `signed` zip still requires notarization. After approving that artifact for submission, use a notarytool
Keychain profile (never put Apple credentials in the repository):

```sh
xcrun notarytool submit dist/macos/dustpan-mac-0.19.1-universal-signed.zip --keychain-profile dustpan --wait
```

Require an Accepted result. Extract the app into a temporary folder, staple with `xcrun stapler staple`,
validate with `xcrun stapler validate` and `spctl --assess --type execute --verbose=2`, then re-create the
zip from that stapled app using `ditto -c -k --sequesterRsrc --keepParent`. Recompute its checksum and record
the notarization result. Keep the matching source archive available beside the binary.

Try the final downloaded build on a clean user profile: standalone startup, task editing, reminders,
notifications, open at login, and connecting/disconnecting a development server. Do not use real data for
release screenshots. The [release checklist](../../RELEASING.md) covers publication separately.
