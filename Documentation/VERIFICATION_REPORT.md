# Delta Verification Report

Date: 20 July 2026

Host: macOS 26.5.2 (25F84)

Candidate: Delta 0.4.1 (16)

Status: exact-candidate verification contract

## Outcome

Delta's source, deterministic acceptance harnesses, Developer ID build, stable installer, notarization flow, Sparkle packaging, privacy controls, and production-readiness checks are covered by the release contract below. The source identifies the next candidate as `0.4.1` (16).

A release must not be merged, tagged, or published until the complete exact-commit gate, separate app and DMG notarization, stapling, Gatekeeper checks, signed-update installation, manual acceptance matrix, and required genuine external-provider evidence have all passed for this version. Generated evidence under `dist/` is authoritative for the commit, installed path, CDHash, notarization IDs, artifact hashes, command results, and acceptance status; this tracked report deliberately does not duplicate volatile identity values or claim that an unverified source commit has passed.

## Implemented and reviewed changes

- Rebuilt every Settings category with compact native cards, inset separators, icon-led rows, and aligned controls.
- Added a dedicated Permissions page for Full Disk Access, notifications, scheduled-backup approval, and saved-password readiness.
- Aligned onboarding and empty states around one primary action and opened destination creation directly from Dashboard, Backups, and Restore.
- Added native Settings and navigation commands, including Command-comma and Command-1 through Command-5.
- Added explicit confirmation before cleanup permanently forgets restore points and prunes unreferenced data.
- Prevented concurrent background operations and added pause, resume, and cancel coverage.
- Made child-process streaming safe across UTF-8 read boundaries and bounded stdout and stderr without losing required structured diagnostics.
- Redacted structured retention, repository, credential, username, hostname, and local-path details from user-visible diagnostics.
- Hardened the stable installer with bundle, minimum-system, team, designated-requirement, staging, rollback, and post-install checks.
- Bound successful release rehearsals to their exact commit, app path, and CDHash so stale evidence fails closed.
- Kept app and DMG notarization records under one producer/consumer artifact contract with regression coverage.
- Correctly verified Sparkle's signed external release notes when Sparkle prepends its integrity warning.
- Simplified Delta's icon and aligned its colour and visual weight with Reccy while preserving Delta's backup identity.
- Rebuilt the menu-bar popover around Reccy's compact native material, section, active-work, and accessible icon-footer patterns while preserving Delta's backup controls and status semantics.
- Corrected singular custom-schedule wording and aligned the README, release notes, operating guide, screenshots, and release pipeline with the implemented app.
- Kept scheduled notification submission inside the short-lived agent lifetime until macOS acknowledges the request, with bounded timeout and failure evidence.
- Removed Intel-sensitive `pipefail` handling from bundled-tool validation and made the crash-marker scan portable to clean macOS runners without ripgrep.
- Added Delta-managed Time Machine-format destinations backed by a provisioned FSKit extension, bounded local cache, authenticated remote generations, verified recovery-key retention, safe reconnect and removal, and the existing native Permissions guidance.
- Added a clean first-registration Time Machine system-support acceptance gate that uses the production Service Management and authenticated XPC path, binds evidence to the exact notarized installed candidate and helper code hashes, and prevents publishing from treating retained development registration state or a transient build location as release proof.
- Kept the Permissions surface to one authoritative Review Login Items action when Time Machine system support and scheduled backups both need attention, and bound the generated Xcode project and its source specification to the same immutable build identity.
- Refreshed the README Permissions image to show the current Time Machine File System and Time Machine System Support rows and the single shared Login Items recovery action.
- Replaced ambiguous per-app FSKit approval guidance with the working macOS By Category → File System Extensions route everywhere Delta presents or verifies setup instructions.
- Kept the release-history audit fail closed while allowing the repository account's approved GitHub noreply display name and GitHub's service committer on GitHub-created commits.

## Automated verification contract

The complete source and packaging gate is:

```sh
Scripts/verify-ci.sh
Scripts/verify-release.sh
```

It covers Swift tests and a real restic lifecycle; script syntax; project, plist, privacy, release-note, and version metadata; product-language and secret scans; universal app and bundled-tool architectures; nested signatures and hardened runtime; installed Keychain, preferences, diagnostics, menu-bar, run-control, scheduling, local repository, REST, S3-compatible, SFTP, rclone, and mounted-volume harnesses; Sparkle feed, archive, and release-note signatures; DMG, dSYMs, manifest, checksums, and source-to-artifact provenance; and fail-closed release-evidence handoff.

Local protocol harnesses are deterministic regression evidence. They never satisfy the separate requirement for real external mounted storage, non-local SFTP, or non-local S3-compatible infrastructure.

## Manual acceptance contract

Manual acceptance uses the exact installed candidate at `/Applications/Delta.app`. Its generated report must identify the same version, build, commit, app path, and CDHash as the automated gate. The matrix covers:

- Settings, permissions, saved-password access, schedule controls, and backup defaults.
- Local, mounted-network, SFTP, S3-compatible, and any other intended remote destination families.
- First and incremental backup preparation, restore-point browsing, dry-run and verified restore behavior, original-path and overwrite choices, and cleanup confirmation.
- Pause, resume, cancel, live and bounded Activity output, warning issues, menu-bar behavior, Notification Center delivery, and a signed Sparkle upgrade from an older installed build.
- Diagnostic and screenshot redaction, including absence of personal usernames, home paths, secrets, and credential-bearing repository URLs.

The README screenshots are product references, not release-acceptance evidence. They use neutral or redacted product state and have been visually inspected for personal usernames, home paths, secrets, credential-bearing URLs, and author, creator, or source-URL metadata. Exact-candidate screenshot inspection remains part of the generated manual acceptance evidence and is never inferred from a tracked JPEG.

## Apple and distribution contract

Finalization requires separate accepted Apple submissions for the app archive and signed DMG, zero notarization issues, successful stapling, Gatekeeper acceptance for the packaged and installed app, a matching Developer ID identity and designated requirement, a signed Sparkle ZIP and feed, matching ZIP/DMG executables, dSYM UUIDs, checksums, and a manifest bound to the exact source commit and version.

`Scripts/doctor-production-readiness.sh` and `Scripts/verify-production-readiness.sh` remain fail closed until those artifacts, the complete manual matrix, and genuine external-provider evidence agree. `Scripts/publish-release.sh` must then stage a draft, download and reverify the six public assets in a fresh directory, and only publish when every check still passes.

## Required release handoff

1. Build, install, and complete all exact-commit automated, signing, Apple notarization, stapling, Gatekeeper, and evidence checks for `0.4.1` (16).
2. Complete every row of the exact-candidate manual acceptance matrix, including a real signed Sparkle upgrade and system-delivered notifications.
3. Provide and exercise genuine external mounted SMB or NFS, non-local SFTP, and non-local S3-compatible fixtures, plus any additional backend families intended for this release.
4. Obtain a fully passing production-readiness result before merging, tagging `v0.4.1`, or publishing.
