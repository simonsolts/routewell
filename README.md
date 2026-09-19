# Routewell

An unofficial macOS app for Flint routers.

Open `Routewell.xcodeproj` in Xcode and run **Routewell (Mock)** to explore the
sample Overview, sidebar, Settings, and menu bar. Requires macOS 26 or later.
The default **Routewell** scheme shows an unconfigured app. Live connections are not implemented. The mock Settings flow can store a
made-up credential in Keychain.

Run package tests:

```sh
swift test --package-path RoutewellKit
```

Run app tests:

```sh
xcodebuild -project Routewell.xcodeproj -scheme 'Routewell (Mock)' \
  -destination 'platform=macOS' test
```

## Copyright and license

Copyright © 2026 Simon Solts.

Routewell is licensed under the GNU General Public License v3.0. See
[LICENSE](LICENSE) and [COPYRIGHT](COPYRIGHT). Third-party contributions retain
their respective copyright notices; see [Third-party notices](THIRD_PARTY_NOTICES.md).

## Acknowledgements

Routewell is heavily inspired by [RouterPilot](https://github.com/TCDemo777/RouterPilot),
created by TCDemo777 and its contributors. RouterPilot's functionality and
architecture provide the foundation for this native macOS reimplementation.
Thank you to the upstream project for making its work available as open source.

Routewell is independently maintained and is not an official RouterPilot release.
See [Third-party notices](THIRD_PARTY_NOTICES.md) for upstream licensing and
attribution details.

## Disclaimer

Routewell is an independent, unofficial project. It is not affiliated with,
endorsed, sponsored, or supported by GL.iNet. GL.iNet and its product names,
logos, and trademarks belong to their respective owners. All other trademarks
are the property of their respective owners.

Use Routewell at your own risk. The software is provided "as is", without
warranty of any kind. To the extent permitted by applicable law, the authors
and contributors are not liable for any loss or damage arising from its use,
including data loss, device damage, or network disruption. See [LICENSE](LICENSE)
for the full warranty disclaimer and limitation of liability.

## Development signing and local data

Use Xcode 27. Local builds use the project's Apple Development team and an
app-specific Keychain entitlement. Xcode automatic signing needs a development
profile for this Mac. Mock credentials use the real Keychain; enter only made-up passwords in Settings ›
Router. Deleting a mock profile deletes only that profile's exact Routewell
mock credential. Settings and profiles (credential references only) are stored
in `~/Library/Application Support/Routewell`.

For ad-hoc CI compilation and tests, override signing:

```sh
xcodebuild -project Routewell.xcodeproj -scheme 'Routewell (Mock)' \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= test
```

Ad-hoc builds do not validate Keychain identity. Automated tests use temporary
storage and an in-memory credential store, never personal saved credentials.
