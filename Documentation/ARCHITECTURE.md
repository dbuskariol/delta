# Delta Architecture

Delta is a native macOS 26 application around restic's encrypted repository format. The app owns user interaction, policy, local state, secrets, scheduling, and release/update trust; restic owns backup storage, snapshot creation, restore, retention, pruning, and integrity checks.

## Process model

| Process | Lifetime and boundary |
| --- | --- |
| `Delta` | User-facing SwiftUI/AppKit process. It edits configuration, coordinates interactive work, observes scheduled work, and hosts the Sparkle updater. |
| `DeltaAgent` | Short-lived Service Management agent. It wakes at a bounded interval, execs the main Delta executable for due-work evaluation, and exits. |
| `DeltaSecretBridge` | Restricted compatibility executable for noninteractive Keychain access. Normal scheduled password resolution uses the main app executable so Keychain trust follows one signed identity. |
| `restic` | Bundled child process with a curated environment. It never receives a destination password in command-line arguments or the ambient process environment. |
| `rclone` | Bundled optional transport selected by restic for configured rclone destinations. |

The main app and agent share `DeltaCore`; there is no network service, privileged helper, kernel extension, or root daemon.

## Data flow

1. A native file picker records security-scoped bookmarks for selected sources, destinations, and restore targets.
2. Delta stores profile, destination, job, log, issue, and restore-point metadata in SQLite through GRDB.
3. Destination passwords and provider credentials are stored as generic-password items in the login Keychain.
4. Before work begins, Delta validates the profile, resolves source bookmarks, checks destination availability, and acquires a cross-process destination lock.
5. `ResticCommandBuilder` constructs a command and a curated environment. Passwords are supplied through a signed password command or short-lived standard input.
6. `ResticRunner` streams UTF-8-safe stdout/stderr, maps exit states, redacts sensitive values, applies command-specific bounded capture, and persists bounded operational history. Complete structured responses fail closed if their parsing limit is exceeded; long-running operational commands retain their final output tail.
7. Successful backup or cleanup work refreshes the authoritative restore-point cache from restic.

## Persistence

`~/Library/Application Support/Delta` contains the SQLite database, operational logs, process locks, and run-control requests. This is replaceable application state, not backup data. The encrypted backup repository remains at the destination selected by the user.

User preferences use Delta's own defaults domain. Secrets use Keychain service `com.delta.backup.destination-secrets`. The app does not write credentials to SQLite, logs, diagnostics, temporary password files, release artifacts, or command arguments.

## Concurrency and failure handling

SQLite uses WAL mode and a busy timeout so the app and scheduled process can coordinate safely. A local file lock serializes Delta work per destination, while restic's repository locks protect against other clients. Persisted running jobs are marked interrupted only after Delta proves that no process still owns the local destination lock.

Operations fail closed on invalid profiles, inaccessible sources, missing credentials, an unavailable destination, a busy repository, or unavailable application state. Restore-to-original-location and in-place overwrite paths require explicit confirmation.

Scheduled notification submission is part of the short-lived agent lifecycle. After a due job finishes, the command-line process waits for `UNUserNotificationCenter` to acknowledge each eligible request, with a bounded five-second timeout; submission failures and timeouts are recorded as warning events before the agent exits.

## Update and distribution trust

Delta embeds a product-specific Sparkle EdDSA public key and requires a signed feed plus verification before extraction. Release artifacts are universal `arm64` + `x86_64`, signed inside-out with Developer ID, use Hardened Runtime and secure timestamps, and are notarized by Apple. The app archive and DMG are notarized separately; both are stapled and Gatekeeper-assessed before publication.

The release manifest binds public artifact hashes, executable hashes, version/build, architectures, minimum system version, and Git commit. dSYMs and Apple notarization evidence remain private.
