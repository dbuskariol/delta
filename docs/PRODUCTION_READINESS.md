# Delta Production Readiness

This checklist is the release gate for Delta. `Scripts/verify-release.sh` is the automated gate; the manual matrix covers macOS behaviors that cannot be proven reliably from unit tests alone.

## Automated Gate

Run from the repository root:

```sh
Scripts/verify-release.sh
```

Every push and pull request also runs `.github/workflows/ci.yml` on GitHub's macOS 26 runner. The workflow calls `Scripts/verify-ci.sh`, which is intentionally certificate-free: it runs tests, product-language checks, manual-matrix validators, tool verification, the local restic integration, an ad-hoc signed app build, code-signature validation, and Sparkle artifact verification. The local release gate remains stricter because it requires a stable Apple signing identity and installed-app acceptance checks.

The automated gate must pass before any beta or production build is shipped. It verifies:

- Swift unit tests
- pinned restic and rclone checksums
- product-language checks for user-facing app strings and Keychain wording
- manual acceptance matrix consistency between this document and the generated report source
- restic command and flag surface
- external backend parser and credential-policy contract coverage for mounted paths, SFTP, REST, S3-compatible, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, rclone, and custom restic URLs
- real local restic init, backup, incremental backup, full restore, selected restore, dry-run restore without writes, repository check, prune, and post-prune check
- installed Delta local lifecycle acceptance through the app coordinator, SQLite store, Keychain password command, bundled restic, newest-first restore-point cache, backup browser listing with nested file metadata, full restore, selected folder restore, selected file restore, dry-run restore with no writes, every overwrite policy, destination check, cleanup, post-cleanup check, post-cleanup cache refresh, and saved backup log source/summary evidence
- warning-free packaged app build
- codesign validation for Delta, DeltaAgent, DeltaSecretBridge, restic, rclone, and Sparkle
- non-ad-hoc app signing identity for stable macOS privacy permissions
- hardened-runtime entitlement hygiene
- same-executable scheduled password resolution and non-interactive password-bridge acceptance
- Password Access health diagnostics for saved destination passwords and backend credentials
- installed Scheduled Backups scheduler acceptance with an isolated due profile, automatic destination preparation, real backup, cached restore point refresh, and source-context log persistence
- installed status-menu surface acceptance for ready/running/attention/blocked state text, compact labels, Back Up Now, Run Due Backups, Pause, Stop, Activity, Updates, and forbidden terminology
- installed-app diagnostic export with redaction of seeded destination and backend credential values
- source access preflight before restic starts or a new destination is prepared
- installed run-control acceptance through the app coordinator, SQLite job store, durable stop-request files, resumable pause state, successful resume, and non-resumable cancel state
- installed mounted-volume lifecycle acceptance through a temporary APFS volume mounted under `/Volumes`, proving mounted-path preparation, backup, restore browsing, restore, check, cleanup, prune, and disappearance after unmount
- installed REST-server backend lifecycle acceptance through a temporary local `rclone serve restic` endpoint with Keychain-backed REST credentials
- installed S3-compatible backend lifecycle acceptance through a temporary local rclone S3 server with missing-credential and corrected-credential coverage
- installed SFTP backend lifecycle acceptance through a temporary localhost SFTP server with temporary host/client keys and non-interactive known_hosts
- installed rclone backend lifecycle acceptance through a temporary local rclone remote, proving automatic preparation, existing-destination reuse, backup, restore browsing, restore, check, cleanup, and prune via restic's `rclone:` backend
- bundled Login Item scheduler plist
- app launch smoke test
- DeltaAgent status, dry-run, and fail-closed argument smoke tests
- isolated DeltaAgent due-run smoke test using temporary Application Support data
- installed `/Applications/Delta.app` smoke verification when present
- Sparkle update archive, release notes, signed appcast enclosure, advertised file size, extracted bundle identity, extracted Sparkle settings, and extracted bundle code signature
- notarization workflow syntax and executable-bit hygiene

After the automated gate, collect a release evidence report:

```sh
Scripts/collect-release-evidence.sh
```

The automated gate writes `dist/release-evidence/automated-gate-status` when it passes. The release evidence report is written under `dist/release-evidence/`, with `dist/release-evidence/latest.md` pointing at the newest report, and records the exact app path, version, git commit, signature details, scheduler/tool smoke output, Sparkle update artifacts, installed app smoke output, Gatekeeper/notarization status, notarization credential policy, automated gate status, local acceptance probe output, and manual acceptance verification.

For a faster local readiness picture, run:

```sh
Scripts/run-local-acceptance-probe.sh
```

The probe writes `dist/local-acceptance/latest.md`. It also runs `Scripts/run-installed-keychain-access-acceptance.sh`, which creates a throwaway destination-secret item through the installed Delta app, proves the installed password bridge mode can read it without interaction, then deletes it. It runs `Scripts/run-installed-scheduled-agent-acceptance.sh`, which seeds an isolated due scheduled profile and proves the installed Scheduled Backups scheduler runs one real backup through the installed Delta executable without interactive Keychain prompts. It runs `Scripts/run-installed-diagnostics-acceptance.sh`, which seeds isolated installed-app state, exports diagnostics through the installed app, and proves seeded destination/backend credential values are redacted. It runs `Scripts/run-installed-preferences-acceptance.sh`, which verifies the signed app's shared Settings surface contract, required categories, compact status summary, recommended defaults, unsafe value normalization, custom backup defaults persisted to a new profile, custom restore defaults, diagnostic settings summaries, and restoration of existing preference values. It runs `Scripts/run-installed-menu-bar-surface-acceptance.sh`, which verifies the installed app's shared status-menu contract for ready/running/attention/blocked text, compact labels, Back Up Now, Run Due Backups, Pause, Stop, Activity, Updates, and forbidden terminology. It runs `Scripts/run-installed-run-control-acceptance.sh`, which launches the installed Delta app in run-control acceptance mode and verifies Delta's coordinator, SQLite job store, durable stop-request files, resumable pause state, successful resume, non-resumable cancel state, cleared stop requests, job logs, and restore-point refresh after resume. It runs `Scripts/run-installed-local-backup-acceptance.sh`, which launches the installed Delta app in local lifecycle acceptance mode and verifies Delta's coordinator, SQLite store, Keychain password command, bundled restic, automatic destination preparation, first backup, no-change backup, incremental backup, newest-first restore-point cache, backup browser listing with nested file metadata, full restore, selected folder restore, selected file restore, dry-run restore with no writes, every overwrite policy, destination check, cleanup, post-cleanup check, pruned restore-point cache refresh, and saved backup log source/summary evidence against a temporary encrypted local destination. It runs `Scripts/run-installed-mounted-volume-acceptance.sh`, which creates a temporary APFS volume mounted under `/Volumes` and proves the installed app can prepare, back up, browse, restore, check, clean up, prune, and observe that the mounted destination disappears after unmount. It runs `Scripts/run-installed-local-rest-acceptance.sh`, which starts a temporary local REST backend with bundled `rclone serve restic`, then proves the installed app can use Keychain-backed REST credentials, prepare, back up, browse, restore, check, clean up, and prune through restic's REST backend. It runs `Scripts/run-installed-local-s3-acceptance.sh`, which starts a temporary local S3-compatible endpoint with bundled rclone and proves the installed app can use Keychain-backed AWS credentials, reject missing credentials, prepare, back up, browse, restore, check, clean up, and prune through restic's S3 backend. It runs `Scripts/run-installed-local-sftp-acceptance.sh`, which starts a temporary localhost SFTP server and proves the installed app can use non-interactive key authentication, reject a wrong target, prepare, back up, browse, restore, check, clean up, and prune through restic's SFTP backend. It also runs `Scripts/run-installed-rclone-local-acceptance.sh`, which configures a temporary rclone local remote and proves the installed app can prepare, back up, browse, restore, check, clean up, and prune through restic's `rclone:` backend without depending on cloud credentials.

External backend evidence is opt-in because it needs real infrastructure. Configure these variables before running the local probe when those targets are available:

```sh
DELTA_ACCEPTANCE_MOUNTED_PATH=/Volumes/BackupShare
DELTA_ACCEPTANCE_SFTP_REPOSITORY='sftp:user@example.com:/srv/backups/delta-acceptance'
DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY="$HOME/.ssh/id_ed25519" # optional
DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY='sftp:user@example.com:/srv/backups/delta-acceptance-bad' # optional failure probe
DELTA_ACCEPTANCE_S3_REPOSITORY='s3:https://s3.example.com/bucket/delta-acceptance'
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
DELTA_ACCEPTANCE_B2_REPOSITORY='b2:bucket:delta-acceptance'
B2_ACCOUNT_ID=...
B2_ACCOUNT_KEY=...
DELTA_ACCEPTANCE_AZURE_REPOSITORY='azure:container:/delta-acceptance'
AZURE_ACCOUNT_NAME=...
AZURE_ACCOUNT_KEY=... # or AZURE_ACCOUNT_SAS
DELTA_ACCEPTANCE_GCS_REPOSITORY='gs:bucket:/delta-acceptance'
GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json # or GOOGLE_ACCESS_TOKEN
DELTA_ACCEPTANCE_SWIFT_REPOSITORY='swift:container:/delta-acceptance'
DELTA_ACCEPTANCE_RCLONE_REPOSITORY='rclone:remote:delta-acceptance'
RCLONE_CONFIG=/path/to/rclone.conf
DELTA_ACCEPTANCE_REST_REPOSITORY='rest:https://rest.example.com/delta-acceptance'
```

`DELTA_ACCEPTANCE_MOUNTED_PATH` must be a mounted network filesystem under `/Volumes`, such as SMB or NFS. Local external disks are covered by installed local lifecycle acceptance, and deterministic mounted-volume behavior is covered by `Scripts/run-installed-mounted-volume-acceptance.sh`; neither substitutes for real SMB/NFS disconnect and reconnect acceptance.

The external harness requires remote URLs to include `delta-acceptance` unless `DELTA_ACCEPTANCE_ALLOW_EXISTING_REMOTE=1` is set after a human confirms the target is safe. It launches the installed Delta app in external lifecycle acceptance mode, then proves the coordinator, isolated SQLite store, Keychain password command, bundled restic, automatic destination preparation, existing-destination reuse, first backup, deduplicated no-change backup, restore-point cache, restore browser listing, full restore, selected-folder restore, check, prune, and post-prune check against the configured mounted, real SFTP, real S3-compatible, REST, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, real rclone, or custom restic backend. Credentialed backend acceptance stores provider environment values as Delta Keychain credential references; S3 acceptance also proves missing-credential failure, and SFTP can prove wrong-target or wrong-credential failure when `DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY` is configured. The deterministic mounted-volume, local REST, local S3-compatible, localhost SFTP, and rclone local-remote harnesses are required by the release gate, but they are not substitutes for testing the actual SMB/NFS server, third-party server, cloud, or storage service behind production destinations.

The probe only marks machine-verifiable evidence as automated or partial evidence. It can record the installed app's own Full Disk Access diagnostic result, but it intentionally keeps Full Disk Access approval, macOS Login Items approval, closed-window schedule visibility, UI disconnect/reconnect behavior, menu bar visual interaction, Notification Center delivery, Sparkle install flow, and notarization as explicit manual follow-up where a shell process would give weak or misleading evidence.

After manual acceptance, Developer ID notarization, and local installation of the exact release candidate, run the external distribution gate:

```sh
Scripts/verify-production-readiness.sh
```

This gate fails unless the automated gate passed for the current git commit, the manual acceptance report passes for the same commit, the app is signed with Developer ID, the notarization ticket is stapled and accepted by Gatekeeper, notarization logs are archived, `/Applications/Delta.app` matches the verified app, installed-app smoke verification passes, and the regenerated release evidence says the build is ready for external distribution.

To inspect those prerequisites before running the hard gate, use:

```sh
Scripts/doctor-production-readiness.sh
```

The doctor reports signing identity availability, automated-gate freshness, installed-app identity, notarization and Gatekeeper status, local/manual acceptance state, and configured external backend acceptance targets. It exits non-zero while production blockers remain; set `DELTA_DOCTOR_ALLOW_BLOCKERS=1` to collect the report without failing the shell.

## Notarization Gate

External distribution builds must be notarized after the automated gate passes:

```sh
DELTA_CODESIGN_IDENTITY="Developer ID Application: Example" Scripts/verify-release.sh
DELTA_NOTARY_KEYCHAIN_PROFILE="Delta Notary" Scripts/notarize-release.sh
```

`Scripts/notarize-release.sh` requires a Developer ID Application signature, submits the app archive with `xcrun notarytool`, waits for the result, saves the submission and notary logs under `dist/notarization`, staples the ticket, validates the stapled app with `xcrun stapler` and `spctl`, then regenerates the Sparkle archive and appcast from the stapled app.

Notarization credentials must be supplied through a stored `notarytool` keychain profile. Raw Apple ID, team ID, or app-specific password environment-variable fallbacks are intentionally unsupported so release automation does not keep notarization secrets in shell state or pass them as long-lived process arguments.

## Manual macOS Acceptance Matrix

Record the app version, build number, macOS build, signing identity, date, and tester for each run.

Create an editable report from the canonical matrix:

```sh
Scripts/create-manual-acceptance-report.sh
```

If `dist/local-acceptance/latest.md` exists, the generated manual report copies each row's local probe status into Evidence / Notes, appends `Manual evidence: TODO`, and leaves Result as `Not run`. Fill in `dist/manual-acceptance/latest.md` as each check is performed. Use exactly `Passed`, `Failed`, `Blocked`, or `Not run` in the Result column. A `Passed` row must replace generated local-probe and follow-up text with real observed manual evidence. Verify the report before external beta distribution:

```sh
Scripts/verify-manual-acceptance.sh
```

Use the local acceptance probe report as supporting evidence while filling this matrix, but do not convert `Partial` probe rows into manual `Passed` rows until the requested human interaction or provider test has actually been completed.

| Area | Required evidence |
| --- | --- |
| Install identity and privacy stability | Install /Applications/Delta.app, launch it, quit, relaunch, and confirm macOS privacy prompts remain stable across rebuilds signed by the same identity. |
| Settings surface | Confirm Settings shows plain-language Scheduled Backups status, not raw LaunchAgent or implementation status; the compact status summary matches Full Disk Access, schedules, Pause automatic runs, Password Access, updates, notifications, idle-sleep protection, and bundled backup-tool state; expand How Scheduled Backups Work and confirm it explains closed-window scheduling, macOS approval, user-level permissions, and policy checks without raw implementation status; Password Access exposes status, refresh, and Repair Password Access; Run Due Now uses the same rules as automatic scheduled runs when they are not paused; Start at Login uses macOS Login Items separately from scheduled backups; Sparkle automatic checks and background downloads are configurable; reset buttons restore recommended backup and restore defaults; backup freshness warnings, source-access warnings, destination-check warnings, local/mounted destination free-space warnings, and activity history retention are configurable or visible where appropriate. |
| Full Disk Access | From Settings, open Privacy & Security, add Delta manually when required, recheck access, and confirm the dashboard only shows Readiness when action is needed. |
| Scheduled Backups | Confirm the automated scheduler acceptance report passed, then create an enabled scheduled profile in the UI, approve Delta in Login Items if macOS asks, turn on Pause automatic runs and confirm due runs do not start, resume automatic runs, quit the main window, wait for the scheduler interval, and confirm the scheduled run appears in Dashboard, Activity, and menu bar state after relaunch. |
| Password access | Use an app-managed destination and a destination with backend credentials. Confirm Settings and diagnostics show Password Access as Ready, then confirm a scheduled backup does not show interactive Keychain prompts after Repair Password Access has been run when needed. |
| Local or external drive destination | Create a new local or external-drive destination, confirm automatic preparation runs, then run a first backup and a second no-change backup. |
| Mounted SMB or NFS destination | Test at least one SMB or NFS mounted path under /Volumes, disconnect it, confirm Delta reports destination unavailable without invoking restic, reconnect it, and confirm backup resumes. Also test an unwritable mounted destination and confirm Delta fails the write probe before invoking restic. |
| SFTP destination | Test a real SFTP destination with a non-root absolute path and non-interactive SSH authentication through a configured key file or ssh-agent; confirm wrong credential/key failure, corrected credential success, restore point refresh, and restore. |
| S3-compatible destination | Test at least one S3-compatible provider with endpoint, bucket, optional region, missing credential failure, corrected credential success, backup, check, and restore. |
| Additional restic remote backends | Test REST server, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, rclone, and custom restic URL destinations with provider-specific credentials/configuration; confirm backup, check, restore point refresh, selected restore, cleanup, and post-cleanup check. |
| Remote first-backup preparation | Add a new unprepared remote destination, start a backup without pressing Prepare first, and confirm Delta probes, prepares when missing, then runs the backup. Repeat with an existing remote destination and confirm Delta reuses it without reinitializing. |
| Restore wizard | Test full restore, selected folder restore from the browser, selected file restore, dry-run preview, chosen-folder restore, original-path preview, original-path confirmation, and every overwrite policy. |
| Restore defaults | Change Settings > Restore Defaults, reopen Restore, and confirm preview, verification, and overwrite policy defaults apply while remaining editable per restore. |
| New backup defaults | Change Settings > New Backup Defaults, create a new profile, and confirm catch-up, battery, Low Power Mode, bandwidth, retention keep rules, prune, post-cleanup check, and cleanup cadence defaults are applied while existing profiles remain unchanged. Confirm Health Monitoring thresholds change dashboard attention timing, destination-check timing, and local/mounted destination free-space warnings without mutating profiles. |
| Browse restore points | Confirm restore points load when the Restore tab is selected, refresh returns all current points, pruned points disappear after cleanup, and newest points are listed first. |
| Pause, resume, and cancel | Start a large backup, pause it from the main app and menu bar, confirm the profile stays paused with Resume visible, resume it, then cancel a separate run and confirm it is not resumable. |
| Streaming and saved logs | Confirm live logs stay in a fixed-height scrolling pane, auto-scroll to the bottom, include source context, and saved logs are grouped by expandable job. |
| Menu bar status item and persistent popover | Confirm the native status item appears when enabled, hides when disabled, changes icon for ready, running, and attention states, and keeps its popover open while a backup transitions from running to completed. Confirm Back Up Now, Run Due Backups, Pause, Stop, Activity, Updates, and last-backup status work from the popover. |
| Notifications | Enable job alerts in Settings, allow macOS notification permission, use Send Test Alert, trigger one warning or failed job from the app and one scheduled job, and confirm successful-backup summaries only appear when the separate success setting is enabled. |
| Sparkle update install | Install an older signed build, host or publish a signed appcast and archive, check for updates, install the update, and confirm settings, Full Disk Access identity, destinations, profiles, restore points, and scheduled behavior remain intact. |
| Diagnostics export redaction | Copy and export a diagnostic report and confirm it contains app, scheduler, tool, profile, and job state but no destination password or backend credential values. |
| Developer ID notarization | For release builds only, sign with Developer ID, submit for notarization, staple the ticket, verify Gatekeeper launch, and archive notarization logs. |

## Release Decision

A build can move from local beta to external beta only when:

- `Scripts/verify-release.sh` passes on a clean checkout.
- The manual matrix has current passing evidence for the targeted macOS release.
- Any accepted limitations are documented in `README.md`.
- Notarization is complete for external distribution builds.
- `Scripts/verify-production-readiness.sh` passes.
