# Delta

Delta is a native SwiftUI macOS backup app built around restic. It is designed for encrypted, incremental, scheduled file-level backups to local drives, mounted network drives, and restic-supported remote destinations.

The product goal is simple: make serious backup practices approachable without hiding the engineering that keeps data safe.

## What Delta Does

- **Encrypted backups by default** using restic repositories. There is no unencrypted backup mode.
- **Incremental restore points** with content-addressed deduplication, metadata tracking, and `--skip-if-unchanged`.
- **Full-volume or custom-folder protection** with macOS-safe excludes and destination self-exclusion.
- **Source preflight before backup** so moved, missing, file-only, or unreadable source selections fail before restic starts or a new destination is prepared.
- **Per-profile extra exclusions** for large generated folders, transient files, disk images, or other paths that should not consume backup storage.
- **Local and network destinations** including local paths, mounted SMB/NFS volumes, SFTP, REST server, S3-compatible storage, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, rclone remotes, and custom restic URLs.
- **Destination validation before save** for required fields, new or changed writable local paths, REST URLs, SFTP paths/ports, S3 endpoint/bucket fields, and rclone remote syntax.
- **Non-interactive SFTP scheduling** with optional SSH private-key file configuration, SSH batch mode, and keepalive options so scheduled jobs fail clearly instead of waiting for password prompts.
- **Automatic destination preparation** after a destination is added, with a first-backup safety net for local/mounted destinations that pass a real write/delete probe and unverified remote destinations that still have no encrypted backup metadata.
- **Scheduled backups** through Delta's signed macOS Login Item scheduler registered with `SMAppService`, with scheduler-started jobs reflected back into the app and menu bar.
- **Power-aware scheduling** with a Pause automatic runs setting, battery and Low Power Mode controls, plus optional idle-sleep protection while backup, restore, check, and cleanup jobs are actively running.
- **Retention maintenance** with scheduled forget/prune/check windows.
- **Pause, resume, and cancel controls** for active backups from the main window and macOS menu bar, including scheduled jobs started by the scheduler. Pause stops restic safely, keeps the profile visibly paused, and Resume continues from already saved backup data.
- **Clear backup summaries** showing new, changed, unchanged, added, and checked data for each backup run.
- **Backup health monitoring** with source-access warnings, configurable freshness, destination-verification, and local/mounted free-space warnings for scheduled profiles with no completed backup, stale restore points, failed runs, stopped runs, unchecked destinations, stale destination checks, low-capacity destinations, or unavailable local/mounted destinations.
- **Notification Center alerts** for failed or warning jobs, with optional successful-backup summaries and a Settings test alert. The signed scheduler uses the same notification policy for scheduled runs.
- **Full or browsed selected restore** with backup browsing, file/folder selection, configurable dry-run and verification defaults, overwrite policies, original-path restore, chosen-folder restore, and optional pre-restore backup.
- **Streaming and saved backup logs** from restic stdout/stderr with source context, stable processed-file counters, clean change summaries, fixed-height live panes, and expandable per-job audit history.
- **Settings and diagnostics** with a compact health summary for system access, schedules, password access, updates, notifications, and bundled backup tools, plus controls for pausing automatic runs, repairing password access for unattended backups, freshness/check/free-space health thresholds, new-backup defaults, restore safety defaults, idle-sleep protection during active jobs, menu bar visibility, start-at-login, Activity log detail, scheduled-run tests, signed update checks/downloads, app version, scheduler status, tool paths, profile/destination counts, recent jobs, and local support paths.
- **Sparkle automatic updates** with generated appcast/update archive support.

## How It Works

Delta does not invent a custom backup format. It delegates encrypted storage format, snapshots, deduplication, restore, pruning, and integrity checks to [restic](https://restic.net/).

At a high level:

1. A user creates a **Destination**, which is where encrypted restore points are stored.
2. Delta creates or uses encrypted restic storage at that destination.
3. A user creates a **Backup Profile**, choosing sources, schedule, retention, bandwidth, and power policy.
4. Scheduled or manual runs invoke bundled `restic` through `ResticRunner`.
5. Destination passwords are fetched from Keychain through `Delta --secret-bridge` using restic `--password-command`.
6. Job state, restore points, events, settings, restore requests, and profile definitions are persisted in SQLite via GRDB.
7. Restore always goes through a wizard: destination, restore point, scope, restore location, conflict policy, preview, then execution.

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
- `DeltaAgent`: signed Scheduled Backups Login Item scheduler for scheduled runs.
- `DeltaSecretBridge`: signed fail-closed compatibility password helper. Current backup jobs use `Delta --secret-bridge` so scheduled work and password reads share the same app identity.
- `DeltaCore`: shared models, database, command builder, scheduling, restic runner, parser, Keychain, bookmarks, locks, job logs, and policy code.

Important implementation details:

- **SQLite persistence** lives under Application Support through `AppDirectories.databaseURL()` with WAL mode and a busy timeout for app/agent concurrent access.
- **Durable-state fail closed** behavior prevents backup, destination, and restore operations if the Application Support database cannot be opened. Delta shows a blocked state instead of continuing against throwaway state.
- **Profile validation** normalizes source paths, schedule values, bandwidth limits, retention limits, cleanup windows, and exclude patterns before saving or running backups.
- **Source access preflight** runs after security-scoped bookmark resolution and before destination preparation so unattended jobs fail clearly when a selected folder was moved, removed, replaced by a file, or is no longer readable.
- **Operation-aware destination checks** allow a first backup to prepare a writable new local destination or an uninitialized remote destination, while restore, browse, check, and cleanup require an existing destination before restic is invoked.
- **Keychain secrets** use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and are read by the same signed Delta executable in app, scheduled, and restic password-command paths. Password Access checks use an interaction-disabled authentication context and fail closed instead of showing system prompts. Delta surfaces Password Access health so users can repair saved destination access before scheduled backups depend on it. The tiny `DeltaSecurity` compatibility shim is kept only for trusted-application access-list support in local development.
- **Password Access repair** rewrites saved destination passwords and backend credentials through the current signed app identity if a development build or old local Keychain item would otherwise prompt during scheduled jobs.
- **Destination credential forms** use provider-specific labels and only hide actual password/token fields; non-secret values such as account names and rclone config paths stay readable.
- **SFTP authentication** uses SSH config, ssh-agent, or an optional destination-level private-key path. Delta forces SSH batch mode for scheduled safety and does not rely on interactive SSH password prompts.
- **Security-scoped bookmarks** preserve access to selected source folders where macOS requires it.
- **Per-destination locks** prevent overlapping backup, restore, prune, and check jobs across app/agent processes.
- **Per-job output logs** persist formatted restic progress, warnings, errors, start lines, and finish lines for troubleshooting after relaunch or scheduled agent runs.
- **Compact backup summaries** persist structured new/changed/unchanged/add/check counts on job records without storing full restic stdout in the job message.
- **Bounded operational history** applies a configurable retention policy to job summaries, saved output, restore requests, and app events from both the main app and Scheduled Backups. Restore points and backup data are not affected.
- **Notification policy** is shared by the app and Scheduled Backups scheduler. Failure and warning alerts are opt-in; successful backup summaries require a second opt-in to avoid alert fatigue. Settings includes a Send Test Alert action so users can verify macOS permission and delivery before relying on scheduled alerts.
- **Redacted diagnostics** can be copied, exported, or generated with `Delta --export-diagnostics` for support. Diagnostic reports include app, scheduler, destination, profile, job, and tool state while redacting URL credentials and known backend credential values.
- **Durable run controls** let the app request pause/cancel for an agent-owned restic process without relying on in-memory UI state.
- **Abandoned-job recovery** marks stale running jobs interrupted after restart only when the per-destination lock proves no restic process still owns the destination.
- **Bundled tools** are pinned and checksum-verified through `Scripts/bootstrap-tools.sh`.
- **Packaged app verification** checks signatures, minimal hardened-runtime entitlements, Sparkle embedding, scheduler plist integrity, scheduler smoke tests, installed scheduled-backup acceptance, installed pause/resume/cancel run-control acceptance, signed Sparkle update metadata, bundled restic/rclone versions, the restic command/flag surface Delta depends on, and a real local dry-run restore that must not write files.
- **Sanitized diagnostic reports** can be copied or exported from Settings without including destination passwords or backend credential values.
- **Isolated app-data smoke tests** use `DELTA_APP_SUPPORT_DIR` so release verification can exercise the installed scheduler's real due-backup path without touching a developer's personal Delta database.

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

Settings are grouped into General, Defaults, Updates, and Advanced. General covers Scheduled Backups, Password Access, Full Disk Access, idle-sleep protection, menu bar/login behavior, and notifications. Defaults covers health monitoring plus new backup and restore defaults. Health monitoring includes backup freshness, destination check age, and local/mounted destination free-space warnings. Cloud destinations are skipped for free-space warnings because generic remote capacity is not exposed consistently. Updates configures Sparkle's signed update checks and downloads. Advanced contains diagnostics, bundled backup-tool status, support files, and activity history retention.

Settings include Pause automatic runs for temporarily suspending due scheduled runs without editing profiles or removing macOS approval for scheduled backups. Manual Back Up Now actions still work. Settings also include app-level defaults for newly-created backup profiles: missed-run catchup, battery policy, Low Power Mode policy, optional bandwidth limits, retention keep rules, cleanup space reclamation, cleanup verification, and cleanup cadence. Those defaults seed new profiles only. Existing profiles keep their own schedule, power, bandwidth, retention, and maintenance settings until edited.

Delta can also hold a macOS activity assertion while a backup, restore, destination check, or cleanup is actively running. This is enabled by default to reduce the chance of long unattended jobs being interrupted by idle sleep. It does not force a scheduled backup to start on battery or in Low Power Mode; those profile policies are still evaluated before work begins.

Diagnostics settings include live-log detail and local activity history retention. History retention removes old job summaries, saved output, restore requests, and app events from Delta's SQLite database. It does not remove restore points or backup data from any destination.

## Scheduling And Maintenance

Scheduled Backups let scheduled profiles run while the main Delta window is closed. The macOS implementation is `DeltaAgent`, a signed Login Item scheduler registered through `SMAppService`; macOS runs it as a per-user LaunchAgent under the hood. In user-facing UI, Delta presents this as Scheduled Backups because LaunchAgent is the operating-system mechanism, not a product concept users should manage directly. It runs as the signed-in user, not as a privileged admin tool, wakes for short schedule checks, starts due backups when policy allows it, then exits.

On each check, Scheduled Backups evaluate:

- backup schedule: hourly, daily, weekly, monthly, or custom interval
- missed-run catchup policy
- destination availability
- battery policy
- Low Power Mode policy
- bandwidth limits
- per-destination lock state
- scheduled retention maintenance

When an enabled scheduled profile is saved, Delta requests scheduled-backup registration automatically. If macOS still requires approval, Delta shows an action-needed scheduled-backup card on the dashboard and a detailed status in Settings. Settings also exposes a Run Due Now action so automatic scheduling rules can be tested without waiting for the next five-minute check. macOS may require manual approval in Login Items; apps cannot approve their own background items.

The visible menu bar dropdown and Start at Login setting are separate from Scheduled Backups. Users can show or hide the menu bar item and choose whether Delta opens after sign-in without changing scheduled backup execution. Delta uses a native AppKit status item with a SwiftUI popover so long-running backup status updates do not dismiss the dropdown. The menu bar item changes symbol for ready, running, and attention states, and provides quick access to Back Up Now, Run Due Backups, Pause, Stop, Activity, update checks, and last-backup status. Status text and action availability are covered by shared DeltaCore policy tests so the main window and status menu do not drift.

Settings and diagnostics include Password Access. Delta verifies that every saved destination password and backend credential can be read with interaction disabled. If a development rebuild, signing change, or Keychain access-list drift would cause scheduled backups to prompt, Delta shows an action-needed status and offers Repair Password Access before unattended work relies on that secret.

Notification Center alerts are also separate from Scheduled Backups. When enabled in Settings and allowed by macOS, Delta alerts on failed or warning jobs from either the app or the signed scheduler. Successful backup summaries are available as a separate opt-in, and Send Test Alert verifies the macOS delivery path without starting a backup.

Retention maintenance can run `forget`, `prune`, and optional `check` based on the profile maintenance schedule. After successful cleanup, Delta refreshes the cached restore-point list so pruned restore points disappear without waiting for the next manual refresh. Post-prune checks are returned to the agent so failed validation is visible in job status and process exit status.

For local and mounted destinations, scheduled maintenance fails fast with a clear reconnect/remount message when the destination folder is absent or unwritable. Delta proves local writability with a hidden temporary write/delete probe and does not launch restic for cleanup or check work against a missing or read-only drive.

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
6. Preview or run the restore with the selected overwrite policy.
7. Optionally verify files after a real restore writes data.
8. Confirm in-place restore when restoring to original paths. Delta enforces this confirmation before any non-preview original-path restore can run.

Settings include conservative restore defaults: preview first, verify restored files, and replace only changed files. Users can change those defaults in Settings and still override them for an individual restore.

The browser loads source roots from the selected restore point immediately and asks restic for one folder's contents at a time with `ls --json`, so full-volume backups do not need to be expanded into memory before selection. Selected-path restore uses restic snapshot path syntax for one selected path, and include filters for multiple selected paths.

## Security Model

- Backup data is encrypted by restic before it leaves the Mac.
- Destination encryption passwords are generated by Delta or supplied by the user.
- Destination passwords and backend credentials are stored in Keychain under Delta's destination-secret namespace.
- New user-managed encryption passphrases must be entered twice before the destination can be saved.
- Restic receives the destination password through a short-lived password command, not a long-lived plaintext environment variable.
- Removing a destination from Delta first verifies no backup profile still uses it, removes cached app state, then cleans up saved password and credential items without deleting backup data at the destination.
- Command, stream, and final-message redaction hides destination URLs, destination-file paths, password-command values, and common backend secret assignments from logs/descriptions.
- Backend credentials are injected only into a curated child-process environment for the restic run; Delta does not forward arbitrary ambient environment secrets.
- Empty-password restic repositories are not used.

Losing the destination password means losing access to the encrypted backup data. That is a restic security property, not a recoverable app state.

## Automatic Updates

Delta uses [Sparkle](https://sparkle-project.org/) for automatic updates.

Settings expose Sparkle's automatic check interval and optional background download behavior. Delta still relies on Sparkle signature verification and prompts before replacing the app.

Relevant files:

- `Sources/Delta/SoftwareUpdateController.swift`
- `Packaging/Delta.app.plist`
- `Scripts/package-update.sh`
- `Scripts/generate-appcast.sh`
- `Scripts/verify-sparkle-update-artifacts.sh`

The appcast URL points at GitHub release assets:

```text
https://github.com/dbuskariol/delta/releases/latest/download/appcast.xml
```

Release verification validates the generated update archive, release notes, signed appcast enclosure, advertised file size, extracted app bundle identifier/version/build, extracted Sparkle settings, and extracted bundle code signature before a build is considered ready for manual Sparkle install testing.

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

Verify the installed `/Applications/Delta.app` copy:

```sh
Scripts/verify-installed-app.sh
```

Full release verification:

```sh
Scripts/verify-release.sh
```

Collect a release evidence report for the verified app:

```sh
Scripts/collect-release-evidence.sh
```

Generate machine-verifiable local acceptance evidence:

```sh
Scripts/run-local-acceptance-probe.sh
```

Run the installed app bundle's non-interactive Keychain access proof directly:

```sh
Scripts/run-installed-keychain-access-acceptance.sh
```

Run the installed app bundle's Settings/defaults proof directly:

```sh
Scripts/run-installed-preferences-acceptance.sh
```

Run the installed app bundle's local backup lifecycle directly:

```sh
Scripts/run-installed-local-backup-acceptance.sh
```

Run configured external backend lifecycles through the installed Delta coordinator:

```sh
DELTA_ACCEPTANCE_MOUNTED_PATH=/Volumes/BackupShare \
Scripts/run-external-backend-acceptance.sh mounted

DELTA_ACCEPTANCE_SFTP_REPOSITORY='sftp:user@example.com:/srv/backups/delta-acceptance' \
DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY="$HOME/.ssh/id_ed25519" \
Scripts/run-external-backend-acceptance.sh sftp

DELTA_ACCEPTANCE_S3_REPOSITORY='s3:https://s3.example.com/bucket/delta-acceptance' \
AWS_ACCESS_KEY_ID=... \
AWS_SECRET_ACCESS_KEY=... \
Scripts/run-external-backend-acceptance.sh s3

DELTA_ACCEPTANCE_B2_REPOSITORY='b2:bucket:delta-acceptance' \
B2_ACCOUNT_ID=... \
B2_ACCOUNT_KEY=... \
Scripts/run-external-backend-acceptance.sh b2

DELTA_ACCEPTANCE_AZURE_REPOSITORY='azure:container:/delta-acceptance' \
AZURE_ACCOUNT_NAME=... \
AZURE_ACCOUNT_KEY=... \
Scripts/run-external-backend-acceptance.sh azure

DELTA_ACCEPTANCE_GCS_REPOSITORY='gs:bucket:/delta-acceptance' \
GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json \
Scripts/run-external-backend-acceptance.sh gcs

DELTA_ACCEPTANCE_SWIFT_REPOSITORY='swift:container:/delta-acceptance' \
OS_AUTH_URL=... OS_USERNAME=... OS_PASSWORD=... \
Scripts/run-external-backend-acceptance.sh swift

DELTA_ACCEPTANCE_RCLONE_REPOSITORY='rclone:remote:delta-acceptance' \
RCLONE_CONFIG=/path/to/rclone.conf \
Scripts/run-external-backend-acceptance.sh rclone

DELTA_ACCEPTANCE_REST_REPOSITORY='rest:https://rest.example.com/delta-acceptance' \
Scripts/run-external-backend-acceptance.sh rest
```

`DELTA_ACCEPTANCE_MOUNTED_PATH` must point to a mounted network filesystem under `/Volumes`, such as SMB or NFS. Local external disks are covered by the installed local lifecycle acceptance instead.

Create and verify the manual macOS acceptance report:

```sh
Scripts/create-manual-acceptance-report.sh
# Edit dist/manual-acceptance/latest.md after testing each required item.
Scripts/verify-manual-acceptance.sh
```

After Developer ID notarization and installing the exact release candidate, run the hard external-distribution gate:

```sh
Scripts/verify-production-readiness.sh
```

The local acceptance probe writes `dist/local-acceptance/latest.md` and separates automated evidence from human-only checks. It also runs `Scripts/run-installed-keychain-access-acceptance.sh`, which creates a throwaway destination-secret item through the installed Delta app, proves the installed password bridge mode can read it without interaction, then deletes it. It runs `Scripts/run-installed-scheduled-agent-acceptance.sh`, which seeds an isolated due scheduled profile and proves the installed Scheduled Backups scheduler runs one real backup through the installed Delta executable without interactive Keychain prompts. It runs `Scripts/run-installed-diagnostics-acceptance.sh`, which seeds isolated installed-app state, exports diagnostics through the installed app, proves seeded destination/backend credential values are redacted, and records the installed app's own Full Disk Access status. It runs `Scripts/run-installed-preferences-acceptance.sh`, which verifies the signed app's shared Settings surface contract, required Settings categories, compact status summary, recommended defaults, unsafe value normalization, custom backup defaults persisted to a new profile, custom restore defaults, diagnostic settings summaries, and restoration of existing preference values. It runs `Scripts/run-installed-run-control-acceptance.sh`, which launches the installed Delta app in run-control acceptance mode and verifies Delta's coordinator, SQLite job store, durable stop-request files, resumable pause state, successful resume, non-resumable cancel state, cleared stop requests, job logs, and restore-point refresh after resume. It also runs `Scripts/run-installed-local-backup-acceptance.sh`, which launches the installed Delta app in local lifecycle acceptance mode and verifies Delta's coordinator, SQLite store, Keychain password command, bundled restic, automatic destination preparation, first backup, no-change backup, incremental backup, newest-first restore-point cache, backup browser listing with nested file metadata, full restore, selected folder restore, selected file restore, dry-run restore with no writes, every overwrite policy, destination check, cleanup, post-cleanup check, pruned restore-point cache refresh, and saved backup log source/summary evidence against a temporary encrypted local destination. When configured with external backend environment variables, it also runs `Scripts/run-external-backend-acceptance.sh`, which launches the installed Delta app in external lifecycle acceptance mode against mounted, SFTP, REST, S3-compatible, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, rclone, and custom restic destinations. That external mode verifies Delta's coordinator, isolated SQLite store, Keychain password command, bundled restic, automatic destination preparation, no-change dedupe behavior, restore-point cache, restore browser listing, full restore, selected folder restore, destination check, cleanup, and post-cleanup check against the real backend. Credentialed backend acceptance stores provider environment values as Delta Keychain credential references, then proves they are usable without inheriting ambient shell secrets. Remote acceptance URLs must point at dedicated paths containing `delta-acceptance` unless `DELTA_ACCEPTANCE_ALLOW_EXISTING_REMOTE=1` is set after a human confirms the target is safe. New manual reports copy that local evidence into the Evidence / Notes column, add a `Manual evidence: TODO` marker, and keep every Result as `Not run`. A row marked `Passed` fails verification until the generated local-probe/follow-up text is replaced with real manual evidence. Local evidence is useful release evidence, but it does not replace the manual macOS acceptance matrix for Full Disk Access approval, macOS Login Items approval, closed-window scheduling UI, disconnect/reconnect behavior, menu bar visual interaction, Notification Center delivery, Sparkle update installation, or notarization.

The release evidence report is written under `dist/release-evidence/` and records the app version, git commit, signing details, scheduler/tool smoke output, Sparkle artifacts, automated gate status, local acceptance probe output, installed app smoke output, notarization ticket status, notarization credential policy, and manual acceptance report verification. `Scripts/verify-production-readiness.sh` fails unless that evidence, the current manual acceptance report, notarization, Gatekeeper, and the installed app all prove the same current git commit is ready for external distribution.

To see the remaining external prerequisites in one place, run:

```sh
Scripts/doctor-production-readiness.sh
```

The doctor checks signing identities, automated-gate freshness, installed-app identity, notarization and Gatekeeper state, local and manual acceptance reports, and external backend acceptance environment variables. It exits non-zero while blockers remain; set `DELTA_DOCTOR_ALLOW_BLOCKERS=1` when you only want the report.

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

Local development builds prefer `DELTA_CODESIGN_IDENTITY` when set. If it is unset, the build script automatically uses the first available `Developer ID Application` or `Apple Development` signing identity before falling back to ad-hoc signing. Stable signing matters for macOS privacy permissions such as Full Disk Access; changing the signing identity changes the app identity macOS trusts. The release verifier rejects ad-hoc-signed app bundles because they are not production-ready and can invalidate privacy approvals between installs. It also fails the production app build if compiler warnings are emitted.

Developer ID distribution should use:

```sh
DELTA_CODESIGN_IDENTITY="Developer ID Application: Example" Scripts/verify-release.sh
```

Notarize and staple the verified Developer ID build:

```sh
xcrun notarytool store-credentials "Delta Notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"

DELTA_CODESIGN_IDENTITY="Developer ID Application: Example" Scripts/build-app.sh
DELTA_NOTARY_KEYCHAIN_PROFILE="Delta Notary" Scripts/notarize-release.sh
```

`Scripts/notarize-release.sh` submits `dist/Delta.app`, waits for Apple notarization, staples the ticket, validates Gatekeeper assessment, archives the notarization log under `dist/notarization`, and regenerates Sparkle update assets from the stapled app. It also supports `DELTA_NOTARY_PREPARE_ONLY=1` for local archive validation without submitting to Apple.

Notarization credentials must be stored in a `notarytool` keychain profile. Delta intentionally does not support Apple ID, team ID, or app-specific password environment-variable fallbacks for release notarization because those credentials can persist in shell state or be exposed as process arguments.

Final external release check:

```sh
Scripts/install-app.sh
Scripts/verify-production-readiness.sh
```

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
