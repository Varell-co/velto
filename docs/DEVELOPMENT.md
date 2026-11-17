# Building Velto

Build with Swift and Xcode on macOS. Velto targets macOS 13 and later.

```sh
swift build
swift run VeltoChecks
bash build-app.sh
```

The install script builds and signs the app locally, then installs it to `~/Applications/Velto.app`. The CLI ships at `Contents/Helpers/velto` inside the app bundle.

## Capture demo screens

```sh
VELTO_SNAPSHOTS=/tmp/velto-shots swift run VeltoApp
```

The debug build captures the menu and main window with demo data and exits.

## Release

Run `bash build-release.sh "$(cat VERSION)"` to create a universal Apple silicon and Intel ZIP in `dist/`. The app uses an ad-hoc signature and ships without notarization.

Run `bash publish-release.sh [patch|minor|major]` from a clean `main` that matches `origin/main` to publish the ZIP on GitHub and update the version and SHA-256 in the Homebrew cask. Confirm the project name is cleared before publishing.
