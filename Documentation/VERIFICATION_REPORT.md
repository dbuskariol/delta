# Delta Verification Report

Date: 16 July 2026
Host: macOS 26.5.2 (25F84)
Version: 0.2.0 (2)
Repository base: `dca5208`; the verified changes are prepared together for the release-readiness pull request

## Outcome

The current Delta source passes its complete certificate-free CI gate, builds as a universal Developer ID application, installs with the intended stable identity, and passes the deterministic installed-app acceptance suite. Real local backup, cleanup, check, dry-run restore, full restore, selected restore, relaunch, update-check, and no-change backup workflows were exercised through the native UI. Restored fixture files matched their sources by SHA-256.

This candidate is **not ready for external production distribution**. The release rehearsal and manual matrix are not yet bound to the final merged release commit, genuine external SMB/NFS, SFTP, and S3 infrastructure is not configured, and the candidate has not been notarized or stapled. The final production-readiness gate correctly remains fail closed.

## Implemented and reviewed changes

- Aligned onboarding and empty states around one primary action, removing duplicate page and empty-state controls. Dashboard, Backups, and Restore now open destination creation directly.
- Replaced Restore's disabled first-run form and Activity's competing split placeholders with single, focused empty states.
- Added native macOS Settings and Navigate commands: Command-comma opens Delta's in-window Settings, while Command-1 through Command-5 select the primary sections.
- Added explicit confirmation before cleanup permanently forgets restore points and prunes unreferenced data.
- Prevented a second background job from starting while Delta already owns active work.
- Made child-process streaming safe when UTF-8 characters span pipe reads.
- Added bounded, command-aware stdout/stderr capture. Complete structured output fails closed if it exceeds its parsing limit; operational commands retain a bounded tail with final diagnostics.
- Replaced oversized streamed lines with a safe omission marker while allowing later output to continue.
- Summarized retention and unknown structured arrays instead of echoing unneeded username, hostname, tag, or snapshot metadata into Activity.
- Corrected generic operation summaries to count `items`, avoiding false file counts when directories are included.
- Hardened the stable-app installer with bundle, minimum-system, team, designated-requirement, same-volume staging, rollback, and post-install verification.
- Expanded the CI gate with script syntax, helper type-checking, plist/privacy linting, metadata-derived version checks, and working-tree whitespace validation.
- Added repository-wide `AGENTS.md`, a screenshot-led README, current release notes, architecture/compliance updates, and privacy-safe screenshots.

## Automated verification

### Complete repository gate

Command:

```sh
Scripts/verify-ci.sh
```

Result: passed.

- 323 Swift tests executed, 1 intentional skip, 0 failures.
- Enabled real `ResticIntegrationTests` lifecycle passed.
- Product-language and crash-marker scans passed.
- Notarization credential policy and acceptance-matrix self-tests passed.
- GitHub workflow, scripts, bundled tools, and restic command surface passed.
- Debug/Release packaging and nested code-signature validation passed.
- External-evidence verifier self-test and fail-closed ad-hoc packaging checks passed.

Focused `ResticRunnerTests` also passed all 26 tests, including the new UTF-8, bounded-output, structured-output overflow, retention privacy, and oversized-line regressions.

### Exact final installed candidate

`Scripts/build-release.sh` and `Scripts/install-app.sh dist/Delta.app` passed.

| Property | Verified value |
| --- | --- |
| Installed path | `/Applications/Delta.app` |
| Bundle identifier | `com.delta.backup` |
| Version | 0.2.0 (2) |
| Architectures | `x86_64 arm64` |
| Authority | Developer ID Application: Daniel Buskariol (`BJCVJ5G7MJ`) |
| Team | `BJCVJ5G7MJ` |
| Hardened runtime | 26.5.0 |
| CDHash | `1785fd98e7b7a49922c8f313891187decfe15bfa` |
| Main executable SHA-256 | `ae8b9313f438752b8539a62cddc927484afa08b2ccf13a4e87865d05645b4c12` |
| dSYM archive SHA-256 | `cdb314835b51126bbbed07a6f9b627ec1e9c649b2fc7b3c0fd1e9d83d9bacd28` |

The `dist` and installed main executables have the same SHA-256, and both app bundles pass strict deep code-signature verification. The guarded installer preserved the designated requirement and signing team.

### Installed-app acceptance for the final CDHash

All of these commands passed against `/Applications/Delta.app` after the final build:

- `Scripts/run-installed-keychain-access-acceptance.sh`
- `Scripts/run-installed-preferences-acceptance.sh`
- `Scripts/run-installed-diagnostics-acceptance.sh`
- `Scripts/run-installed-menu-bar-surface-acceptance.sh`
- `Scripts/run-installed-run-control-acceptance.sh`
- `Scripts/run-installed-scheduled-agent-acceptance.sh`
- `Scripts/run-installed-local-backup-acceptance.sh`
- `Scripts/run-installed-local-rest-acceptance.sh`
- `Scripts/run-installed-local-s3-acceptance.sh`
- `Scripts/run-installed-local-sftp-acceptance.sh`
- `Scripts/run-installed-rclone-local-acceptance.sh`
- `Scripts/run-installed-mounted-volume-acceptance.sh`

These cover Keychain continuity, preferences/defaults, diagnostic redaction, status-menu contracts, pause/resume/cancel, scheduled work, local repositories, and deterministic local REST, S3-compatible, SFTP, rclone, and temporary mounted-volume lifecycles. The protocol harnesses are supporting regression evidence, not genuine provider evidence.

## Computer Use scenarios

The real installed app was navigated through its accessibility tree and native controls. No preview or mock UI was used.

- Created the isolated `Studio Archive` local destination under `/Users/Shared/Delta Acceptance` and the `Project Files` profile.
- Prepared the repository automatically and completed the first backup.
- Exercised incremental and no-change backups; the final candidate reported `0 new · 0 changed · 11 KB checked`.
- Browsed the restore point tree to individual files.
- Ran a dry-run restore and a full verified restore through the Restore page.
- Exercised selected restore behavior and inspected the restored hierarchy.
- Confirmed cleanup shows a destructive confirmation describing the destination, permanent restore-point removal, pruning, and the configured post-cleanup check.
- Ran cleanup and confirmed Activity showed `Retention complete · kept 1 restore point · removed 0 restore points` without raw host/user metadata.
- Ran repository checks before and after a same-identity reinstall.
- Relaunched the final installed candidate, reopened the saved repository, ran a check, and ran a no-change backup without an interactive Keychain prompt.
- Reviewed Dashboard, Backups, Destinations, Restore, Activity, General, Permissions, Defaults, Updates, and Advanced settings.
- Repeated first-run navigation against an isolated `/Users/Shared/Delta Onboarding Acceptance` state. Dashboard, Backups, and Restore opened the existing destination editor directly; Restore showed no disabled workflow controls; Activity and Events each showed one unambiguous empty state.
- Verified the final installed app exposes Settings in the Delta menu, Navigate in the menu bar, Command-comma for Settings, and Command-1 through Command-5 for primary-section navigation.
- Used Check Now in Updates and received the signed-feed result: Delta 0.2.0 was current.
- Confirmed Full Disk Access, Notifications, Scheduled Backups, and Saved Passwords showed Allowed in the Permissions page.

The signed UI restore produced these source/restored SHA-256 pairs:

| Fixture | Source SHA-256 | Restored SHA-256 |
| --- | --- | --- |
| `Product Guide.md` | `ccd4e1b04d58c6de871b99d5924f7555ed0001c6fc55d750e1852f03819495b5` | `ccd4e1b04d58c6de871b99d5924f7555ed0001c6fc55d750e1852f03819495b5` |
| `Security Guide.md` | `5269176f877f033d929919305a606864f70ac256fb37a3719aac150e0ab0aa5e` | `5269176f877f033d929919305a606864f70ac256fb37a3719aac150e0ab0aa5e` |

## Screenshot privacy

Six current README screenshots were captured from the installed app at 1115 × 768:

- Dashboard
- Backups
- Destinations
- Restore browser
- Activity
- Settings → Permissions

Each image was visually inspected. Filesystem content uses only `/Applications/Delta.app` and the neutral `/Users/Shared/Delta Acceptance` fixture. A binary string scan found no personal username or home path, and Spotlight metadata reports no author, creator, or source URL. The disposable fixture and its exact Keychain item were deleted after verification.

## Release-gate results

The non-writing external preflight passed as a parser/configuration check and reported:

- Ready: 0
- Not configured: 10
- Invalid: 0

`Scripts/doctor-production-readiness.sh` correctly reported 8 blockers and 7 warnings. It verified the Developer ID signature and matching installed CDHash, then blocked on missing release-gate state, notarization evidence, manual acceptance, and genuine external backends.

Before the changes were committed for review, the final gates failed as intended:

```text
Scripts/verify-release.sh
Delta release error: the worktree is dirty; commit the verified release source first

Scripts/verify-production-readiness.sh
Production readiness failed: git worktree is not clean
```

The combined local probe recorded 11 partial rows, 1 human-only row, and 10 failed release-state rows. Those failures are accounted for: eight depend on the missing clean-commit automated release record, one needs signed Sparkle artifacts, and one needs notarization/Gatekeeper evidence.

## Remaining external acceptance

External distribution still requires all of the following for the exact committed candidate:

1. Land the pull request, then pass `Scripts/verify-release.sh` from the exact clean release commit.
2. Complete and verify the manual acceptance matrix for that exact commit and app CDHash.
3. Run genuine mounted SMB or NFS, non-local SFTP, and non-local S3-compatible lifecycles with current credentials and infrastructure. Localhost and temporary APFS evidence must remain labeled as supporting evidence.
4. Complete any additional backend families required for the intended release: REST, B2, Azure, GCS, Swift, rclone, and custom URLs.
5. Manually verify Notification Center delivery, persistent status-item behavior, and an actual signed Sparkle update from an older build.
6. With explicit release authority, notarize and staple the app and DMG, archive the accepted submission/logs, pass Gatekeeper, verify Sparkle artifacts, collect release evidence, and rerun `Scripts/verify-production-readiness.sh`.

No Apple notarization submission, release tag, publication, credential rotation, or genuine external-provider write was performed during this verification.
