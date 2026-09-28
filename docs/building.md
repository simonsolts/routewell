# Building Routewell

Routewell needs macOS 26 or later and Xcode 27.

## Run the app

Open `Routewell.xcodeproj` in Xcode.

- **Routewell (Mock)** runs the app with sample data. You do not need a router.
- **Routewell** runs the app with no configuration. Set up your router in
  Settings › Router.

The mock Settings flow can store a credential in Keychain. Enter only made-up
passwords there.

## Run the tests

Package tests:

```sh
swift test --package-path RoutewellKit
```

App tests:

```sh
xcodebuild -project Routewell.xcodeproj -scheme 'Routewell (Mock)' \
  -destination 'platform=macOS' test
```

Automated tests use temporary storage and an in-memory credential store. They
never read your saved credentials.

## Signing and local data

Local builds use the project's Apple Development team and an app-specific
Keychain entitlement. Xcode automatic signing needs a development profile for
this Mac.

Mock credentials use the real Keychain. When you delete a mock profile, the app
deletes only that profile's mock credential.

The app is sandboxed. It stores settings and profiles (credential references
only) in its Application Support folder.

## Ad-hoc builds for CI

To compile and test without a signing identity, sign ad hoc. Keep the sandbox
entitlements, because the key file bookmark test needs them. Remove the
Keychain access group, because it needs a provisioning profile:

```sh
cp Routewell/Routewell.entitlements /tmp/ci.entitlements
plutil -remove keychain-access-groups /tmp/ci.entitlements
xcodebuild -project Routewell.xcodeproj -scheme 'Routewell (Mock)' \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=/tmp/ci.entitlements test
```

Ad-hoc builds do not validate the Keychain identity. The CI workflow in
`.github/workflows/tests.yml` runs these steps on every pull request into
`main`.
