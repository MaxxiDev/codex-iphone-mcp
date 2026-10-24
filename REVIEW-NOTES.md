# iPhone Use — local reviewed build

Based on YueChen-C/iPhone-use v1.0.0, release commit fcff38908343a9afe1197a2133233b123db41e9f.
Upstream: https://github.com/YueChen-C/iPhone-use
This is a modified, locally built Apple Silicon application, not an upstream release.

## Changes

- Require a random 256-bit bearer token for all device/status/screenshot/control API routes.
- Store that token as an owner-only 0600 regular file; reject symlinks and loose permissions.
- MCP automatically reads the token; helper scripts authenticate requests too.
- Keep the API bound to 127.0.0.1 and reject unexpected Host, Origin and cross-site requests.
- Reject negative, overflowing, duplicate or oversized HTTP lengths, unsupported transfer encoding,
  malformed JSON, oversized headers and incomplete requests that take over 15 seconds to arrive.
- Reject invalid coordinates/image limits; limit gesture duration and relative movement.
- Browser viewer requests a token, keeps it only in memory and never embeds it in a URL.
- Disable proxy use in the MCP HTTP bridge and refuse redirects in Python API helpers.
- Give the built app a distinct name and bundle identifier to distinguish it from the downloaded release.

## Validation

- Original upstream baseline: 162 Swift tests passed.
- Modified build: 170 Swift tests passed.
- 46 non-network Python tests passed.
- 16 Python HTTP integration tests could not run: this session forbids binding localhost ports
  (PermissionError: Operation not permitted). These are not claimed as passes.
- MCP initialize, notifications, 12 tool definitions, ping and clean JSON-RPC output passed.
- Release build and local ad-hoc signature verification passed.
- No app launch, camera/Bluetooth permission grant, phone pairing, live control, or on-device test
  has been performed by this review workflow.

## Start on your Mac

1. Copy iPhoneUseReviewed.app to Applications and open it yourself.
2. Allow camera access for USB capture and Bluetooth access for keyboard/mouse control if you choose.
3. Keep iPhone unlocked and USB-connected; Trust This Computer must be completed on the phone.
4. On iPhone enable Settings > Accessibility > Touch > AssistiveTouch.
5. Under AssistiveTouch > Devices > Bluetooth Devices, pair with iPhone Use / the Mac name.
6. Confirm that the Mac window displays the phone and that a harmless click works.

This build is ad-hoc signed, not notarized by Apple. Signature verification is an integrity check,
not an Apple security endorsement. Do not run both builds at once (they use the same default port).

After successful manual testing, register the reviewed binary with Codex in your Terminal:

```sh
codex mcp add iphone-use -- /Applications/iPhoneUseReviewed.app/Contents/MacOS/iphone-use mcp
```

Then open a new Codex chat or restart Codex to discover its tools. This workflow did not change
Codex config or install/register any skill. The optional upstream skill is not needed for basic MCP.

## Local API authentication

Default token file: ~/Library/Application Support/iPhoneUse/api-token
The app creates it on first launch; MCP reads it automatically as the same macOS user.
Do not paste the token into chat or publish it. For scripted status checks, from the source folder:

```sh
python3 scripts/local_api.py http://127.0.0.1:7390/status
```

Optional IPHONE_USE_AUTH_FILE must be an absolute path shared by the app and its clients.
If used, pass the same variable to all clients. Authentication errors fail closed.
The browser viewer at http://127.0.0.1:7390/viewer has no embedded credential; enter the token
locally only if you want that preview. Closing the tab discards its in-memory copy.
Upstream curl examples omit authentication and will return 401 in this build; use local_api.py.

## Review limits

This is a targeted static review and hardening pass, not a complete security audit.
No obvious third-party upload endpoint was found in the inspected core runtime, but that is not
proof of the absence of every vulnerability. Possession of this token permits phone control.
Software running as your own macOS user may read that token; this does not sandbox other local apps.
Using cloud AI clients can transmit phone screenshots to those clients/model providers.
Phone must stay unlocked; pointer accuracy, Bluetooth reliability, portrait orientation and ASCII
input limitations remain upstream constraints. Use non-sensitive screens for the first live test.

## Rebuild

On an ordinary Terminal: swift test; swift build -c release.
The initial locally packaged application was built using Swift 6.3.3 for arm64 macOS, with the
cache paths moved to /tmp because of session filesystem restrictions. No third-party Swift
package dependencies are declared in Package.swift.

Original MIT copyright is retained; the fork also records MaxxiDev copyright for its modifications. No public binary release is provided at this stage.
