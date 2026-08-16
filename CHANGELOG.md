# Changelog

All notable changes are documented here. This project follows Semantic
Versioning where practical.

## [Unreleased]

- Renamed the user-facing desktop application to Recomposition Viewer.
- Prepared the app, native scrcpy package, and Compose inspector backend as one
  self-contained open-source repository.
- Removed machine-specific paths, product-specific defaults, and proprietary
  font assets.
- Added portable development/build scripts, CI, release automation, community
  files, architecture documentation, and third-party notices.
- Adopted the refreshed amber-on-near-black color system with open-licensed
  Sora and IBM Plex Mono typography.
- Isolated the packaged backend from the launch directory and explicitly select
  Python 3.11 through `uv`.
- Corrected hottest-first ordering to rank recent recompositions rather than
  skips, which represent work the runtime avoided.
- Replaced the placeholder app mark with the supplied device-counter design and
  added a persistent preview click-to-highlight hint.
- Switched the desktop preview from the vendored plugin path to the published
  `scrcpy_video_view` package.

## [1.3.2] - 2026-08-16

- Added expandable/collapsible hierarchy branches and reveal-on-selection for
  deeply nested composables.
- Integrated the low-latency scrcpy video plugin.
- Added preview hit testing and bounds highlighting.

## [1.3.0] - 2026-08-16

- Added live scrcpy preview and automatic capture on attach.
- Improved root refresh and inspector connection recovery across navigation.

## [1.0.0] - 2026-08-16

- Initial macOS inspector with live hierarchy, recomposition, skip, and recent
  counters.
