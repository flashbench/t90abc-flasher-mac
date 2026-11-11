# Security Policy

## Supported versions

Only the [latest release](https://github.com/flashbench/t90abc-flasher-mac/releases/latest) receives fixes.

## Reporting a vulnerability

Please report security problems privately through GitHub:
**Security → Report a vulnerability** on this repository
([direct link](https://github.com/flashbench/t90abc-flasher-mac/security/advisories/new)).

Do not open a public issue for security problems. Include the app version, your macOS version and steps to reproduce. You will get a reply as soon as possible.

## What the app does

- Talks only to an ALIENTEK T90 soldering iron in update mode over USB HID (VID `0x19F5`, PID `0x3245`).
- Reads the firmware package or image that you choose. ZIP archives are unpacked into a temporary folder that is removed afterwards.
- Makes one network request on launch, to `api.github.com`, to check for a newer release. No personal data is sent and there is no analytics.
- Opens links only in your web browser, and update downloads only from `github.com`.
