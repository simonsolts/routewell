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
