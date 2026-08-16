# Third-party notices

The device-side binaries in `src/android_compose_inspector/artifacts` were
built on 2026-08-16 from the Android Open Source Project UI Inspector sources:

- https://android.googlesource.com/platform/tools/base/+/mirror-goog-studio-main/ui-inspector/
- https://android.googlesource.com/platform/tools/base/+/mirror-goog-studio-main/dexter/slicer/

Those sources are licensed under the Apache License 2.0. The compiled View
inspector is a minimal implementation of the same AOSP App Inspection protocol
that returns active window `uniqueDrawingId` values.

Packaged artifact SHA-256 hashes:

- `lib_ui_inspector_agent.so`: `550f022bcf0e175b33ce4ba55ab7a639cc3ab2ac932313f60fa48833e36a523e`
- `lib_ui_inspector_service.jar`: `3ff8139f4249e98a86b3dd27e25b2cfa7bc140054e4ebb868bf123f998121033`
- `lib_ui_inspector_payload.jar`: `51ada211b1a8c7fdf2530c703e412825eee46abbef2e8f33afbb66a1112e8c4c`
- `view-inspector.jar`: `2779f8d726d9bbae54a17aa0fdee54ffa48db094724cd299b5a41f7747164949`

The version-matched Jetpack Compose `inspector.jar` is not redistributed by
this plugin. It is resolved at runtime from the user's Gradle cache or Google's
Android Maven repository.
