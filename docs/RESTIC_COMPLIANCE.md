# Restic Compliance Notes

Delta uses restic as the backup engine. This document maps Delta behavior to restic commands, options, backend syntax, and expected exit handling.

## Version

Bundled restic is pinned in `Resources/Tools/tools.json` and installed by `Scripts/bootstrap-tools.sh`.

The verifier checks:

```sh
Resources/Tools/bin/restic version
Resources/Tools/bin/rclone version
```

## Destination Passwords

Delta uses restic `--password-command`.

The command points at `Delta --secret-bridge`, which reads the destination password from Keychain and writes it to stdout for restic. Delta does not pass destination passwords through long-lived environment variables or command-line literals. Job logs use the command's redacted description, which hides destination URL arguments, destination-file paths, and password-command values before persisting the start line. Streamed restic output and fallback final job messages are also redacted for URL-embedded credentials and common backend secret assignments before they are displayed or stored.

`Delta --secret-bridge` accepts exactly one keychain account argument and exits with usage status for missing or extra arguments. This keeps the password bridge fail-closed if restic or a caller invokes it with an unexpected command line. The standalone `DeltaSecretBridge` target remains signed and fail-closed as a compatibility helper, but it is not the active restic password command.

If restic reports that password resolution failed through the bridge, Delta maps the failure to a destination-password access message that points users to Repair Password Access or re-saving the destination, instead of showing raw Keychain status output.

App-managed destinations use a generated Keychain password stored under `com.delta.backup.destination-secrets` with a `Delta destination secrets` access label. User-managed passphrase destinations require confirmation before the password is stored.

Relevant files:

- `Sources/DeltaCore/ResticCommand.swift`
- `Sources/Delta/DeltaApp.swift`
- `Sources/DeltaSecretBridge/main.swift`
- `Sources/DeltaCore/KeychainSecretStore.swift`

## Backends

Delta supports the following restic backend families:

| Destination type | Restic URL shape |
| --- | --- |
| Local/mounted path | `/Volumes/Backup/Delta` |
| SFTP | `sftp:user@host:/path` |
| SFTP with port/IPv6 | `sftp://user@host:2222//absolute/path` |
| REST server | `rest:https://host:8000/delta` |
| S3-compatible | `s3:https://server:port/bucket/delta` |
| Backblaze B2 | `b2:bucket:path/to/delta` |
| Azure Blob | `azure:container:/path` |
| Google Cloud Storage | `gs:bucket:/path` |
| OpenStack Swift | `swift:container:/path` |
| rclone | `rclone:remote:path` |
| Custom | User-supplied restic URL |

URL construction is covered by `ResticCommandTests`.

Delta validates destination inputs before saving them. The validator trims persisted fields, requires writable new or changed local destinations or writable parents, rejects relative local paths in the native destination form, requires absolute SFTP paths and valid ports, normalizes optional SFTP SSH identity-file paths, requires the identity file to be readable when provided, requires S3 endpoint and bucket fields, validates REST URLs as `http` or `https`, and rejects rclone remote names that already include a colon. Advanced raw restic URLs remain available through the custom destination type.

After a destination is created, Delta starts a prepare job that runs `restic init` with the saved encryption secret and backend credentials. The destination row action remains available as a retry path. Delta also keeps a first-backup safety net. For local and mounted destinations, a writable path with no restic `config` file is initialized before backup starts. For remote destinations that have not been verified yet, Delta first runs a lightweight `snapshots --json` probe. If the probe succeeds, the destination is treated as existing and verified. If restic reports a missing destination, Delta runs `restic init` before starting backup. Password, backend credential, lock, and network failures stop before source scanning begins.

Destination availability checks are operation-aware. Creating or preparing a local destination may use an existing writable parent directory, but restore point refresh, backup browsing, restore, integrity check, and cleanup require the destination directory itself to exist and pass a hidden temporary write/delete probe before Delta invokes restic. If a mounted drive is missing or unwritable, Delta records or throws a user-facing unavailable-destination result instead of starting restic and surfacing backend noise.

Backup profiles are validated before save and again before execution. Delta trims and deduplicates source paths, rejects empty or relative source paths, verifies the profile still points at an existing destination, normalizes schedule and cleanup windows, clamps retention and bandwidth limits to product-supported ranges, and keeps default macOS-safe excludes present. If a persisted profile is invalid, Delta records a failed job and does not invoke restic.

## Backend Credentials

Backend credentials and backend configuration values are stored in Keychain and injected into a curated restic process environment only for the job run. Scheduled jobs exec the main Delta executable before resolving saved secrets, and restic uses `Delta --secret-bridge <account>` as its password command, so the same signed app identity that saves destination secrets reads them later. Agent and secret-bridge reads use a non-interactive `LAContext`, so scheduled jobs fail closed instead of showing Keychain prompts. New destination creation rolls back newly-created backend credential/configuration and destination password items if persistence fails, and partial backend field saves roll back earlier saved items before returning the error. Destination removal is blocked while any backup profile still references that destination; once allowed, Delta removes the app-side destination and cached restore point metadata before best-effort cleanup of saved destination password and backend credential/configuration items. Delta exposes Password Access health in Settings and diagnostics by verifying saved destination passwords plus backend credential/configuration items with interaction disabled. The repair operation reloads and rewrites those secrets through the current signed app identity, then verifies they are readable with interaction disabled. Delta forwards operational values such as `PATH`, `HOME`, `TMPDIR`, locale, and `SSH_AUTH_SOCK`, but does not pass arbitrary ambient environment variables to restic.

Supported credential templates include:

- REST: `RESTIC_REST_USERNAME`, `RESTIC_REST_PASSWORD`
- S3: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- Backblaze B2: `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`
- Azure Blob: `AZURE_ACCOUNT_NAME`, `AZURE_ACCOUNT_KEY`, `AZURE_ACCOUNT_SAS`, `AZURE_ENDPOINT_SUFFIX`
- Google Cloud Storage: `GOOGLE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_ACCESS_TOKEN`
- OpenStack Swift: `ST_AUTH`, `ST_USER`, `ST_KEY`, `OS_AUTH_URL`, `OS_REGION_NAME`, `OS_USERNAME`, `OS_USER_ID`, `OS_PASSWORD`, `OS_TENANT_ID`, `OS_TENANT_NAME`, `OS_PROJECT_NAME`, `OS_PROJECT_DOMAIN_NAME`, `OS_PROJECT_DOMAIN_ID`, `OS_USER_DOMAIN_NAME`, `OS_USER_DOMAIN_ID`, `OS_TRUST_ID`, `OS_APPLICATION_CREDENTIAL_ID`, `OS_APPLICATION_CREDENTIAL_NAME`, `OS_APPLICATION_CREDENTIAL_SECRET`, `OS_STORAGE_URL`, `OS_AUTH_TOKEN`, `SWIFT_DEFAULT_CONTAINER_POLICY`
- rclone: `RCLONE_CONFIG`

The destination editor presents these as provider-specific field labels instead of raw environment variable names. Actual passwords, secret keys, SAS tokens, and access tokens use secure fields; non-secret configuration values such as account IDs, project IDs, endpoint suffixes, and rclone config paths remain visible.

S3 region is passed as an explicit restic backend option:

```text
-o s3.region=<region>
```

SFTP destinations are always run with non-interactive SSH arguments:

```text
-o sftp.args="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
```

If the user chooses an SSH private key file, Delta adds:

```text
-i <identity-file> -o IdentitiesOnly=yes
```

This follows restic's SFTP guidance that automatic backups require passwordless SSH authentication. The `accept-new` host-key policy allows first-time scheduled connections to avoid interactive prompts while still rejecting changed host keys. The identity file path is destination configuration, not a backend password; passphrase-protected keys must already be available through ssh-agent or the configured SSH environment.

rclone is pinned to the bundled executable when available:

```text
-o rclone.program=<Delta.app>/Contents/MacOS/rclone
```

## Backup

Delta backup commands use:

```text
backup
--json
--compression auto
--skip-if-unchanged
--tag delta
--tag profile:<profile-id>
```

Full-volume backups additionally use:

```text
--one-file-system
```

The UI stores full-volume sources as volume roots (`/` or `/Volumes/<name>`). Choosing a folder on a mounted volume is normalized to the containing volume root before command construction, so the stored profile matches restic's `--one-file-system` behavior.

Delta adds macOS-safe excludes and excludes the local destination path when the destination is inside a local filesystem path.

Per-profile extra exclusions are merged with Delta's default macOS-safe exclusions and forwarded as additional `--exclude` arguments. The profile editor stores only the user's extra patterns in the visible field; the command builder always keeps the built-in safety patterns.

Expected restic backup exit handling:

| Exit code | Delta state |
| --- | --- |
| `0` | Succeeded |
| `3` | Warning, incomplete snapshot due to unreadable source data, even if restic output does not include a matching permission phrase |
| `10` | Destination not prepared/found |
| `11` | Destination locked |
| `12` | Wrong password |
| other non-zero | Failed or cancelled when interruption text is present |

Generic `permission denied` or `operation not permitted` failures are not treated as unreadable-source warnings unless restic exits with code `3` or explicitly reports unreadable source data. Delta shows a broader permissions message for restore target, destination, or source permission failures so users are not sent only to Full Disk Access when the write target is the problem.

Before invoking restic for a backup, Delta resolves security-scoped source bookmarks, then verifies each selected source still exists, is a folder, and is readable. This check happens before first-backup destination preparation, so an invalid source cannot accidentally initialize a new destination and then fail later. Full-volume backups still rely on restic's own traversal and exit-code behavior for protected files inside an otherwise readable volume.

Restic progress totals can change while it scans sources, so Delta does not expose volatile live percentages as authoritative completion. The UI uses a monotonic estimated progress bar that never moves backward during a running job, paired with stable processed-file and processed-byte counters. Backup jobs record source paths at job start, and saved logs are grouped by job with expandable full-log loading from SQLite. Restic summary JSON is parsed into explicit new, changed, unchanged, added, and checked counts so unchanged successful runs are clearly distinguished from runs that created new backup data. Delta stores those counts as compact structured job metadata, including restic `snapshot_id` when present, instead of storing the complete restic stdout stream in the job message.

Saved activity output is operational history, not backup data. Delta applies a configurable local retention policy to job summaries, saved stdout/stderr lines, restore request records, and app events from both the main app and Scheduled Backups scheduler. Cleanup keeps a minimum set of recent job summaries for UI continuity and never deletes cached restore points or encrypted destination data.

## Snapshots / Restore Points

Delta lists restore points with:

```text
snapshots --json
```

The JSON parser is covered by unit tests.

Every successful restore point refresh treats restic's `snapshots --json` response as authoritative for that destination. Delta replaces that destination's cached restore points in SQLite instead of only appending, so restore points removed by cleanup are not left selectable. Restore point IDs are scoped by destination in SQLite, which allows cloned or mirrored destinations to contain the same restic snapshot ID without overwriting each other. Restore point reads are sorted newest-first.

Delta browses files and folders inside a selected restore point with:

```text
ls --json --sort name <snapshot-id> <absolute-directory-path>
```

The UI starts from the restore point's backed-up source roots and loads one directory at a time. Delta does not recursively dump a full-volume backup into app memory just to render the browser. Before invoking restic, Delta trims and validates the restore point ID and rejects relative folder filters because restic `ls` directory arguments must be absolute paths inside the restore point. `ls --json` output is parsed as newline-delimited restic node records; non-node records are ignored.

## Restore

Delta trims and validates restore requests before building restic arguments. Restore point IDs must be non-empty, chosen restore targets must be non-empty, and selected restore paths must be absolute paths from the restore point. Duplicate selected paths and children of an already selected parent are collapsed before command construction. Delta restore commands use:

```text
restore
--json
--overwrite <always|if-changed|if-newer|never>
--target <path>
```

Optional restore flags:

```text
--verify
--dry-run
--verbose=2
```

Delta never combines `--verify` with `--dry-run`. Preview-only restores do not write files, so there are no restored files for restic to verify; verification is applied only to real restores that write data.

Single selected path restore uses restic snapshot path syntax:

```text
<snapshot-id>:/path/to/restore
```

Multiple selected paths from the browser use repeated include filters:

```text
--include /path/one
--include /path/two
```

Non-preview restore to original paths targets `/` and requires an explicit confirmation flag on the restore request before Delta runs restic. Dry-run original-path previews are allowed without that confirmation.

## Retention, Prune, And Check

Delta retention maintenance uses:

```text
forget
--json
--keep-hourly <n>
--keep-daily <n>
--keep-weekly <n>
--keep-monthly <n>
--keep-yearly <n>
--group-by host,paths,tags
--prune
```

`--prune` is controlled by the profile retention policy.

When post-prune validation is enabled, Delta runs:

```text
check --json --read-data-subset 1/100
```

Scheduled maintenance is evaluated independently from backup due checks, but it uses the same profile, destination, power policy, and per-destination locking path. Background due checks use the latest backup and cleanup attempts, not only successful runs, so a failed destination or credential state is not retried every helper wake in the same schedule window.

When a user saves an enabled scheduled profile, Delta requests Scheduled Backups registration through `SMAppService` if the helper is not already registered. If macOS reports that Login Items approval is still required, Delta records the schedule and surfaces the approval action instead of silently leaving scheduled backups inert.

When idle-sleep protection is enabled, Delta holds a macOS `ProcessInfo` activity assertion only around active restic jobs. This does not change restic command semantics and does not override the profile battery or Low Power Mode policy that is evaluated before scheduled work starts.

## Locking

Delta uses two lock layers:

1. A local cross-process per-destination lock to prevent overlapping Delta app/agent work.
2. restic repository locks for repository safety across all restic clients.

Delta maps restic lock exit code `11` and lock-related stderr to a user-facing busy message.

The shared SQLite database is opened with WAL journal mode and a busy timeout so the app and `DeltaAgent` can read/write job state without immediately failing during short concurrent writes.

If the app cannot open the Application Support database, backup, destination, browse, and restore actions are blocked. The app still opens far enough to show the storage error and retry, but it does not run restic jobs against temporary profile/job state.

On app or agent startup, Delta also reconciles any persisted `running` job rows. A job is marked interrupted only when Delta can acquire the destination's per-process lock, which proves no app/agent process currently owns that destination. If the lock is still held, the job remains running and the UI continues to observe it through SQLite/log polling.

Release smoke tests may set `DELTA_APP_SUPPORT_DIR` to point Delta and DeltaAgent at a temporary Application Support directory. Production launches do not set this variable, so normal app data remains under the user's Application Support folder. The release verifier uses the override to prove the packaged helper can open SQLite and run the real due-backup path without touching a developer's personal Delta data.

## Streaming Logs

`ResticRunner` streams stdout and stderr while the process is running. The coordinator records start, streamed output, and finish lines as per-job SQLite log entries, while the UI also receives the same live events for Activity output. Status JSON is additionally persisted as a compact structured progress snapshot on the running job row, so the app can reconstruct progress after relaunch or when a scheduled backup is owned by `DeltaAgent`. When a scheduled backup is started by `DeltaAgent`, the app polls the same SQLite job/log state so the dashboard, Activity page, and menu bar still show the active operation. Restic JSON status/error lines are formatted into readable messages before durable storage.

Active backups expose Pause and Cancel controls in the main window and macOS menu bar. For UI-owned jobs Delta uses the in-memory `ResticRunController`; for agent-owned jobs it writes a per-job stop request under Application Support and the runner checks that request while restic is alive. Pause sends restic a graceful interrupt, records the job as cancelled with a structured `.pause` stop reason, keeps the profile visibly paused, and shows Resume as the next primary action. Resume runs restic backup again, relying on restic's content-addressed storage so already written data is reused. Cancel uses the same safe interruption path for any active restic job, records a structured `.cancel` stop reason, and does not make the profile appear resumable. `Scripts/run-installed-run-control-acceptance.sh` proves those run-control semantics through the installed Delta executable with isolated SQLite state and durable stop-request files.

Relevant files:

- `Sources/DeltaCore/ResticRunner.swift`
- `Sources/DeltaCore/ResticRunControlStore.swift`
- `Sources/DeltaCore/ResticLogFormatter.swift`
- `Sources/DeltaCore/BackupCoordinator.swift`
- `Sources/DeltaCore/DeltaDatabase.swift`
- `Sources/Delta/DeltaAppModel.swift`

## Verification

Primary verification command:

```sh
Scripts/verify-release.sh
```

This runs:

- unit tests
- restic/rclone bootstrap and checksum verification
- bundled restic command, flag, and backend option surface verification for SFTP, REST, S3, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, and rclone
- external backend parser and credential-policy contract tests for mounted paths, SFTP, REST, S3-compatible, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, rclone, and custom restic URLs
- installed external backend preflight reporting for configured real-provider acceptance environments before destructive lifecycle runs
- production external acceptance evidence verification for a real mounted SMB/NFS destination, real SFTP destination, and real S3-compatible destination, rejecting localhost harness reports
- local restic integration test with real init/backup/restore, dry-run restore without writes, check, prune, and post-prune check
- backup source preflight coverage for moved, invalid, and unreadable source selections
- packaged app build
- codesign verification
- minimal hardened-runtime entitlement checks for Delta, DeltaAgent, DeltaSecretBridge, restic, and rclone
- same-executable scheduled password resolution and non-interactive password-bridge acceptance
- installed REST-server lifecycle acceptance through a temporary local `rclone serve restic` endpoint with Keychain-backed REST credentials
- installed SFTP, S3-compatible, and rclone backend lifecycle acceptance through deterministic localhost/local rclone harnesses
- Sparkle framework checks and signed appcast/update metadata
- scheduler smoke checks
- bundled restic/rclone version checks
