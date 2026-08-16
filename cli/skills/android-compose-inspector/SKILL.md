---
name: android-compose-inspector
description: Inspect live Jetpack Compose recomposition and skip counters through the official device-side UI Inspector, without Android Studio or app instrumentation. Use when diagnosing excessive recomposition, checking which composables changed during an interaction, or comparing Compose runtime behavior on an attached Android device.
---

# Android Compose Inspector

Use the MCP tools from `android-compose-inspector` to inspect a foreground,
running, debuggable Compose application selected by the user.

Before attaching, tell the user that this skill will load the official Android
UI Inspector agent into the selected debug app and maintain an adb-forwarded
connection until detach.

## Workflow

1. Call `compose_prerequisites`. If it is not ready, report the missing path and
   stop.
2. Call `compose_attach` with the exact application ID. Pass `device` when more
   than one device is connected.
3. Call `compose_start_tracking` with `reset=true` unless the user explicitly
   wants accumulated values.
4. Establish a baseline with `compose_snapshot`, or call `compose_observe` while
   the user performs the target interaction. Prefer bounded 3–10 second windows;
   the server enforces a 30-second maximum.
5. Report composables ranked by `recomposition_delta`, while distinguishing
   recompositions from `skip_delta`. Include source locations when present.
6. Call `compose_stop_tracking`, then `compose_detach` when the investigation is
   done, even if a later inspection command fails.

Never attach to an app the user has not placed in scope. Do not present a high
recomposition count alone as proof of a performance bug; correlate it with the
interaction, frequency, composable cost, and frame behavior.

If attach reports that the target is not foreground, ask the user to bring that
app to the foreground and retry. If there are no devices, report the output of
the prerequisite/attach error rather than guessing a serial.
