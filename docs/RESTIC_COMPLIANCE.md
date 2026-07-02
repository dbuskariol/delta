# Restic Compliance Notes

Delta uses restic as the backup engine. This document maps Delta behavior to restic commands, options, backend syntax, and expected exit handling.

## Version

Bundled restic is pinned in `Resources/Tools/tools.json` and installed by `Scripts/bootstrap-tools.sh`.

The verifier checks:

```sh
Resources/Tools/bin/restic version
Resources/Tools/bin/rclone version
```

## Repository Passwords

Delta uses restic `--password-command`.

The command points at `DeltaSecretBridge`, which reads the destination password from Keychain and writes it to stdout for restic. Delta does not pass repository passwords through long-lived environment variables or command-line literals.

App-managed destinations use a generated Keychain password. User-managed passphrase destinations require confirmation before the password is stored.

Relevant files:

- `Sources/DeltaCore/ResticCommand.swift`
- `Sources/DeltaSecretBridge/main.swift`
- `Sources/DeltaCore/KeychainSecretStore.swift`

## Backends

Delta supports the following restic backend families:

| Destination type | Restic URL shape |
| --- | --- |
| Local/mounted path | `/Volumes/Backup/Delta` |
| SFTP | `sftp:user@host:/path` |
| SFTP with port/IPv6 | `sftp://user@host:2222//absolute/path` |
| REST server | `rest:https://host:8000/repo` |
| S3-compatible | `s3:https://server:port/bucket/path` |
| Backblaze B2 | `b2:bucket:path/to/repo` |
| Azure Blob | `azure:container:/path` |
| Google Cloud Storage | `gs:bucket:/path` |
| OpenStack Swift | `swift:container:/path` |
| rclone | `rclone:remote:path` |
| Custom | User-supplied restic URL |

URL construction is covered by `ResticCommandTests`.

Delta validates destination inputs before saving them. The validator trims persisted fields, requires writable new or changed local destinations or writable parents, rejects relative local paths in the native destination form, requires absolute SFTP paths and valid ports, validates REST URLs as `http` or `https`, and rejects rclone remote names that already include a colon. Advanced raw restic URLs remain available through the custom destination type.

After a destination is created, Delta starts a prepare job that runs `restic init` with the saved encryption secret and backend credentials. The destination row action remains available as a retry path. For local and mounted destinations, Delta also keeps a first-backup safety net: if the writable destination has no restic `config` file yet, it runs `restic init` before starting backup.

## Backend Credentials

Backend credentials are stored in Keychain and injected into a curated restic process environment only for the job run. Keychain items are created with a trusted-application access list for the signed Delta app, DeltaAgent, and DeltaSecretBridge so scheduled jobs do not require interactive Keychain approval. Delta forwards operational values such as `PATH`, `HOME`, `TMPDIR`, locale, and `SSH_AUTH_SOCK`, but does not pass arbitrary ambient environment variables to restic.

Supported credential templates include:

- REST: `RESTIC_REST_USERNAME`, `RESTIC_REST_PASSWORD`
- S3: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- Backblaze B2: `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`
- Azure Blob: `AZURE_ACCOUNT_NAME`, `AZURE_ACCOUNT_KEY`, `AZURE_ACCOUNT_SAS`, `AZURE_ENDPOINT_SUFFIX`
- Google Cloud Storage: `GOOGLE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_ACCESS_TOKEN`
- OpenStack Swift: Keystone, token, and Swift object storage variables
- rclone: `RCLONE_CONFIG`, `RCLONE_BWLIMIT`, `RCLONE_VERBOSE`

S3 region is passed as an explicit restic backend option:

```text
-o s3.region=<region>
```

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

Delta adds macOS-safe excludes and excludes the local destination path when the destination is inside a local filesystem path.

Expected restic backup exit handling:

| Exit code | Delta state |
| --- | --- |
| `0` | Succeeded |
| `3` | Warning, incomplete snapshot due to unreadable source data |
| `10` | Destination not prepared/found |
| `11` | Destination locked |
| `12` | Wrong password |
| other non-zero | Failed or cancelled when interruption text is present |

Restic progress totals can change while it scans sources, so Delta does not render volatile live percentages as stable completion. The UI uses an indeterminate active-job bar with stable processed-file and processed-byte counters, backup jobs record source paths at job start, and saved logs are grouped by job with expandable full-log loading from SQLite.

## Snapshots / Restore Points

Delta lists restore points with:

```text
snapshots --json
```

The JSON parser is covered by unit tests.

Delta browses files and folders inside a selected restore point with:

```text
ls --json --sort name <snapshot-id> <absolute-directory-path>
```

The UI starts from the restore point's backed-up source roots and loads one directory at a time. Delta does not recursively dump a full-volume backup into app memory just to render the browser. `ls --json` output is parsed as newline-delimited restic node records; non-node records are ignored.

## Restore

Delta restore commands use:

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

Scheduled maintenance is evaluated independently from backup due checks, but it uses the same profile, destination, power policy, and per-destination locking path.

## Locking

Delta uses two lock layers:

1. A local cross-process per-destination lock to prevent overlapping Delta app/agent work.
2. restic repository locks for repository safety across all restic clients.

Delta maps restic lock exit code `11` and lock-related stderr to a user-facing busy message.

## Streaming Logs

`ResticRunner` streams stdout and stderr while the process is running. The coordinator records start, streamed output, and finish lines as per-job SQLite log entries, while the UI also receives the same live events for Activity output. Restic JSON status/error lines are formatted into readable messages before durable storage.

Active backups expose Pause and Cancel controls. Pause sends restic a graceful interrupt, records the job as cancelled with a paused message, keeps the profile visibly paused, and shows Resume as the next primary action. Resume runs restic backup again, relying on restic's content-addressed storage so already written data is reused. Cancel uses the same safe interruption path for any active restic job and records a cancelled job instead of a failed job.

Relevant files:

- `Sources/DeltaCore/ResticRunner.swift`
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
- local restic integration test with real init/backup/restore
- packaged app build
- codesign verification
- Sparkle framework checks
- helper smoke checks
- bundled restic/rclone version checks
