# Android Compose Inspector

Exposes the official device-side Jetpack Compose inspector to AI coding agents,
either as an MCP server (Codex) or as a standalone `compose-inspector` CLI any
agent with a terminal can drive. It provides live recomposition and skip
counters without Android Studio, without a debug overlay, and without adding
instrumentation to the app.

## How it works

1. The host stages the bundled AOSP UI Inspector agent in the app sandbox and
   loads it with Android's `attach-agent` command.
2. The server discovers the agent's abstract Unix socket and forwards it with
   `adb`, reusing an agent that is already alive for the same process.
3. The persistent connection asks the app for its Compose UI version, resolves
   that exact official `inspector.jar` from the local Gradle cache or Google
   Maven, and loads the View and Compose inspectors.
4. MCP commands enable/reset counters and query fresh Compose trees while the
   socket remains connected.

This deliberately reuses the same Compose inspector protocol that powers Layout
Inspector. It does not scrape Android Studio.

## Requirements

- macOS or Linux with Python 3.11+ and `uv`
- `adb` on `PATH`
- one Android 10 / API 29 or newer device or emulator
- a running, foreground, debuggable app that uses Jetpack Compose
- network access to Google Maven on the first inspection of a Compose version,
  unless its AAR is already in the local Gradle or plugin cache

The first attach can take several seconds while the agent is loaded and the
matching Compose inspector is resolved. Production/non-debuggable apps are
intentionally unsupported. This build currently packages the native agent for
`arm64-v8a` devices.

## CLI usage (any agent)

`compose-inspector` is a normal terminal command — no MCP client required, so
it works from Claude Code, Codex, Cursor, or any agent that can run a shell
command. State (the adb port forward and the live agent socket) lives in a
background daemon that the first command starts automatically; every
subsequent command talks to that same daemon over `127.0.0.1:8756` until you
run `compose-inspector stop`.

Install it onto `PATH` as an isolated `uv tool` with one line — no clone
required:

```sh
curl -fsSL https://raw.githubusercontent.com/balvinderz/recomposition_viewer/main/cli/install.sh | bash
```

Or, from a local clone, run `./install.sh` directly (also accepts `--pip` to
force a `pip install --user` fallback instead of `uv`).

Or run it inside this project without installing:

```sh
uv sync
uv run compose-inspector prerequisites
```

Either way, the workflow is the same:

```sh
compose-inspector attach com.example.app
compose-inspector start-tracking <session_id>
compose-inspector observe <session_id> --duration-ms 5000
compose-inspector stop-tracking <session_id>
compose-inspector detach <session_id>
```

Every command prints one JSON object to stdout (add `--pretty` for indented
output) and exits non-zero on failure with `{"error": ..., "error_type": ...}`.
Run `compose-inspector --help` or `compose-inspector <command> --help` for the
full flag list, and `compose-inspector sessions` / `compose-inspector stop` to
inspect or shut down the daemon.

The CLI writes a generic `SKILL.md` to
`~/.compose-inspector/skills/compose-inspector-cli/SKILL.md` on first run.
Symlink it into whichever agent you use so it always stays current:

```sh
mkdir -p ~/.claude/skills/compose-inspector && ln -s \
  ~/.compose-inspector/skills/compose-inspector-cli/SKILL.md \
  ~/.claude/skills/compose-inspector/SKILL.md

mkdir -p ~/.codex/skills/compose-inspector && ln -s \
  ~/.compose-inspector/skills/compose-inspector-cli/SKILL.md \
  ~/.codex/skills/compose-inspector/SKILL.md
```

## MCP workflow (Codex)

Ask Codex to perform this sequence:

1. `compose_prerequisites`
2. `compose_attach` with the application ID, such as `com.example.app`
3. `compose_start_tracking`
4. interact with the app, then call `compose_observe` for 3–10 seconds or
   `compose_snapshot`
5. `compose_stop_tracking` and `compose_detach`

`compose_observe` returns only changed nodes, ranked by recomposition plus skip
deltas. Each entry includes the composable name/path, source file and line when
available, screen bounds, cumulative counts, and the counts added during the
observation.

When `app_only` is enabled, framework wrappers are collapsed while system
`Text` and `Image` leaves remain visible in the application tree.

## Available tools

- `compose_prerequisites`
- `compose_attach`
- `compose_start_tracking`
- `compose_snapshot`
- `compose_observe`
- `compose_reset_counts`
- `compose_stop_tracking`
- `compose_detach`
- `compose_sessions`

## Development

```sh
uv sync --extra test
uv run pytest
uv run python -m android_compose_inspector.server
```

The protobuf files under `proto/` are intentionally minimal, wire-compatible
subsets of AOSP's UI Inspector and Compose inspector protocols. Regenerate their
Python bindings with `scripts/generate_protos.sh` after modifying them.

## Current limitations

- Attach requires the explicitly selected app to be foreground so an accidental
  background-process attach fails safely.
- The bundled native agent currently supports `arm64-v8a`; other ABIs fail with
  a message listing the packaged ABIs.
- The agent socket name is an internal AOSP implementation detail. The server
  accepts both current (`ui_inspector_<pid>_<digest>`) and older
  (`ui_inspector_<pid>`) forms and will report a clear attach error if Android
  changes it.
- The MCP server has been exercised end-to-end against a physical API 37
  `arm64-v8a` device with Compose UI 1.11.2.

## Third-party code

The bundled device agent and the inspector protocol are derived from the
Apache-2.0-licensed [AOSP UI Inspector](https://android.googlesource.com/platform/tools/base/+/mirror-goog-studio-main/ui-inspector/).
See `THIRD_PARTY_NOTICES.md` for artifact hashes and provenance.
