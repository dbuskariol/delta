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
- restic command and flag surface
- real local restic init, backup, incremental backup, full restore, selected restore, repository check, prune, and post-prune check
- packaged app build
- codesign validation for Delta, DeltaAgent, DeltaSecretBridge, restic, rclone, and Sparkle
- hardened-runtime entitlement hygiene
- bundled Login Item helper plist
- app launch smoke test
- DeltaAgent smoke test
- Sparkle update archive and signed appcast metadata

## Manual macOS Acceptance Matrix

Record the app version, build number, macOS build, signing identity, date, and tester for each run.

| Area | Required evidence |
| --- | --- |
| Install identity | Install `/Applications/Delta.app`, launch it, quit, relaunch, and confirm macOS privacy prompts remain stable across rebuilds signed by the same identity. |
| Full Disk Access | From Settings, open Privacy & Security, add Delta manually when required, recheck access, and confirm the dashboard only shows Readiness when action is needed. |
| Background Backups | Create an enabled scheduled profile, approve Delta in Login Items if macOS asks, quit the main window, wait for the helper interval, and confirm the scheduled run appears in Dashboard, Activity, and menu bar state after relaunch. |
| Keychain background access | Use an app-managed destination and a destination with backend credentials. Confirm a scheduled backup does not show interactive Keychain prompts after Repair Keychain Access has been run when needed. |
| Local drive destination | Create a new local or external-drive destination, confirm automatic preparation runs, then run a first backup and a second no-change backup. |
| Mounted network drive | Test at least one SMB or NFS mounted path under `/Volumes`, disconnect it, confirm Delta reports destination unavailable without invoking restic, reconnect it, and confirm backup resumes. |
| SFTP destination | Test a real SFTP destination with a non-root absolute path, wrong credential failure, corrected credential success, restore point refresh, and restore. |
| S3-compatible destination | Test at least one S3-compatible provider with endpoint, bucket, optional region, missing credential failure, corrected credential success, backup, check, and restore. |
| Remote first backup preparation | Add a new unprepared remote destination, start a backup without pressing Prepare first, and confirm Delta probes, prepares when missing, then runs the backup. Repeat with an existing remote destination and confirm Delta reuses it without reinitializing. |
| Restore wizard | Test full restore, selected folder restore from the browser, selected file restore, dry-run preview, chosen-folder restore, original-path preview, original-path confirmation, and every overwrite policy. |
| Restore defaults | Change Settings > Restore Defaults, reopen Restore, and confirm preview, verification, and overwrite policy defaults apply while remaining editable per restore. |
| New backup defaults | Change Settings > New Backup Defaults, create a new profile, and confirm catch-up, battery, Low Power Mode, prune, and post-cleanup check defaults are applied while existing profiles remain unchanged. |
| Browse restore points | Confirm restore points load when the Restore tab is selected, refresh returns all current points, pruned points disappear after cleanup, and newest points are listed first. |
| Pause, resume, cancel | Start a large backup, pause it from the main app and menu bar, confirm the profile stays paused with Resume visible, resume it, then cancel a separate run and confirm it is not resumable. |
| Streaming logs | Confirm live logs stay in a fixed-height scrolling pane, auto-scroll to the bottom, include source context, and saved logs are grouped by expandable job. |
| Menu bar | Confirm Back Up Now, Run Due Backups, Pause, Stop, Activity, Updates, last backup status, and status transitions work without the menu closing unexpectedly on completion. |
| Notifications | Enable job alerts in Settings, allow macOS notification permission, trigger one warning/failed job from the app and one scheduled helper job, and confirm successful-backup summaries only appear when the separate success setting is enabled. |
| Sparkle updates | Install an older signed build, host or publish a signed appcast and archive, check for updates, install the update, and confirm settings, Full Disk Access identity, destinations, profiles, restore points, and scheduled helper behavior remain intact. |
| Diagnostics | Copy and export a diagnostic report and confirm it contains app/helper/tool/profile/job state but no repository password or backend credential values. |
| Notarization | For release builds only, sign with Developer ID, submit for notarization, staple the ticket, verify Gatekeeper launch, and archive notarization logs. |

## Release Decision

A build can move from local beta to external beta only when:

- `Scripts/verify-release.sh` passes on a clean checkout.
- The manual matrix has current passing evidence for the targeted macOS release.
- Any accepted limitations are documented in `README.md`.
- Notarization is complete for external distribution builds.
