# Delta

Delta is a native encrypted backup and restore manager for macOS 26. It supports Delta-format backups powered by [restic](https://restic.net/) and a native Time Machine format that presents Delta-managed remote storage to macOS without first staging a complete sparsebundle locally.

[![CI](https://github.com/dbuskariol/delta/actions/workflows/ci.yml/badge.svg)](https://github.com/dbuskariol/delta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dbuskariol/delta)](https://github.com/dbuskariol/delta/releases/latest)
![macOS 26](https://img.shields.io/badge/macOS-26%2B-111111?logo=apple&logoColor=white)

![Delta dashboard](Documentation/Screenshots/dashboard-0.3.0.jpg)

Delta-format profiles create file-level restic backups. Time Machine-format destinations instead let macOS own backup history and restore semantics. Delta is not a bootable clone or hosted backup service.

## Know what is protected

Each backup profile keeps its source, destination, schedule, retention rules, power policy, exclusions, speed limits, and most recent result together. Delta validates the source and saved credentials before starting, serializes work for each destination, and asks restic to encrypt, compress, incrementally store, and deduplicate the selected data.

![Delta backup profiles](Documentation/Screenshots/backups-0.3.0.jpg)

- Back up selected folders or one readable filesystem volume.
- Run manually or on hourly, daily, weekly, monthly, and interval schedules.
- Catch up one missed run after sleep, disconnection, or an unavailable destination.
- Control battery and Low Power Mode behavior without changing a schedule.
- Keep hourly, daily, weekly, monthly, and yearly restore points, then prune unreferenced data and optionally check the repository.
- See new, changed, unchanged, and added-byte counts without treating an unchanged run as a failure.
- Preserve restic exit codes, warnings, unreadable-file evidence, and issue history instead of overstating protection.

## Store encrypted backups where they belong

![Delta destinations](Documentation/Screenshots/destinations-0.3.0.jpg)

Each destination chooses one immutable format. Delta-format destinations use restic's interoperable encrypted repository. Time Machine-format destinations use an encrypted APFS sparsebundle whose band data is stored as authenticated immutable remote objects behind a strictly bounded local cache. Provider credentials remain in the login Keychain in either mode.

| Destination | Delta behavior |
| --- | --- |
| Local folder or removable disk | Uses a native folder selection and a directly accessible filesystem path |
| Mounted SMB or NFS volume | Uses the volume after macOS or Finder has mounted it; macOS owns the network mount |
| SFTP | Connects with host, path, username, port, and optional SSH identity settings |
| S3-compatible object storage | Supports endpoint, bucket, path, region, access key, and secret key settings |
| Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift | Exposes the credentials and repository fields required by restic |
| REST server | Connects to a restic REST repository URL with optional credentials |
| rclone remote | Uses the bundled rclone transport for an already configured remote |
| Advanced restic URL | Accepts a user-managed backend URL for interoperable configurations |

Provider availability, credentials, server policy, latency, and storage charges remain outside Delta's control. A mounted NAS must be connected before its profile can run; a cloud destination still needs a valid provider account and network path. For an existing Time Machine disk, Delta never recreates a missing local or mounted folder or treats a detached provider as empty backup history: it reports `Storage Unavailable` and waits for the same destination to return.

Time Machine mode supports local or mounted filesystem paths, SFTP, S3-compatible, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, and configured rclone object destinations. It does not use restic's REST protocol or arbitrary restic URLs. macOS owns the schedule, backup history, browsing, and restore experience; Delta owns connection, remote durability, cache limits, recovery records, and provider access.

## Restore without guessing

![Delta restore browser](Documentation/Screenshots/restore-0.3.0.jpg)

Restore starts with a repository and a concrete point in time. Expand its backed-up sources, select any combination of files and folders, and preview the operation before Delta writes data.

- Restore everything, one folder, or individual files.
- Choose a separate destination or explicitly acknowledge an in-place restore.
- Preview by default, then choose skip, replace-changed, or overwrite behavior.
- Verify restored content after a real write.
- Create an optional pre-restore backup before an in-place operation.
- Refresh restore points and repository contents without losing the selected destination context.

Delta reports success only after the underlying restore exits successfully. For high-value recovery, independently open or hash representative restored files before relying on the result.

For Time Machine-format destinations, connect the disk in Delta and use macOS's native Time Machine browser. Delta does not re-label a transport write or a mounted disk as a completed backup; macOS remains authoritative for Time Machine backup and restore outcomes.

## Inspect every operation

![Delta activity history](Documentation/Screenshots/activity-0.3.0.jpg)

Activity keeps backup, restore, destination preparation, check, and cleanup results in one place. Live process output is bounded so a noisy backend cannot exhaust app memory; parsed summaries remain available while secrets, password commands, and credential-bearing repository URLs are redacted.

A completed backup with unreadable or omitted files remains technically incomplete. Delta preserves the evidence, groups actionable issues, and allows a reviewed omission to be acknowledged without erasing it from history. Cleanup requires confirmation, applies the profile's retention rules to the selected destination, and runs the configured post-cleanup check before presenting the final result.

## Native Mac controls

![Delta permission settings](Documentation/Screenshots/settings-permissions-0.3.0.jpg)

Delta uses native SwiftUI navigation, toolbars, menus, alerts, file pickers, settings, keyboard focus, and accessibility descriptions. The optional menu-bar control keeps Back Up Now, Run Due Backups, Pause, Resume, Stop, Activity, Updates, and main-window access available while the window is closed.

Use **Command-,** to open Settings and **Command-1** through **Command-5** to move between Dashboard, Backups, Destinations, Restore, and Activity. The same destinations, profiles, jobs, and controls are used by the window, menus, and signed background agent.

Settings covers scheduling, power behavior, notifications, login, permissions, health thresholds, new-profile defaults, restore safety, retention, signed updates, diagnostics, and saved history. The Permissions page explains the current access state without pretending that an approval exists when macOS has not granted it.

## Encryption and credentials

Restic encrypts Delta-format repository metadata and file content before storage. Time Machine-format destinations use Apple's AES-256 encrypted sparsebundle plus Delta's authenticated remote-generation layer. Delta can generate a high-entropy password or save a user-supplied passphrase. Destination passwords and provider secrets remain in the login Keychain; background reads prohibit interactive prompts and fail closed when the signed component cannot access the saved item.

Losing a user-managed repository password means losing access to that repository. Delta cannot bypass restic encryption. Password rotation stages and verifies a new restic key before retiring the previous key, with rollback designed to leave the repository usable if an intermediate step fails.

An app-managed Time Machine destination has a store-scoped recovery key that can be explicitly revealed and copied. Save it securely before relying on recovery from another Mac. Reconnecting reads a fixed remote recovery record, unwraps the independent manifest key with the disk password, and authenticates the latest signed generation before saving any local configuration.

Time Machine's local working cache is reconstructible, bounded, and always configured smaller than the logical encrypted disk. Its size controls buffering performance and the cache portion of local footprint, not backup or source-file size. Delta may evict clean bands immediately; when the working window fills, it spills dirty bands only after their immutable remote objects are uploaded and read-back verified, then continues through the same bounded window. A durability barrier succeeds only after every changed band and the signed generation are verified at the selected destination. Repeated DiskImages reads use a fixed two-band, 16 MiB authenticated memory window, and provider verification may temporarily use one additional fixed 64 MiB transfer batch; neither overhead grows with the backup. A full sparsebundle is never staged locally, whether the backup contains megabytes or terabytes. The provider can still observe encrypted-object sizes, counts, names, and timing plus non-secret recovery metadata such as the configured volume name and capacity.

## Permissions and privacy

Delta does not collect analytics, advertising identifiers, backup contents, credentials, or usage data. The bundled privacy manifest declares no tracking and no collected data. Network activity is limited to the signed GitHub release feed and the backup destinations you configure.

| macOS access | When it is needed |
| --- | --- |
| Selected files and folders | Custom sources, restore targets, local destinations, and SSH key selection |
| Full Disk Access | Required to add or remove a Time Machine-format disk; also required when a Delta-format backup includes a full volume or protected folders macOS otherwise prevents Delta from reading |
| Login Items | Required only when Scheduled Backups is enabled so macOS can run Delta's signed agent |
| Notifications | Optional for job alerts and success summaries |
| Keychain | Required to save repository passwords and remote-provider credentials |
| File System Extensions | Required only for Time Machine-format destinations so macOS can mount Delta's user-space remote storage volume |
| Background Items | Required only for Time Machine-format destinations so the mounted disk and on-demand setup helper survive the main app closing |

Delta-format backups do not require administrator privileges. Time Machine setup uses a narrowly scoped, signed privileged helper and macOS may request administrator approval when it is registered or updated. Delta does not require Accessibility, Screen Recording, Camera, Microphone, Contacts, or Location access. Read [SECURITY.md](SECURITY.md) for the trust model, secret handling, diagnostics policy, and vulnerability reporting.

## Architecture

| Component | Responsibility |
| --- | --- |
| `Delta` | SwiftUI app, AppKit status item, workflows, settings, diagnostics, and Sparkle updates |
| `DeltaAgent` | Signed Login Item agent that evaluates due work and exits |
| `DeltaCore` | Models, policy, SQLite/GRDB persistence, scheduling, command construction, parsing, process control, and Keychain integration |
| `DeltaSecretBridge` | Restricted helper path for noninteractive destination-password reads |
| `DeltaTimeMachineService` | User storage service for authenticated remote generations, bounded cache, locks, and reconnect |
| `DeltaTimeMachineFS` | User-approved sandboxed FSKit extension presenting sparse remote-backed files to DiskImages through an authenticated same-user socket in Delta's macOS App Group; no provider credentials or network entitlement |
| `DeltaTimeMachineHelper` | On-demand privileged helper that validates the already attached Delta disk and changes only its exact macOS Time Machine destination configuration |
| `restic` | Encrypted repository format, snapshots, deduplication, restore, retention, and checks |
| `rclone` | Optional transport for additional remote storage providers |

Operational configuration, audit history, and local control state live under `~/Library/Application Support/Delta`. Secrets remain in Keychain, and backup data remains at the configured destination. See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for process boundaries, repository locking, persistence, scheduling, and data flow.

## Install

Delta requires macOS 26 or later.

1. Download the notarized DMG from the [latest release](https://github.com/dbuskariol/delta/releases/latest).
2. Open the DMG and drag Delta to Applications.
3. Open Delta from Applications and add a destination. Choose Delta encrypted backup for a restic profile, or Time Machine for a macOS-managed backup disk.
4. For Time Machine, keep the app at `/Applications/Delta.app`, approve File System Extensions and Background Items when macOS asks, connect the disk in Delta, then configure and inspect backups in macOS Time Machine. Delta refuses to register production system components from a renamed, temporary, or build-output copy.
5. Run a first backup, inspect its authoritative history, and perform a test restore before considering the setup complete.

Public releases also include a signed ZIP for Sparkle updates, `SHA256SUMS`, external release notes, and a machine-readable provenance manifest.

## Build and verify

Requirements:

- macOS 26 or later
- Xcode 26.5 or later
- Swift 6.2 or later
- Network access for initial package resolution and bundled-tool bootstrap

```sh
Scripts/bootstrap-tools.sh
swift test
Scripts/verify-ci.sh
```

`Scripts/verify-ci.sh` is the certificate-free CI gate. It checks Swift tests, Debug and Release builds, strict metadata and privacy configuration, scripts, bundled tools, product language, packaged-app behavior, deterministic restic lifecycles, and fail-closed release assumptions. Its ad-hoc FSKit extension is intentionally inert and verified to contain neither the restricted module entitlement nor a provisioning profile; shipping validation separately requires both. GitHub executes the same gate on native Apple-silicon and Intel macOS 26 runners.

Identity-sensitive acceptance uses a stable Apple Development or Developer ID-signed app installed in `/Applications`. Replacing it with an ad-hoc or differently signed build can invalidate Keychain access and macOS privacy approvals. Use the guarded installer only with an intended stable identity:

```sh
Scripts/build-release.sh
Scripts/install-app.sh dist/Delta.app
```

The installer verifies the bundle identifier, minimum macOS version, signing team, designated requirement, and post-install bundle before replacing the installed app. Release distribution remains a separate, stricter process.

## Release trust

Delta's release pipeline is fail closed. It builds a universal hardened-runtime archive, verifies nested code, requires Developer ID signing, notarizes and staples the app and DMG, signs the Sparkle ZIP with EdDSA, validates the appcast and external release notes, checks Gatekeeper, records checksums and provenance, and preserves private dSYM and Apple evidence before publication.

No locally signed build should be described as a public release candidate until the manual acceptance matrix, genuine required external-backend evidence, notarization, stapling, Gatekeeper, Sparkle, and production-readiness gates pass for that exact bundle and CDHash. See [Documentation/RELEASING.md](Documentation/RELEASING.md).

## Recovery expectations and limitations

- Delta-format backups protect files through restic restore points; Time Machine-format destinations use macOS's native history and recovery. Neither makes a bootable clone.
- A backup is only one copy. Keep at least one independent, preferably off-site destination and periodically test recovery from it.
- Delta cannot recover a lost repository password, repair a provider outage, or read data that macOS denied to the backup process.
- Disconnected drives, unmounted shares, expired cloud credentials, repository locks, insufficient free space, and offline servers block work and remain visible as failures or attention states.
- Cleanup can permanently remove old restore points and unreferenced repository data. Review retention rules, the selected profile, and the selected destination before confirming it.
- Disconnecting a Time Machine destination behaves like unplugging a physical backup disk: Delta detaches the APFS disk but preserves its macOS Time Machine registration and exact destination identity for the next reconnect. Explicit removal first requires the verified disk to be connected, removes only that exact identity from macOS, then deletes its reconstructible local cache and configuration—not remote backup data. Delta verifies and retains an app-managed recovery key under the remote disk identity before deleting local state; user-managed users must retain the original password. Provider credentials must be entered again when reconnecting.
- Backend support describes configurations Delta and restic can address; genuine provider acceptance still depends on the exact server, account, permissions, network, and release evidence.

## Updating and troubleshooting

Use **Settings → Updates** or **Updates** in the menu-bar panel. Delta checks a signed appcast, verifies the EdDSA archive signature before extraction, and accepts only appropriately signed and notarized application updates. The notarized DMG remains the manual recovery path.

- **A source is unavailable:** reselect it, confirm the drive is mounted, then review filesystem permissions and Full Disk Access if protected data is involved.
- **A scheduled backup did not run:** update to Delta 0.3.2 or later, confirm Scheduled Backups is enabled and approved in Login Items, then review pause, power, missed-run, source, destination, and saved-password status. Delta 0.3.2 repairs the stale missing-service registration that an earlier version could leave after an update; it does not require deleting profiles or backup data.
- **Saved Passwords needs repair:** use Settings → Permissions to review access and rewrite the Keychain access list for the currently signed Delta app.
- **A destination is unavailable or locked:** reconnect it, verify credentials, and ensure another restic client is not operating on the same repository.
- **A Time Machine disk will not connect:** confirm the app is named `Delta.app` directly in `/Applications`, then open Settings → Permissions, review File System Extensions and Time Machine System Support, approve any pending macOS Background Items request, and retry. Delta cannot grant these approvals itself.
- **A connected Time Machine disk reports a remote-storage error:** restore provider connectivity first, then use the destination's offered recovery action. Disconnect the disk before editing, checking, or removing its remote configuration; Delta deliberately keeps an uncertain or failed mount visible instead of claiming it was ejected.
- **An update is unavailable:** use Check Now, confirm network access to GitHub Releases, or install the notarized DMG manually.
- **Support needs evidence:** copy or export the sanitized diagnostic report from Settings. Known secrets, credential-bearing URLs, and personal home-directory names are redacted.

## Documentation

- [Architecture](Documentation/ARCHITECTURE.md)
- [Security and privacy](SECURITY.md)
- [Release process](Documentation/RELEASING.md)
- [Release notes](Documentation/RELEASE_NOTES.md)
- [Current verification report](Documentation/VERIFICATION_REPORT.md)
- [Backup-engine behavior](docs/RESTIC_COMPLIANCE.md)
- [Production acceptance](docs/PRODUCTION_READINESS.md)
- [Contributing](CONTRIBUTING.md)

## Status

Delta is in active development at version 0.4.0. The Time Machine architecture and recovery workflow are implemented on the feature branch but are not yet production-accepted or shipped. Deterministic and localhost evidence remains regression evidence, not a substitute for a complete installed Time Machine backup/restore, genuine external-provider acceptance, Intel runtime coverage, or the exact notarized release candidate. Public production readiness still depends on those runtime results plus all signing, Apple-service, notarization, stapling, Gatekeeper, Sparkle, and release-history gates.
