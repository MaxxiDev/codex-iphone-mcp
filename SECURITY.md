# Security and privacy

This experimental fork has received a targeted review and hardening pass. It has not received an independent security audit or penetration test, and no guarantee of complete safety is made.

## Trust boundary

The Mac app can capture the connected phone's screen and send input through Bluetooth. An authenticated API client can use those capabilities. The app cannot determine whether an on-screen action is safe, authorized or reversible.

- API access is loopback-only and requires a private bearer token, except for the empty viewer shell.
- The default token file is `~/Library/Application Support/iPhoneUse/api-token` with mode `0600`.
- Never commit tokens, pairing files, calibration identities, screenshots, recordings or device logs.
- The token is not a sandbox against software already running as the same macOS user.
- Do not expose the API over a tunnel, public interface or reverse proxy.
- A cloud AI client may transmit phone screenshots and task content to its model provider. Review that client's policies separately.
- Keep human oversight for messages, transactions, deletion and permission changes.

## Reporting a concern

Do not publish credentials, phone screenshots or a working exploit in a public issue. If the repository's **Security → Report a vulnerability** option is available, use it for a private report. Otherwise open a minimal issue requesting a private reporting channel without technical exploit details or personal data.

Private reporting availability and response times are not guaranteed. This is a volunteer-maintained experimental project with no support SLA.

For a token suspected of exposure, quit the app and its clients, remove or replace the local token file, then restart the app so it can create a new one. Review what the exposed client could access. Do not post the old token in an issue.

## Validation scope

See [REVIEW-NOTES.md](REVIEW-NOTES.md). Unit tests, compilation and code-signature checks are different from real-device testing, notarization and independent security review.
