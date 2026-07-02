# Delta Production Readiness

This checklist is the release gate for Delta. `Scripts/verify-release.sh` is the automated gate; the manual matrix covers macOS behaviors that cannot be proven reliably from unit tests alone.

## Automated Gate

Run from the repository root:

```sh
Scripts/verify-release.sh
```

The automated gate must pass before any beta or production build is shipped. It verifies:

- Swift unit tests
- pinned restic and rclone checksums
- product-language checks for user-facing app strings and Keychain wording
- restic command and flag surface
- real local restic init, backup, incremental backup, full restore, selected restore, dry-run restore without writes, repository check, prune, and post-prune check
- warning-free packaged app build
- codesign validation for Delta, DeltaAgent, DeltaSecretBridge, restic, rclone, and Sparkle
- non-ad-hoc app signing identity for stable macOS privacy permissions
- hardened-runtime entitlement hygiene
- same-executable scheduled password resolution and non-interactive password-bridge acceptance
- bundled Login Item helper plist
- app launch smoke test
- DeltaAgent status, dry-run, and fail-closed argument smoke tests
- isolated DeltaAgent due-run smoke test using temporary Application Support data
- installed `/Applications/Delta.app` smoke verification when present
- Sparkle update archive and signed appcast metadata
- notarization workflow syntax and executable-bit hygiene

After the automated gate, collect a release evidence report:

```sh
Scripts/collect-release-evidence.sh
```

The automated gate writes `dist/release-evidence/automated-gate-status` when it passes. The release evidence report is written under `dist/release-evidence/` and records the exact app path, version, git commit, signature details, helper/tool smoke output, Sparkle update artifacts, installed app smoke output, Gatekeeper/notarization status, automated gate status, local acceptance probe output, and manual acceptance verification.

For a faster local readiness picture, run:

```sh
Scripts/run-local-acceptance-probe.sh
```

The probe writes `dist/local-acceptance/latest.md`. It also runs `Scripts/run-installed-keychain-access-acceptance.sh`, which creates a throwaway destination-secret item through the installed Delta app, proves the installed password bridge mode can read it without interaction, then deletes it. It also runs `Scripts/run-installed-local-backup-acceptance.sh`, which uses the app bundle's own restic binary to initialize a temporary encrypted local destination, run first and deduplicated second backups, restore a full restore point, restore a selected folder, check, prune, and run a post-prune check.

External backend evidence is opt-in because it needs real infrastructure. Configure these variables before running the local probe when those targets are available:

```sh
DELTA_ACCEPTANCE_MOUNTED_PATH=/Volumes/BackupShare
DELTA_ACCEPTANCE_SFTP_REPOSITORY='sftp:user@example.com:/srv/backups/delta-acceptance'
DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY="$HOME/.ssh/id_ed25519" # optional
DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY='sftp:user@example.com:/srv/backups/delta-acceptance-bad' # optional failure probe
DELTA_ACCEPTANCE_S3_REPOSITORY='s3:https://s3.example.com/bucket/delta-acceptance'
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

The external harness requires remote URLs to include `delta-acceptance` unless `DELTA_ACCEPTANCE_ALLOW_EXISTING_REMOTE=1` is set after a human confirms the target is safe. It proves unprepared-destination failure, preparation, existing-destination reuse, first backup, deduplicated no-change backup, full restore, selected-folder restore, check, prune, and post-prune check. S3 acceptance also proves missing-credential failure; SFTP can prove wrong-target or wrong-credential failure when `DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY` is configured.

The probe only marks machine-verifiable evidence as automated or partial evidence. It intentionally keeps Full Disk Access, closed-window schedule behavior, UI disconnect/reconnect behavior, menu bar interaction, notifications, Sparkle install flow, and notarization as explicit manual follow-up where a shell process would give weak or misleading evidence.

After manual acceptance, Developer ID notarization, and local installation of the exact release candidate, run the external distribution gate:

```sh
Scripts/verify-production-readiness.sh
```

This gate fails unless the automated gate passed for the current git commit, the manual acceptance report passes for the same commit, the app is signed with Developer ID, the notarization ticket is stapled and accepted by Gatekeeper, notarization logs are archived, `/Applications/Delta.app` matches the verified app, installed-app smoke verification passes, and the regenerated release evidence says the build is ready for external distribution.

## Notarization Gate

External distribution builds must be notarized after the automated gate passes:

```sh
DELTA_CODESIGN_IDENTITY="Developer ID Application: Example" Scripts/verify-release.sh
DELTA_NOTARY_KEYCHAIN_PROFILE="Delta Notary" Scripts/notarize-release.sh
```

`Scripts/notarize-release.sh` requires a Developer ID Application signature, submits the app archive with `xcrun notarytool`, waits for the result, saves the submission and notary logs under `dist/notarization`, staples the ticket, validates the stapled app with `stapler` and `spctl`, then regenerates the Sparkle archive and appcast from the stapled app.

## Manual macOS Acceptance Matrix

Record the app version, build number, macOS build, signing identity, date, and tester for each run.

Create an editable report from the canonical matrix:

```sh
Scripts/create-manual-acceptance-report.sh
```

If `dist/local-acceptance/latest.md` exists, the generated manual report copies each row's local probe status into Evidence / Notes while leaving Result as `Not run`. Fill in `dist/manual-acceptance/latest.md` as each check is performed. Use exactly `Passed`, `Failed`, `Blocked`, or `Not run` in the Result column. Verify the report before external beta distribution:

```sh
Scripts/verify-manual-acceptance.sh
```

Use the local acceptance probe report as supporting evidence while filling this matrix, but do not convert `Partial` probe rows into manual `Passed` rows until the requested human interaction or provider test has actually been completed.

| Area | Required evidence |
| --- | --- |
| Install identity | Install `/Applications/Delta.app`, launch it, quit, relaunch, and confirm macOS privacy prompts remain stable across rebuilds signed by the same identity. |
| Settings surface | Confirm Settings shows plain-language Background Backups, not raw helper status; the compact status summary matches Full Disk Access, schedules, updates, notifications, and bundled backup-tool state; Start at Login uses macOS Login Items separately from scheduled backups; reset buttons restore recommended backup and restore defaults; backup freshness warnings, destination-check warnings, and activity history retention are configurable. |
| Full Disk Access | From Settings, open Privacy & Security, add Delta manually when required, recheck access, and confirm the dashboard only shows Readiness when action is needed. |
| Background Backups | Create an enabled scheduled profile, approve Delta in Login Items if macOS asks, quit the main window, wait for the helper interval, and confirm the scheduled run appears in Dashboard, Activity, and menu bar state after relaunch. |
| Keychain background access | Use an app-managed destination and a destination with backend credentials. Confirm a scheduled backup does not show interactive Keychain prompts after Repair Password Access has been run when needed. |
| Local drive destination | Create a new local or external-drive destination, confirm automatic preparation runs, then run a first backup and a second no-change backup. |
| Mounted network drive | Test at least one SMB or NFS mounted path under `/Volumes`, disconnect it, confirm Delta reports destination unavailable without invoking restic, reconnect it, and confirm backup resumes. |
| SFTP destination | Test a real SFTP destination with a non-root absolute path and non-interactive SSH authentication through a configured key file or ssh-agent; confirm wrong credential/key failure, corrected credential success, restore point refresh, and restore. |
| S3-compatible destination | Test at least one S3-compatible provider with endpoint, bucket, optional region, missing credential failure, corrected credential success, backup, check, and restore. |
| Remote first backup preparation | Add a new unprepared remote destination, start a backup without pressing Prepare first, and confirm Delta probes, prepares when missing, then runs the backup. Repeat with an existing remote destination and confirm Delta reuses it without reinitializing. |
| Restore wizard | Test full restore, selected folder restore from the browser, selected file restore, dry-run preview, chosen-folder restore, original-path preview, original-path confirmation, and every overwrite policy. |
| Restore defaults | Change Settings > Restore Defaults, reopen Restore, and confirm preview, verification, and overwrite policy defaults apply while remaining editable per restore. |
| New backup defaults | Change Settings > New Backup Defaults, create a new profile, and confirm catch-up, battery, Low Power Mode, bandwidth, prune, post-cleanup check, and cleanup cadence defaults are applied while existing profiles remain unchanged. Confirm Health Monitoring thresholds change dashboard attention timing without mutating profiles. |
| Browse restore points | Confirm restore points load when the Restore tab is selected, refresh returns all current points, pruned points disappear after cleanup, and newest points are listed first. |
| Pause, resume, cancel | Start a large backup, pause it from the main app and menu bar, confirm the profile stays paused with Resume visible, resume it, then cancel a separate run and confirm it is not resumable. |
| Streaming logs | Confirm live logs stay in a fixed-height scrolling pane, auto-scroll to the bottom, include source context, and saved logs are grouped by expandable job. |
| Menu bar | Confirm the native status item appears when enabled, hides when disabled, changes icon for ready, running, and attention states, and keeps its popover open while a backup transitions from running to completed. Confirm Back Up Now, Run Due Backups, Pause, Stop, Activity, Updates, and last-backup status work from the popover. |
| Notifications | Enable job alerts in Settings, allow macOS notification permission, trigger one warning/failed job from the app and one scheduled helper job, and confirm successful-backup summaries only appear when the separate success setting is enabled. |
| Sparkle updates | Install an older signed build, host or publish a signed appcast and archive, check for updates, install the update, and confirm settings, Full Disk Access identity, destinations, profiles, restore points, and scheduled helper behavior remain intact. |
| Diagnostics | Copy and export a diagnostic report and confirm it contains app/helper/tool/profile/job state but no destination password or backend credential values. |
| Notarization | For release builds only, sign with Developer ID, submit for notarization, staple the ticket, verify Gatekeeper launch, and archive notarization logs. |

## Release Decision

A build can move from local beta to external beta only when:

- `Scripts/verify-release.sh` passes on a clean checkout.
- The manual matrix has current passing evidence for the targeted macOS release.
- Any accepted limitations are documented in `README.md`.
- Notarization is complete for external distribution builds.
- `Scripts/verify-production-readiness.sh` passes.
