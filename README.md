# Routewell

An unofficial macOS app for Flint routers.

Open `Routewell.xcodeproj` in Xcode and run **Routewell (Mock)** to explore the
sample Overview, sidebar, Settings, and menu bar. Requires macOS 26 or later.
The default **Routewell** scheme shows an unconfigured app. Live connections
and credentials are not implemented in this scaffold.

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

Routewell is licensed under the GNU General Public License v3.0 only. See
[LICENSE](LICENSE) and [COPYRIGHT](COPYRIGHT). Third-party contributions retain
their respective copyright notices; see [Third-party notices](THIRD_PARTY_NOTICES.md).

## Acknowledgements

Routewell is heavily inspired by [RouterPilot](https://github.com/TCDemo777/RouterPilot),
created by [Tristan](https://github.com/TCDemo777) and its contributors. RouterPilot is the reference for
this native macOS app's feature set and how it is organised.
Thanks to Tristan for releasing it as open source.

Routewell is independently maintained and is not an official RouterPilot release.
See [Third-party notices](THIRD_PARTY_NOTICES.md) for RouterPilot's licence and
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
