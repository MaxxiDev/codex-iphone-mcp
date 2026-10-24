# Changelog

## Unreleased — MaxxiDev experimental fork

### Added

- Random 256-bit API bearer token with owner-only file storage.
- Host, Origin and cross-site request validation.
- Authenticated MCP and Python API clients.
- HTTP parser and authentication regression tests.
- English and Chinese fork introductions, security notes and a hardware validation checklist.

### Changed

- Reject malformed HTTP lengths, duplicate headers, unsupported transfer encoding and non-object JSON.
- Bound header/body sizes and incomplete request lifetime.
- Validate screen coordinates and image dimensions; bound gesture duration, relative movement and text input.
- Use a separate reviewed-build application identity.
- Publish source first; defer binary releases until real-device validation.

### Validation

170 Swift and 46 non-network Python tests passed locally. Sixteen HTTP integration tests were blocked by local port-binding permissions. MCP protocol checks and an Apple Silicon Release build passed. Real-device acceptance remains open.

### Upstream

Based on YueChen-C/iPhone-use v1.0.0 (`fcff38908343a9afe1197a2133233b123db41e9f`). This fork retains upstream authorship, history and the MIT license.
