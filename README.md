# Delta

Delta is a native backup manager for macOS 26. It combines a focused SwiftUI interface with [restic](https://restic.net/) for encrypted, incremental, deduplicated backups to local disks, mounted volumes, SSH, object storage, REST servers, and rclone remotes.

[![CI](https://github.com/dbuskariol/delta/actions/workflows/ci.yml/badge.svg)](https://github.com/dbuskariol/delta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dbuskariol/delta)](https://github.com/dbuskariol/delta/releases/latest)
![macOS 26](https://img.shields.io/badge/macOS-26%2B-111111?logo=apple&logoColor=white)

Delta creates file-level backups. It is not a bootable clone, a block-level disk imager, Time Machine, or a hosted backup service.

## Install

Delta requires macOS 26 or later.

1. Download the notarized DMG from the [latest release](https://github.com/dbuskariol/delta/releases/latest).
2. Open the DMG and drag Delta to Applications.
3. Open Delta from Applications and add a destination.

The release also includes a signed ZIP used by Delta's Sparkle updater. Every public artifact is accompanied by `SHA256SUMS` and a machine-readable provenance manifest.

## What Delta does

| Area | Capability |
| --- | --- |
| Backup | Encrypted, compressed, incremental backups with content-defined deduplication and unchanged-run detection |
| Sources | Selected folders or one readable filesystem volume, with macOS-safe default exclusions |
| Destinations | Local paths, mounted SMB/NFS volumes, SFTP, S3-compatible storage, B2, Azure Blob, Google Cloud Storage, OpenStack Swift, REST, rclone, and advanced restic URLs |
| Scheduling | Hourly, daily, weekly, monthly, or interval schedules; missed-run catch-up; battery and Low Power Mode policies |
| Retention | Hourly/daily/weekly/monthly/yearly keep rules, pruning, and optional post-prune repository checks |
| Restore | Browse restore points and folders, preview restores, select individual items, choose overwrite behavior, and optionally verify written data |
| Operations | Live progress, durable run history, grouped backup issues, notifications, diagnostics, and menu-bar controls |
| Updates | Signed Sparkle feed, EdDSA-signed archives, verification before extraction, Developer ID, and Apple notarization |

Delta prepares new destinations, validates sources and credentials before starting, and serializes operations per destination. A backup that restic completes with unreadable files remains technically incomplete: Delta preserves the exit code and issue list, while letting you acknowledge an unchanged set of known omissions without hiding it from the audit trail.

## Destination secrets

Every destination is encrypted by restic. Delta-generated passwords and provider credentials are stored in the login Keychain. Scheduled reads prohibit interactive prompts and fail closed if the saved item is not available to the signed app.

For user-managed passphrases, losing the password means losing access to the encrypted repository. Delta cannot bypass restic encryption. Password rotation stages a new restic key, saves and verifies it, then retires the previous key; rollback keeps the repository usable if an intermediate step fails.

## Permissions and privacy

Delta does not collect analytics, advertising identifiers, backup contents, credentials, or usage data. Its privacy manifest declares no tracking and no collected data. Network activity is limited to the signed GitHub release feed and the backup destinations you configure.

| macOS access | When it is needed |
| --- | --- |
| Selected files and folders | Granted through native file pickers for custom backup sources, restore targets, local destinations, and SSH key selection |
| Full Disk Access | Optional for full-volume backups or protected folders that macOS otherwise prevents Delta from reading |
| Login Items | Required only when Scheduled Backups is enabled; macOS manages Delta's signed background agent |
| Notifications | Optional for job alerts and success summaries |
| Keychain | Required to save destination passwords and remote-provider credentials |

Delta does not require administrator privileges, Accessibility, Screen Recording, Camera, Microphone, Contacts, or Location access.

Read [SECURITY.md](SECURITY.md) for the trust model, secret handling, diagnostics policy, and vulnerability reporting.

## Menu bar and keyboard behavior

The optional menu-bar item reflects ready, running, paused, blocked, and attention states. It provides Back Up Now, Run Due Backups, Pause, Resume, Stop, Activity, Updates, and main-window access without requiring the app window to remain open.

Delta follows standard macOS keyboard navigation and menu behavior. Version 0.1.0 does not install global hotkeys or require Accessibility permission.

## Architecture

| Component | Responsibility |
| --- | --- |
| `Delta` | SwiftUI app, AppKit status item, workflows, settings, diagnostics, and Sparkle updates |
| `DeltaAgent` | Signed Login Item agent that evaluates due work and exits |
| `DeltaCore` | Models, policy, SQLite/GRDB persistence, scheduling, command construction, parsing, process control, and Keychain integration |
| `DeltaSecretBridge` | Restricted helper path for noninteractive destination-password reads |
| `restic` | Encrypted repository format, snapshots, deduplication, restore, retention, and checks |
| `rclone` | Optional transport for additional remote providers |

Operational state lives under `~/Library/Application Support/Delta`; secrets remain in Keychain, and backup data remains at the configured destination. See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for process boundaries and data flow.

## Build and test

Requirements:

- macOS 26 or later
- Xcode 26.5 or later
- Swift 6.2 or later
- Network access for the first package resolution and bundled-tool bootstrap

```sh
Scripts/bootstrap-tools.sh
swift test
Scripts/verify-ci.sh
```

`Scripts/verify-ci.sh` is the certificate-free CI gate. Release builds use the Xcode project and the fail-closed release entry point documented in [Documentation/RELEASING.md](Documentation/RELEASING.md). A stable Apple Development or Developer ID signature is important for local Keychain and privacy-permission continuity.

The suite covers policy, persistence, command construction and redaction, scheduling, restore safety, warning semantics, service registration contracts, real local restic lifecycle tests, packaged-app checks, and deterministic installed-app acceptance harnesses. GitHub runs the CI gate on Apple Silicon and Intel macOS 26 runners.

## Updating

Use **Settings → Updates** or **Updates** in the menu-bar panel. Delta requires a signed appcast, verifies the EdDSA signature before extraction, and accepts only Developer ID-signed/notarized application updates. The DMG remains available for manual replacement.

## Troubleshooting

- **A source is unavailable:** reselect it in the backup profile, then check its filesystem permissions and Full Disk Access if it contains protected data.
- **A scheduled backup did not run:** open Settings and confirm Scheduled Backups is enabled and approved in Login Items, then review battery, Low Power Mode, and destination status.
- **Password Access needs repair:** use Settings → Password Access to rewrite the Keychain access list for the currently signed Delta app.
- **A destination is missing or locked:** reconnect the disk/network location, verify credentials, and ensure another restic client is not operating on the same repository.
- **An update is unavailable:** use Check for Updates, confirm network access to GitHub Releases, or install the notarized DMG manually.
- **More evidence is needed:** export diagnostics from Settings. Delta redacts known secrets and credential-bearing URLs before writing the report.

## Documentation

- [Architecture](Documentation/ARCHITECTURE.md)
- [Security and privacy](SECURITY.md)
- [Release process](Documentation/RELEASING.md)
- [Release notes](Documentation/RELEASE_NOTES.md)
- [Backup-engine behavior](docs/RESTIC_COMPLIANCE.md)
- [Production acceptance](docs/PRODUCTION_READINESS.md)
- [Contributing](CONTRIBUTING.md)
