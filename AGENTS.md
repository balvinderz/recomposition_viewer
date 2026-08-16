# Repository guidance

## Scope

This repository contains a Flutter macOS app, a macOS Flutter plugin, and a
Python inspector backend/Codex plugin. Read `docs/ARCHITECTURE.md` before changing
cross-process behavior.

## Validation

Run `./scripts/verify.sh` after changes. Device integration must also exercise
attach, automatic capture, a navigation/root change, preview selection and
highlight, and detach.

## Invariants

- Never hardcode developer paths, device serials, application IDs, or ports.
- Never commit downloaded Compose inspector JARs, app captures, credentials, or
  proprietary assets.
- Keep Flutter and MCP transports backed by the same Python session logic.
- Preserve stable ordering and full ancestry in hierarchy projections.
- Treat screen, video, and composable bounds as separate coordinate spaces.
- Every process, socket, timer, subscription, texture, and ADB forward needs an
  explicit cleanup owner.
- Update third-party notices and hashes when bundled artifacts change.
