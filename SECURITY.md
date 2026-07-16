# Security and Privacy

## Supported version

Security fixes are provided for the latest public Delta release. Confirm the installed version in Settings and update through Sparkle or the latest notarized DMG.

## Reporting a vulnerability

Please use [GitHub's private vulnerability reporting](https://github.com/dbuskariol/delta/security/advisories/new). Do not include real backup passwords, cloud credentials, private SSH keys, repository contents, or unredacted diagnostic data in a public issue.

## Security model

- restic encrypts repository contents and metadata before they reach the configured destination.
- Delta stores destination passwords and provider credentials in the macOS login Keychain under service `com.delta.backup.destination-secrets`.
- Scheduled reads explicitly prohibit user interaction. Missing or inaccessible secrets stop the job.
- Passwords are supplied through a signed password command or short-lived standard input, not process arguments, ambient environment variables, logs, or temporary files.
- Remote-provider processes receive only the environment variables required by the configured backend.
- A local per-destination lock and restic's repository lock prevent unsafe overlapping operations.
- Diagnostics redact saved credential values, embedded URL credentials, known secret-bearing environment fields, and personal home-directory names.

Delta does not provide server-side account recovery. A lost user-managed restic password may make the repository permanently unreadable.

## Update trust

Release apps and nested code use Developer ID Application signatures from team `BJCVJ5G7MJ`, Hardened Runtime, secure timestamps, and Apple notarization. Sparkle requires a signed feed and an EdDSA-signed archive before extraction. Checksums and `release.json` bind the public artifacts to the tagged Git commit.

Only the Sparkle public key is stored in the repository. The private Sparkle key, Developer ID private key, notarization credentials, dSYMs, and Apple evidence are never public release assets.

## Privacy

Delta does not collect tracking data, analytics, advertising identifiers, backup contents, credentials, or usage telemetry. Its network surface is the GitHub-hosted signed update feed and destinations explicitly configured by the user. Operational state stays under the user's Application Support directory; backup data stays at its configured destination.

Optional macOS permissions are described in the README. Full Disk Access broadens the files Delta can read for backup, so enable it only when the selected backup scope requires protected data.
