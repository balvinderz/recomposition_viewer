# Releasing

1. Update `version` in `pubspec.yaml`, the backend/plugin versions when they
   changed, and `CHANGELOG.md`.
2. Run `./scripts/verify.sh` on macOS with the supported Flutter and Python
   versions.
3. Run `./scripts/build_macos.sh release` and smoke-test attach, automatic
   capture, tree refresh, preview selection, highlight, and detach on a device.
4. Run `./scripts/package_dmg.sh release` to produce
   `dist/Recomposition-Viewer-macOS.dmg`.
5. For public distribution, sign the app with a Developer ID Application
   certificate and notarize it with Apple before packaging. The local build
   script only applies an ad-hoc signature, so a downloaded DMG still shows a
   Gatekeeper warning on first launch until notarization is added.
6. Create an annotated `vX.Y.Z` tag and push it. The release workflow builds
   the app, packages the DMG, and attaches it with a SHA-256 checksum to a
   draft GitHub release.

The GitHub-hosted build is suitable for testing but cannot be notarized until
the repository is configured with Apple signing credentials. Never commit
certificates, private keys, API keys, or notarization passwords.
