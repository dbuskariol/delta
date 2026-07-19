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
- Diagnostics redact saved credential values, embedded URL credentials, signed-URL query secrets, original and rclone-derived secret-bearing environment fields, and personal home-directory names.
- Time Machine-format destinations keep the sparsebundle encrypted by Apple's DiskImages stack. Delta stores its random manifest-authentication key remotely only as an AES-256-GCM wrapped value under PBKDF2-HMAC-SHA256 (600,000 iterations) with a unique salt; recovery-critical metadata is authenticated as additional data.
- The remote provider receives encrypted sparsebundle band objects and authenticated Delta control records. It can still observe object names, sizes, counts, access timing, and the non-secret recovery metadata needed to identify and reopen the store, including its configured volume name and capacity. Delta does not claim to hide this traffic metadata.
- The Time Machine FSKit extension has no provider credentials. Its owner-only Unix socket resides in Delta's public Team-ID-prefixed macOS App Group, requires the same user, and validates the kernel-supplied immutable audit token against the exact signed Delta app or FSKit extension; it does not trust a caller-reported PID. The sandboxed extension has no network client, network server, private, or temporary-exception entitlement. The complete repository UUID remains authenticated inside every request even though the filesystem socket name is compact.
- FSKit discovery, DiskImages, and APFS role assignment run in the signed-in user session. The privileged setup helper accepts only Delta's exact signed Team ID and identifiers, serializes global mutations, validates the exact private source, user-owned mount, and attached APFS disk, and only adds or removes that verified macOS Time Machine destination. It does not mount FSKit, create or attach an image, receive the encrypted disk password, or transport backup data.
- The encrypted Time Machine disk password is supplied to `hdiutil` only as mutable, short-lived standard input in the user session. It never crosses privileged XPC, and Delta clears its mutable copies after use. The sparsebundle's source directory is opened without following links, verified on the expected device and owner, forced to owner-only mode, synchronized, and revalidated before every attach.
- Time Machine write ownership is fenced by a local destination lock, a durable per-store writer identity, and a short remote lease. Delta also persists the last accepted generation and authenticated manifest digest as a local rollback witness; startup and maintenance reject an older head, a same-generation mismatch, a missing witness, or a gap in the retained parent chain before cache or cleanup mutation. Maintenance remains bound to the exact preflight head, and runtime history pruning waits until the new witness is durably recorded. Lease loss, transport failure, inconsistent listings, unauthenticated history, manifest forks, or failed read-back verification prevent a new generation from becoming authoritative. Cache and transport limits fail closed instead of evicting dirty data or accepting oversized remote input.

Delta does not provide server-side account recovery. A lost user-managed restic password may make that repository permanently unreadable. A user-managed Time Machine disk likewise requires its original password. For app-managed Time Machine disks, Delta offers an explicit recovery-key view and fail-closed verifies the store-scoped Keychain key before local configuration is removed; users must export it securely to recover on another Mac.

## Update trust

Release apps and nested code use Developer ID Application signatures from team `BJCVJ5G7MJ`, Hardened Runtime, secure timestamps, and Apple notarization. Sparkle requires a signed feed and an EdDSA-signed archive before extraction. Checksums and `release.json` bind the public artifacts to the tagged Git commit.

Only the Sparkle public key is stored in the repository. The private Sparkle key, Developer ID private key, notarization credentials, dSYMs, and Apple evidence are never public release assets.

## Privacy

Delta does not collect tracking data, analytics, advertising identifiers, backup contents, credentials, or usage telemetry. Its network surface is the GitHub-hosted signed update feed and destinations explicitly configured by the user. Operational state stays under the user's Application Support directory; backup data stays at its configured destination.

macOS permissions are described in the README. Full Disk Access broadens the files Delta can read for Delta-format backups and is also required by macOS when Delta's signed helper adds or removes a verified Time Machine-format disk. Enable it only when protected backup sources or Time Machine-format destinations need those supported operations.
