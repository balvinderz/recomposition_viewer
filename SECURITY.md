# Security policy

## Supported versions

Security fixes are applied to the latest release and the default branch.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature instead of opening a
public issue. Include a minimal reproduction and the affected version, but do
not include secrets, production app data, or personally identifiable device
information.

## Trust model

This is a local developer tool with powerful debugging access. It starts `adb`,
`scrcpy`, and a Python backend; copies inspector artifacts into a selected debug
app's private directory; injects an agent; and opens localhost ADB forwards. The
macOS App Sandbox is disabled to permit those operations.

Use it only with source code, binaries, devices, and accounts you are authorized
to inspect. Review changes to artifact hashes in
`cli/THIRD_PARTY_NOTICES.md`. Do not run untrusted
builds against a device containing sensitive data.
