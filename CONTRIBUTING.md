# Contributing

Thanks for helping improve Recomposition Viewer. Bug reports, protocol research,
tests, documentation, and focused pull requests are welcome.

## Development setup

```sh
git clone <your-fork-url>
cd recomposition_inspector
./scripts/bootstrap.sh
./scripts/verify.sh
```

Run the app with `flutter run -d macos`. Inspector integration work requires an
authorized API 29+ arm64 Android device and a foreground debuggable Compose app;
unit tests do not.

## Pull requests

- Open an issue first for broad UI redesigns, new platforms, or protocol changes.
- Keep each pull request focused and explain the user-visible behavior.
- Add deterministic tests for tree projection, geometry, protocol framing, and
  lifecycle changes where practical.
- Run `./scripts/verify.sh` and include manual device verification for changes
  that cross ADB, the inspector agent, or scrcpy.
- Do not add captured app data, device identifiers, proprietary fonts/assets,
  downloaded Compose inspector JARs, or signing credentials.
- Update architecture or release documentation when a contract changes.

## Style

Dart follows `dart format` and `flutter_lints`. Python follows Ruff with the
configuration in the backend `pyproject.toml`. Prefer small named domain types
over unstructured maps at UI boundaries, and include actionable context in
errors that cross a process boundary.

## Reporting bugs

Include the macOS, Flutter, Android API/ABI, Compose UI, adb, and scrcpy versions;
the target app must be anonymized unless you are allowed to share it. Describe
whether the failure occurred during prerequisites, attach, capture, refresh,
preview startup, or detach.

By contributing, you agree that your work is licensed under Apache-2.0.
