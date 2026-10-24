# iPhone Use — MaxxiDev Edition

Control a real iPhone from a Mac, with local HTTP and MCP interfaces for AI agents.

**Experimental · Source release · Live-device validation pending**

[![Source checks](https://github.com/MaxxiDev/iphone-use/actions/workflows/ci.yml/badge.svg)](https://github.com/MaxxiDev/iphone-use/actions/workflows/ci.yml)

[简体中文](README.zh-CN.md) · [Changes](CHANGELOG.md) · [Review and test notes](REVIEW-NOTES.md) · [Security](SECURITY.md)

This is an independent fork of [YueChen-C/iPhone-use](https://github.com/YueChen-C/iPhone-use), maintained by [MaxxiDev](https://github.com/MaxxiDev). The upstream author built the USB screen capture, Bluetooth input, desktop interface and MCP foundation. This fork adds API authentication, stricter request validation and regression tests. It is not an official upstream release or an Apple product.

## What it does

- Mirrors an unlocked iPhone over a USB data cable.
- Uses Bluetooth LE to send mouse and keyboard input through AssistiveTouch.
- Provides MCP tools for screenshots, taps, swipes, typing and basic navigation.
- Supports selecting a connected device by its full ID.
- Runs the phone bridge locally, without installing an app on the iPhone or requiring a paid Apple developer account.

The intended uses are supervised app testing, development and personal automation. The phone must remain unlocked and physically connected for screen capture.

## What this fork changes

| Area | Changes |
| --- | --- |
| API access | A random 256-bit bearer token is required for device information, screenshots and control routes. |
| Token storage | Owner-only `0600` file; reject symlinks, unexpected owners and malformed tokens. |
| Browser requests | Validate local Host and Origin; reject cross-site requests. The preview shell contains no device data or embedded token. |
| HTTP parsing | Reject invalid, negative, overflowing, duplicate and oversized lengths, malformed JSON and unsupported transfer encoding. Limit incomplete-request lifetime. |
| Input validation | Validate coordinates and image limits; bound gesture duration, relative movement and text length. |
| Clients | MCP reads the token automatically. Python helpers authenticate local requests and refuse redirects. |
| Identity | Locally packaged app is named `iPhoneUseReviewed.app`, distinct from the upstream download. “Reviewed” refers to this documented review, not a security certification. |

## Current status

This repository publishes source code. **No MaxxiDev binary release is published at this stage.**

Local validation recorded on 24 October 2026:

| Check | Result |
| --- | --- |
| Upstream baseline | 162 Swift tests passed before changes |
| Modified Swift suite | 170 tests passed |
| Python tests without network listeners | 46 tests passed |
| Python HTTP integration tests | 16 blocked by local execution permissions; not claimed as passes |
| MCP protocol | Initialization, notifications, 12 tool definitions, ping and clean JSON-RPC output passed |
| Release compilation | Apple Silicon build completed |
| Local app signature | Ad-hoc signature verified; not notarized |
| Real iPhone | Pairing, capture, pointer accuracy, reconnection and live MCP control not yet validated |

A successful build or passing unit tests do not establish complete security or hardware compatibility. See [REVIEW-NOTES.md](REVIEW-NOTES.md) for the exact scope and remaining checks. GitHub Actions results are separate from this local record. The [first full CI run](https://github.com/MaxxiDev/iphone-use/actions/runs/40089597349) passed **170 Swift tests, all 62 Python tests (including HTTP integration), a Release build and the MCP protocol check** at commit `55f7ea65c2cbd1544a38a403264c9653af2cfd47`. Live-device validation remains pending.

## Requirements

- A Mac running macOS 14 or later, with Bluetooth LE.
- Swift 6 or later, supplied by compatible Xcode or Command Line Tools.
- Python 3 for helper scripts and Python tests; `ffmpeg` only for optional recording.
- An unlocked iPhone and a USB cable that supports data.
- Camera and Bluetooth permissions on the Mac; USB trust and AssistiveTouch on the iPhone.

No third-party Swift package dependencies are declared in `Package.swift`.

## Build and connect

```sh
git clone https://github.com/MaxxiDev/iphone-use.git
cd iphone-use
swift test
swift build -c release
./scripts/build-app.sh
```

The packaging script creates `build/iPhoneUseReviewed.app`. It uses an available signing identity or falls back to an ad-hoc signature. It does not notarize the app. Review the source and macOS permission prompts before running it.

1. Move the app to Applications and open it.
2. Connect and unlock the iPhone, and complete **Trust This Computer** on the phone.
3. Grant camera access for the USB video feed and Bluetooth access for input if you choose to use the app.
4. On iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**.
5. Under **AssistiveTouch → Devices → Bluetooth Devices**, pair with **iPhone Use** or the Mac name shown by the app.
6. First verify the phone image and a harmless manual click on a non-sensitive screen.

Do not run the upstream app and this app at the same time: both use port `7390` by default.

## Connect an AI agent

With the app already running, register the local MCP server:

```sh
# Codex
codex mcp add iphone-use -- /Applications/iPhoneUseReviewed.app/Contents/MacOS/iphone-use mcp

# Claude Code (alternative client)
claude mcp add iphone-use -- /Applications/iPhoneUseReviewed.app/Contents/MacOS/iphone-use mcp
```

Restart the client or open a new session to load the tools. The MCP process forwards requests to the running app; it does not independently start capture or Bluetooth.

Start with a read-only task, such as listing devices and taking a screenshot. Confirm the selected device before sending input. Messages, purchases, deletion and other consequential actions need human oversight; this app does not understand what an on-screen button means.

The optional upstream Codex skill remains in `codex/skills/iphone-use/`, but is not required for basic MCP and is not installed automatically.

## Local API authentication

The service binds to `127.0.0.1:7390`. On first launch the app creates:

```text
~/Library/Application Support/iPhoneUse/api-token
```

The app and MCP client share that owner-only token file. Never commit it, post it in an issue or paste it into an AI conversation.

For a scripted status check from this checkout:

```sh
python3 scripts/local_api.py http://127.0.0.1:7390/status
```

The helper reads the token locally. Upstream unauthenticated `curl` examples return `401` in this fork.

`IPHONE_USE_PORT` selects a different port. Optional `IPHONE_USE_AUTH_FILE` must be an absolute path shared by the app and all clients. If you customize it, pass the same value to the MCP process. The browser viewer at `/viewer` asks for the token and retains it in memory only; it does not put credentials into URLs or persistent browser storage.

## Privacy and limitations

- **Local bridge does not mean local AI.** MCP returns phone screenshots to the chosen AI client; a cloud model provider may receive those images.
- The token reduces unauthorized API access, but is not protection against malicious software already running as your macOS user.
- Keep the API on loopback. Do not expose it through a tunnel, reverse proxy or public network.
- Screenshots may contain notifications, messages and other private information. Use a test phone or non-sensitive screen during setup.
- The phone must stay unlocked. Portrait is the primary workflow; rotation and all device/iOS combinations are not guaranteed.
- Direct keyboard input supports US-layout ASCII. Other text needs an appropriate iPhone input method or separately configured clipboard workflow.
- Bluetooth pairing, pointer calibration and reconnect behavior still need real-device testing.
- This is a targeted hardening pass, **not a complete security audit, penetration test or safety certification**.

## Development

```sh
swift test
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
swift build -c release
python3 -B scripts/check-mcp.py
```

HTTP integration tests need permission to bind loopback ports. Hardware testing is separate and is never implied by a green unit-test run. See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.

Older upstream guides remain under `docs/` for architecture and historical context. For this fork's authentication, app name and release status, this README and review notes take precedence over upstream examples.

## Credits and license

Original project and core implementation: [YueChen-C/iPhone-use](https://github.com/YueChen-C/iPhone-use), copyright © 2026 YueChen.

Fork maintenance, API hardening, validation and documentation: MaxxiDev. The initial adaptation used AI-assisted development; the concrete changes and validation limits are documented rather than presented as an independent security audit.

Distributed under the [MIT License](LICENSE). Original copyright and permission notices are retained. Please preserve upstream attribution when redistributing this fork.
