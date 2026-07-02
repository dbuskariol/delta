# Delta

Delta is a native SwiftUI macOS backup app built around restic. It is designed for encrypted, incremental, scheduled file-level backups to local drives, mounted network drives, and restic-supported remote destinations.

The product goal is simple: make serious backup practices approachable without hiding the engineering that keeps data safe.

## What Delta Does

- **Encrypted backups by default** using restic repositories. There is no unencrypted backup mode.
- **Incremental restore points** with content-addressed deduplication, metadata tracking, and `--skip-if-unchanged`.
- **Full-volume or custom-folder protection** with macOS-safe excludes and destination self-exclusion.
- **Per-profile extra exclusions** for large generated folders, transient files, disk images, or other paths that should not consume backup storage.
- **Local and network destinations** including local paths, mounted SMB/NFS volumes, SFTP, REST server, S3-compatible storage, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, rclone remotes, and custom restic URLs.
- **Destination validation before save** for required fields, new or changed writable local paths, REST URLs, SFTP paths/ports, S3 endpoint/bucket fields, and rclone remote syntax.
- **Non-interactive SFTP scheduling** with optional SSH private-key file configuration, SSH batch mode, and keepalive options so scheduled jobs fail clearly instead of waiting for password prompts.
- **Automatic destination preparation** after a destination is added, with a first-backup safety net for writable local/mounted destinations and unverified remote destinations that still have no encrypted backup metadata.
- **Scheduled backups** through Background Scheduling, a signed macOS Login Item helper registered with `SMAppService`, with helper-started jobs reflected back into the app and menu bar.
- **Power-aware scheduling** with battery and Low Power Mode controls.
- **Retention maintenance** with scheduled forget/prune/check windows.
- **Pause, resume, and cancel controls** for active backups from the main window and macOS menu bar, including scheduled jobs started by Background Scheduling. Pause stops restic safely, keeps the profile visibly paused, and Resume continues from already saved backup data.
- **Clear backup summaries** showing new, changed, unchanged, added, and checked data for each backup run.
- **Notification Center alerts** for failed or warning jobs, with optional successful-backup summaries. The signed background helper uses the same notification policy for scheduled runs.
- **Full or browsed selected restore** with backup browsing, file/folder selection, configurable dry-run and verification defaults, overwrite policies, original-path restore, chosen-folder restore, and optional pre-restore backup.
- **Streaming and saved backup logs** from restic stdout/stderr with source context, stable processed-file counters, clean change summaries, fixed-height live panes, and expandable per-job audit history.
- **Settings and diagnostics** with a top health summary for system access, schedules, updates, notifications, and bundled backup tools, plus controls for new-backup defaults, restore safety defaults, menu bar visibility, Activity log detail, app version, helper status, tool paths, profile/destination counts, recent jobs, and local support paths.
- **Sparkle automatic updates** with generated appcast/update archive support.

## How It Works

Delta does not invent a custom backup format. It delegates repository format, encryption, snapshots, deduplication, restore, pruning, and integrity checks to [restic](https://restic.net/).

At a high level:

1. A user creates a **Destination**, which is where encrypted restore points are stored.
2. Delta creates or uses a restic repository at that destination.
3. A user creates a **Backup Profile**, choosing sources, schedule, retention, bandwidth, and power policy.
4. Scheduled or manual runs invoke bundled `restic` through `ResticRunner`.
5. Destination passwords are fetched from Keychain through `DeltaSecretBridge` using restic `--password-command`.
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
- `DeltaAgent`: signed Background Scheduling Login Item helper for scheduled runs.
- `DeltaSecretBridge`: CLI password bridge used by restic `--password-command`.
- `DeltaCore`: shared models, database, command builder, scheduling, restic runner, parser, Keychain, bookmarks, locks, job logs, and policy code.

Important implementation details:

- **SQLite persistence** lives under Application Support through `AppDirectories.databaseURL()` with WAL mode and a busy timeout for app/agent concurrent access.
- **Durable-state fail closed** behavior prevents backup, destination, and restore operations if the Application Support database cannot be opened. Delta shows a blocked state instead of continuing against throwaway state.
- **Profile validation** normalizes source paths, schedule values, bandwidth limits, retention limits, cleanup windows, and exclude patterns before saving or running backups.
- **Operation-aware destination checks** allow a first backup to prepare a writable new local destination or an uninitialized remote destination, while restore, browse, check, and cleanup require an existing destination before restic is invoked.
- **Keychain secrets** use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and a trusted-application access list for the signed Delta app, agent, and secret bridge. Background secret reads fail closed instead of showing system prompts.
- **Background secret repair** rewrites saved destination passwords and backend credentials through the current signed app identity if a development build or old local Keychain item would otherwise prompt during scheduled jobs.
- **Destination credential forms** use provider-specific labels and only hide actual password/token fields; non-secret values such as account names and rclone config paths stay readable.
- **SFTP authentication** uses SSH config, ssh-agent, or an optional destination-level private-key path. Delta forces SSH batch mode for scheduled safety and does not rely on interactive SSH password prompts.
- **Security-scoped bookmarks** preserve access to selected source folders where macOS requires it.
- **Per-destination locks** prevent overlapping backup, restore, prune, and check jobs across app/agent processes.
- **Per-job output logs** persist formatted restic progress, warnings, errors, start lines, and finish lines for troubleshooting after relaunch or scheduled agent runs.
- **Compact backup summaries** persist structured new/changed/unchanged/add/check counts on job records without storing full restic stdout in the job message.
- **Notification policy** is shared by the app and Background Scheduling helper. Failure and warning alerts are opt-in; successful backup summaries require a second opt-in to avoid alert fatigue.
- **Durable run controls** let the app request pause/cancel for an agent-owned restic process without relying on in-memory UI state.
- **Abandoned-job recovery** marks stale running jobs interrupted after restart only when the per-destination lock proves no restic process still owns the destination.
- **Bundled tools** are pinned and checksum-verified through `Scripts/bootstrap-tools.sh`.
- **Packaged app verification** checks signatures, minimal hardened-runtime entitlements, Sparkle embedding, background helper plist integrity, helper smoke tests, signed Sparkle update metadata, bundled restic/rclone versions, and the restic command/flag surface Delta depends on.
- **Sanitized diagnostic reports** can be copied or exported from Settings without including destination passwords or backend credential values.

## Backup Behavior

Delta creates file-level backups. Full-volume mode is not a bootable clone or bare-metal restore mechanism.

Full-volume profiles start from the startup volume (`/`) or a user-selected mounted volume. When the user chooses a folder on a mounted drive, Delta stores the volume root such as `/Volumes/Archive` instead of the clicked subfolder.

For full-volume profiles, Delta uses:

- restic `backup`
- `--one-file-system`
- macOS-safe excludes
- explicit local destination exclusion
- `--compression auto`
- `--skip-if-unchanged`
- profile/restic tags

Custom-folder profiles use the selected source folders and stored security-scoped bookmarks where available.

Each profile keeps Delta's default macOS-safe excludes and can add extra restic exclude patterns. Extra excludes are saved with the profile and passed to restic as additional `--exclude` arguments.

Settings include app-level defaults for newly-created backup profiles: missed-run catchup, battery policy, Low Power Mode policy, cleanup space reclamation, and cleanup verification. Those defaults seed new profiles only. Existing profiles keep their own schedule, power, bandwidth, retention, and maintenance settings until edited.

## Scheduling And Maintenance

Background Scheduling lets scheduled profiles run while the main Delta window is closed. The macOS implementation is `DeltaAgent`, a signed Login Item helper registered through `SMAppService` and implemented as a per-user LaunchAgent. In user-facing UI, Delta presents this as Background Scheduling because LaunchAgent is the macOS scheduling mechanism, not a user-facing product feature. It runs as the signed-in user, not as a privileged admin helper, wakes for short schedule checks, starts due backups when policy allows it, then exits.

On each check, Background Scheduling evaluates:

- backup schedule: hourly, daily, weekly, monthly, or custom interval
- missed-run catchup policy
- destination availability
- battery policy
- Low Power Mode policy
- bandwidth limits
- per-destination lock state
- scheduled retention maintenance

When an enabled scheduled profile is saved, Delta requests Background Scheduling registration automatically. If macOS still requires approval, Delta shows an action-needed scheduled-backup card on the dashboard and a detailed status in Settings. macOS may require manual approval in Login Items; apps cannot approve their own background items.

The visible menu bar dropdown is separate from Background Scheduling. Users can show or hide the menu bar item from Settings without changing scheduled backup execution. The menu bar item provides quick access to Back Up Now, Run Due Backups, Pause, Stop, Activity, update checks, and last-backup status.

Notification Center alerts are also separate from Background Scheduling. When enabled in Settings and allowed by macOS, Delta alerts on failed or warning jobs from either the app or the signed helper. Successful backup summaries are available as a separate opt-in.

Retention maintenance can run `forget`, `prune`, and optional `check` based on the profile maintenance schedule. Post-prune checks are returned to the agent so failed validation is visible in job status and process exit status.

For local and mounted destinations, scheduled maintenance fails fast with a clear reconnect/remount message when the destination folder is absent. Delta does not launch restic for cleanup or check work against a missing drive.

For remote destinations, Delta performs a one-time lightweight restore-point probe before the first backup if the destination has not been verified yet. If the remote already contains encrypted backup metadata, Delta uses it and caches the verified state. If restic reports that the destination is missing, Delta prepares it automatically before the backup starts. Password, credential, lock, or network failures stop before backup data is scanned.

## Restore Workflow

Restore is intentionally explicit:

1. Choose a Destination.
2. Refresh and choose a Restore Point.
3. Restore the full restore point, or browse backed-up source folders and select specific files/folders.
4. Choose a destination folder or original paths.
5. Choose conflict behavior:
   - Replace all
   - Replace changed
   - Replace older
   - Keep existing
6. Preview or run the restore with the selected overwrite and verification policy.
7. Optionally verify restored files.
8. Confirm in-place restore when restoring to original paths. Delta enforces this confirmation before any non-preview original-path restore can run.

Settings include conservative restore defaults: preview first, verify restored files, and replace only changed files. Users can change those defaults in Settings and still override them for an individual restore.

The browser loads source roots from the selected restore point immediately and asks restic for one folder's contents at a time with `ls --json`, so full-volume backups do not need to be expanded into memory before selection. Selected-path restore uses restic snapshot path syntax for one selected path, and include filters for multiple selected paths.

## Security Model

- Backup data is encrypted by restic before it leaves the Mac.
- Destination encryption passwords are generated by Delta or supplied by the user.
- Destination passwords and backend credentials are stored in Keychain under Delta's destination-secret namespace.
- New user-managed encryption passphrases must be entered twice before the destination can be saved.
- Restic receives the destination password through a short-lived password command, not a long-lived plaintext environment variable.
- Command redaction hides password-command values from logs/descriptions.
- Backend credentials are injected only into a curated child-process environment for the restic run; Delta does not forward arbitrary ambient environment secrets.
- Empty-password restic repositories are not used.

Losing the destination password means losing access to the encrypted backup data. That is a restic security property, not a recoverable app state.

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
Scripts/verify-product-language.sh
Scripts/verify-restic-surface.sh
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

Production readiness and manual macOS acceptance:

```text
docs/PRODUCTION_READINESS.md
```

Package Sparkle update assets:

```sh
Scripts/package-update.sh
Scripts/generate-appcast.sh
```

## Release And Signing

Local development builds prefer `DELTA_CODESIGN_IDENTITY` when set. If it is unset, the build script automatically uses the first available `Developer ID Application` or `Apple Development` signing identity before falling back to ad-hoc signing. Stable signing matters for macOS privacy permissions such as Full Disk Access; changing the signing identity changes the app identity macOS trusts. The release verifier rejects ad-hoc-signed app bundles because they are not production-ready and can invalidate privacy approvals between installs.

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
