# Contributing

Contributions should keep the upstream hardware behavior and this fork's authentication boundary clear.

1. Open a focused issue or pull request describing the concrete behavior to change.
2. Preserve upstream MIT copyright and license notices.
3. Run `swift test`, the Python test suite, a Release build and the MCP protocol checker.
4. Add regression coverage for parser, authentication or input-validation changes.
5. For Bluetooth, capture, pointer or device-routing changes, report the actual Mac/iOS/device combination tested. Do not equate mocked tests with real-device validation.
6. Keep tokens, logs, screenshots, recordings, pairing data and private machine paths out of commits and reports.
7. Include limitations and any checks that could not be completed.

Do not use real accounts, payments, messages or personal information as automated test fixtures. Security-sensitive reports should follow [SECURITY.md](SECURITY.md).

## Before the first binary release

- [ ] Complete all HTTP/MCP integration tests on an unrestricted local runner.
- [ ] Verify first pairing and permission prompts on a real iPhone.
- [ ] Verify USB capture, a harmless tap, swipe and ASCII input.
- [ ] Verify device selection and disconnect/reconnect behavior.
- [ ] Verify unauthenticated API requests fail and authenticated MCP works.
- [ ] Check portrait pointer accuracy and document calibration needs.
- [ ] Verify the distributed archive, signature, source revision and known limitations.

No app-store, notarization or security-audit claim should be added without corresponding evidence.
