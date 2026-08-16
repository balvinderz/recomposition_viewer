---
name: compose-inspector-cli
description: Inspect live Jetpack Compose recomposition and skip counters on an attached Android device through the `compose-inspector` CLI, without Android Studio or app instrumentation. Use when diagnosing excessive recomposition, checking which composables changed during an interaction, or comparing Compose runtime behavior on a device.
---

# Compose Inspector CLI

`compose-inspector` is a terminal tool, not an MCP tool — run it with the Bash/
shell tool available in this environment. Every command prints one JSON object
to stdout; pass `--pretty` for indented output while exploring by hand.

A background daemon holds the live device connection (adb port forward + the
official UI Inspector agent socket) between commands. The first command that
needs it starts it automatically; nothing needs to be launched manually.

Before attaching, tell the user that this will load the official Android UI
Inspector agent into the selected debug app and keep an adb-forwarded
connection open until `detach`.

## Workflow

1. `compose-inspector prerequisites` — verifies adb and the packaged agent
   artifacts are available. If not ready, report the missing piece and stop.
2. `compose-inspector attach <package_id> [--device <serial>]` — attaches to a
   running, foreground, debuggable app. Returns a `session_id`; pass it to
   every following command. Pass `--device` only when more than one device is
   connected.
3. `compose-inspector start-tracking <session_id>` — resets counters by
   default; pass `--no-reset` only if the user explicitly wants accumulated
   values from a prior tracking window.
4. Either:
   - `compose-inspector snapshot <session_id>` for a point-in-time read, or
   - `compose-inspector observe <session_id> --duration-ms 5000` while the user
     performs the target interaction. Prefer bounded 3000-10000ms windows; the
     daemon enforces a 30000ms maximum.
5. Report composables ranked by `recomposition_delta`, distinguishing
   recompositions from `skip_delta`. Include `file`/`line` when present.
6. `compose-inspector stop-tracking <session_id>`, then
   `compose-inspector detach <session_id>` when the investigation is done —
   run detach even if a later inspection command failed.

Use `compose-inspector sessions` to see what is currently attached, and
`compose-inspector stop` to shut the daemon down entirely (detaches every
session first). You do not need to call `stop` between investigations — leave
the daemon running for the next command.

## Flags worth knowing

- `--all` on `snapshot`/`observe` includes framework/system composables
  (normally collapsed, except `Text`/`Image` leaves which stay visible).
- `--changed-only` on `snapshot` returns only nodes with a nonzero delta.
- `--port <n>` targets a non-default daemon port if the default (8756) is in
  use; pass it consistently across every command in a session.

## Guardrails

Never attach to an app the user has not placed in scope. Do not present a high
recomposition count alone as proof of a performance bug; correlate it with the
interaction, frequency, composable cost, and frame behavior.

If `attach` reports the target is not foreground, ask the user to bring that
app to the foreground and retry. If there are no devices, report the
`prerequisites`/`attach` error text rather than guessing a serial.

## Output contract

Every command prints exactly one JSON object. On success it is the raw result
(e.g. `attach` returns `{"session_id": ..., "attached": true, ...}`). On
failure it is `{"error": "...", "error_type": "..."}` and the process exits
non-zero — check the exit code, not just stdout, when scripting multiple
calls.
