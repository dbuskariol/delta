# Delta

Delta is a native SwiftUI macOS backup app built around restic. It is designed for encrypted, incremental, scheduled file-level backups to local drives, mounted network drives, and restic-supported remote destinations.

The product goal is simple: make serious backup practices approachable without hiding the engineering that keeps data safe.

## What Delta Does

- **Encrypted backups by default** using restic repositories. There is no unencrypted backup mode.
- **Incremental restore points** with content-addressed deduplication, metadata tracking, and `--skip-if-unchanged`.
- **Full-volume or custom-folder protection** with macOS-safe excludes and destination self-exclusion.
- **Local and network destinations** including local paths, mounted SMB/NFS volumes, SFTP, REST server, S3-compatible storage, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, rclone remotes, and custom restic URLs.
- **Destination validation before save** for required fields, new or changed writable local paths, REST URLs, SFTP paths/ports, and rclone remote syntax.
- **Automatic destination preparation** after a destination is added, with a first-backup safety net for writable local or mounted destinations that still have no restic metadata.
- **Scheduled backups** through a bundled `DeltaAgent` LaunchAgent registered with `SMAppService`.
- **Power-aware scheduling** with battery and Low Power Mode controls.
- **Retention maintenance** with scheduled forget/prune/check windows.
- **Pause, resume, and cancel controls** for active backups. Pause stops restic safely, keeps the profile visibly paused, and Resume continues from already saved backup data.
- **Full or browsed selected restore** with backup browsing, file/folder selection, dry-run preview, overwrite policies, verification, original-path restore, chosen-folder restore, and optional pre-restore backup.
- **Streaming and saved backup logs** from restic stdout/stderr with source context, stable processed-file counters, fixed-height live panes, and expandable per-job audit history.
- **Sparkle automatic updates** with generated appcast/update archive support.

## How It Works

Delta does not invent a custom backup format. It delegates repository format, encryption, snapshots, deduplication, restore, pruning, and integrity checks to [restic](https://restic.net/).

At a high level:

1. A user creates a **Destination**, which is where encrypted restore points are stored.
2. Delta creates or uses a restic repository at that destination.
3. A user creates a **Backup Profile**, choosing sources, schedule, retention, bandwidth, and power policy.
4. Scheduled or manual runs invoke bundled `restic` through `ResticRunner`.
5. Repository passwords are fetched from Keychain through `DeltaSecretBridge` using restic `--password-command`.
6. Job state, restore points, events, settings, restore requests, and profile definitions are persisted in SQLite via GRDB.
7. Restore always goes through a wizard: destination, restore point, scope, restore location, conflict policy, dry run, then execution.

## Terminology

Delta intentionally uses user-facing language instead of restic internals:

| Delta term | restic term | Meaning |
| --- | --- | --- |
| Destination | Repository | The encrypted storage location for backup data. |
| Restore point | Snapshot | A point-in-time backup that can be restored. |
| Cleanup | Forget/prune | Applies retention rules and removes unneeded data. |
| Check | Check | Validates repository integrity. |

## Architecture

The app is split into signed targets:

- `Delta`: SwiftUI macOS app, menu bar item, settings, backup/restore UI, Sparkle update controller.
- `DeltaAgent`: LaunchAgent helper for scheduled runs.
- `DeltaSecretBridge`: CLI password bridge used by restic `--password-command`.
- `DeltaCore`: shared models, database, command builder, scheduling, restic runner, parser, Keychain, bookmarks, locks, job logs, and policy code.

Important implementation details:

- **SQLite persistence** lives under Application Support through `AppDirectories.databaseURL()`.
- **Keychain secrets** use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and a trusted-application access list for the signed Delta app, agent, and secret bridge. Background secret reads fail closed instead of showing system prompts.
- **Security-scoped bookmarks** preserve access to selected source folders where macOS requires it.
- **Per-destination locks** prevent overlapping backup, restore, prune, and check jobs across app/agent processes.
- **Per-job output logs** persist formatted restic progress, warnings, errors, start lines, and finish lines for troubleshooting after relaunch or scheduled agent runs.
- **Bundled tools** are pinned and checksum-verified through `Scripts/bootstrap-tools.sh`.
- **Packaged app verification** checks signatures, Sparkle embedding, LaunchAgent plist integrity, helper smoke tests, Sparkle update metadata, and bundled restic/rclone versions.

## Backup Behavior

Delta creates file-level backups. Full-volume mode is not a bootable clone or bare-metal restore mechanism.

For full-volume profiles, Delta uses:

- restic `backup`
- `--one-file-system`
- macOS-safe excludes
- explicit local destination exclusion
- `--compression auto`
- `--skip-if-unchanged`
- profile/restic tags

Custom-folder profiles use the selected source folders and stored security-scoped bookmarks where available.

## Scheduling And Maintenance

`DeltaAgent` is packaged as a LaunchAgent and runs periodically. Each run evaluates:

- backup schedule: hourly, daily, weekly, monthly, or custom interval
- missed-run catchup policy
- destination availability
- battery policy
- Low Power Mode policy
- bandwidth limits
- per-destination lock state
- scheduled retention maintenance

Retention maintenance can run `forget`, `prune`, and optional `check` based on the profile maintenance schedule. Post-prune checks are returned to the agent so failed validation is visible in job status and process exit status.

## Restore Workflow

Restore is intentionally explicit:

1. Choose a Destination.
2. Refresh and choose a Restore Point.
3. Restore the full restore point, or browse backed-up source folders and select specific files/folders.
4. Choose a target folder or original paths.
5. Choose conflict behavior:
   - Replace all
   - Replace changed
   - Replace older
   - Keep existing
6. Run a dry-run preview by default.
7. Optionally verify restored files.
8. Confirm in-place restore when restoring to original paths. Delta enforces this confirmation before any non-preview original-path restore can run.

The browser loads source roots from the selected restore point immediately and asks restic for one folder's contents at a time with `ls --json`, so full-volume backups do not need to be expanded into memory before selection. Selected-path restore uses restic snapshot path syntax for one selected path, and include filters for multiple selected paths.

## Security Model

- Backup data is encrypted by restic before it leaves the Mac.
- Repository passwords are generated by Delta or supplied by the user.
- Passwords and backend credentials are stored in Keychain.
- New user-managed encryption passphrases must be entered twice before the destination can be saved.
- Restic receives the repository password through a short-lived password command, not a long-lived plaintext environment variable.
- Command redaction hides password-command values from logs/descriptions.
- Backend credentials are injected only into a curated child-process environment for the restic run; Delta does not forward arbitrary ambient environment secrets.
- Empty-password restic repositories are not used.

Losing the repository password means losing access to the encrypted backup data. That is a restic security property, not a recoverable app state.

## Automatic Updates

Delta uses [Sparkle](https://sparkle-project.org/) for automatic updates.

Relevant files:

- `Sources/Delta/SoftwareUpdateController.swift`
- `Packaging/Delta.app.plist`
- `Scripts/package-update.sh`
- `Scripts/generate-appcast.sh`

The appcast URL points at GitHub release assets:

```text
https://github.com/dbuskariol/delta/releases/latest/download/appcast.xml
```

## Development

Requirements:

- macOS with Swift 6.2 toolchain/Xcode 26-compatible environment
- Network access for initial restic/rclone/Sparkle dependency bootstrap

Bootstrap tools:

```sh
Scripts/bootstrap-tools.sh
Scripts/verify-tools.sh
```

Run tests:

```sh
swift test
```

Run the local restic integration test:

```sh
DELTA_RESTIC_INTEGRATION=1 \
RESTIC_BINARY=Resources/Tools/bin/restic \
swift test --filter ResticIntegrationTests
```

Build the app:

```sh
Scripts/build-app.sh
```

Install the verified app bundle locally:

```sh
Scripts/install-app.sh
```

Full release verification:

```sh
Scripts/verify-release.sh
```

Package Sparkle update assets:

```sh
Scripts/package-update.sh
Scripts/generate-appcast.sh
```

## Release And Signing

Local development builds prefer `DELTA_CODESIGN_IDENTITY` when set. If it is unset, the build script automatically uses the first available `Developer ID Application` or `Apple Development` signing identity before falling back to ad-hoc signing. Stable signing matters for macOS privacy permissions such as Full Disk Access; changing the signing identity changes the app identity macOS trusts.

Developer ID distribution should use:

```sh
DELTA_CODESIGN_IDENTITY="Developer ID Application: Example" Scripts/verify-release.sh
```

Notarization is intentionally deferred until final release preparation. The build pipeline is structured for Developer ID signing and notarization, but Apple notarization credentials/submission should be handled at release time.

## Current Scope

Delta is a file-level backup app. It does not currently provide:

- bootable clone creation
- bare-metal system imaging
- block-level disk imaging
- Time Machine compatibility

Those are separate product categories with different restore expectations and failure modes.

## Further Reading

- [restic backup docs](https://restic.readthedocs.io/en/stable/040_backup.html)
- [restic restore docs](https://restic.readthedocs.io/en/stable/050_restore.html)
- [restic retention/prune docs](https://restic.readthedocs.io/en/stable/060_forget.html)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Sparkle](https://sparkle-project.org/)
