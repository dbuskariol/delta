# AGENTS.md

This file is the repository-wide operating guide for coding agents working on Delta. It applies to every path in the checkout unless a more specific `AGENTS.md` exists below it. Direct user instructions always take precedence.

## Product and engineering intent

Delta is a native macOS 26 encrypted backup and restore manager built with Swift 6.2, SwiftUI, AppKit, Service Management, GRDB/SQLite, Sparkle, restic, and rclone. The app deliberately supports macOS 26 only; do not add availability branches or compatibility UI for older systems.

Treat these as product invariants:

- Delta is local-first and privacy-preserving. Profiles, operational state, logs, and restore-point metadata stay on the Mac; secrets stay in the login Keychain; encrypted backup data stays at the destination selected by the user. Network access is limited to the signed update feed and destinations the user explicitly configures.
- Restic owns repository encryption, snapshot creation, deduplication, restore, retention, pruning, integrity checks, and repository-format compatibility. Delta owns native interaction, validation, policy, scheduling, local state, credentials, process coordination, and trustworthy presentation. Do not invent incompatible repository semantics or bypass restic's safety model.
- A backup is not successful merely because some data was written. Preserve restic's technical exit status, warnings, unreadable-file evidence, raw audit trail, and the distinction between complete success, known omissions, interruption, cancellation, and failure.
- A restore must never imply that data was recovered until the requested files were written and, when selected, verified. Original-location restores, in-place overwrites, destructive cleanup, password changes, and other high-consequence operations require explicit scope and confirmation.
- Destination passwords and backend credentials never belong in command arguments, broad inherited process state, SQLite, logs, diagnostics, fixtures, temporary files, release artifacts, or source control. Supply secrets only through the signed password-command path, short-lived standard input, or the minimum curated child-process environment required by a backend.
- User-managed repository passwords are not recoverable by Delta. Password rotation must stage and verify the new restic key before retiring the previous key, and failures must leave the repository accessible with a known-good key.
- Work is serialized per destination across the app and scheduled processes. Preserve the local destination lock, restic repository locking, SQLite WAL coordination, and the rule that a persisted running job is marked interrupted only after proving that no process still owns its local lock.
- Scheduled and interactive work follow the same validation and policy rules. Scheduled secret reads are noninteractive and fail closed. `DeltaAgent` remains a short-lived Service Management agent, not a privileged daemon or a second independent backup implementation.
- `~/Library/Application Support/Delta` is application state, not the user's backup repository. Deleting it can lose local configuration and audit history but must never be presented as deleting or preserving the encrypted backup data at a configured destination. Never confuse database cleanup, log retention, migrations, or app recovery with repository maintenance.
- The shipping app is a universal `arm64` and `x86_64` Developer ID application with Hardened Runtime, secure timestamps, Apple notarization, stapled tickets, Gatekeeper acceptance, and Sparkle archive/feed verification.
- Icon-only controls need stable accessibility labels, help text where useful, keyboard access where appropriate, and equivalent VoiceOver actions for direct-manipulation behavior.

## Native Mac quality bar

“Native” is a product requirement, not just an implementation language. Delta should feel designed for the current macOS rather than like a web, mobile, or cross-platform interface placed in a window.

- Prefer current Apple frameworks and system behavior: SwiftUI and Observation for interface state, AppKit where Mac-specific control is needed, Service Management for scheduled background work, UserNotifications for alerts, Security/Keychain for secrets, and standard system panels and services.
- Use standard Mac structure: real windows and scenes, toolbars, sidebars, tables or outlines, search fields, menus, Settings, sheets, popovers, alerts, context menus, drag and drop, Share/Reveal conventions, and undo/redo through the responder chain where editing warrants it.
- Respect window resizing, compact and expansive layouts, multiple displays, full screen, focus, first-responder behavior, state restoration, appearance, accent color, increased contrast, reduced motion, and Dynamic Type where macOS exposes it.
- Keyboard use is first-class. Commands need conventional menu placement, discoverable shortcuts, correct enabled state, focus traversal, Escape/Return behavior, and the same result whether invoked from a button, menu item, shortcut, context menu, menu-bar control, or accessibility action.
- Accessibility is part of the control contract. Preserve semantic roles and values, useful grouping and reading order, sufficiently large hit targets, non-color status cues, spoken progress and errors, and usable alternatives to pointer-only interaction.
- Let the system own privacy-sensitive approval and permission guidance whenever it provides the authoritative surface. Explain why Full Disk Access, Login Items, Notifications, file access, or Keychain access is needed; accurately reflect current authorization; and provide one clear recovery action without pretending Delta can grant permission itself.
- Prefer platform-standard terminology, typography, spacing, materials, symbols, animations, and interaction feedback. Custom chrome, gestures, and controls require a concrete product benefit and must still behave like Mac controls.
- Do not expose restic, LaunchAgent, bookmark, lock-file, or process terminology in primary product UI when plain backup language communicates the state. Preserve technical detail in Activity, diagnostics, and support evidence where it is useful and safely redacted.
- Do not duplicate the same action or message in one context. Establish one visual primary action and one authoritative presentation of readiness, status, progress, validation, warnings, errors, and confirmation. Secondary entry points are welcome when they route through the same command, state, naming, availability, and behavior.
- Keep Dashboard, profiles, destinations, Activity, Restore, menu bar, Notifications, and Settings coherent. A job's state, a destination's availability, a policy restriction, or a known omission must mean the same thing everywhere it appears.
- Add a third-party dependency only when Apple frameworks, restic/rclone, GRDB, Sparkle, and a small maintained local implementation cannot meet the requirement. Consider binary size, privacy, signing, concurrency, launch cost, update cadence, supply-chain trust, and Intel support before doing so.

## Performance and resource discipline

Delta coordinates long-running child processes, large repositories, deep file trees, and durable job history while remaining responsive. Performance regressions are correctness bugs when they can freeze controls, lose progress or log evidence, exhaust memory or disk space, delay cancellation, corrupt perceived job state, or interfere with scheduled work.

- Keep restic/rclone execution, filesystem inspection, Keychain access, SQLite work, bookmark resolution, log parsing, diagnostics, and repository browsing off the main actor. Publish compact user-interface state on the main actor at a deliberate cadence.
- Stream process output incrementally. Bound in-memory logs, issue collections, progress samples, restore listings, and history pages; persist the evidence needed for audit and troubleshooting without loading an entire long run or repository into memory.
- Coalesce high-frequency progress updates before invalidating SwiftUI. Do not rebuild large view trees for every output line, byte count, file event, or scheduler tick.
- Apply backpressure deliberately between process pipes, parsers, persistence, and presentation. Never allow an unread pipe or slow UI consumer to stall a backup process indefinitely.
- Preserve process ownership and lifecycle. Cancellation, pause, resume, termination, app quit, scheduled-agent exit, relaunch, and crash recovery must leave accurate persisted state and must not orphan work or mark live work interrupted.
- Cancel stale asynchronous work when a profile, destination, restore point, selection, window, or app lifecycle changes. Tie tasks, observers, timers, security-scoped access, database subscriptions, and child processes to explicit owners.
- Prefer event-driven observation to polling. Any repeating scheduler, status refresh, destination check, or timer needs a clear cadence, owner, suspension behavior, and teardown path.
- Keep cross-process database transactions short. Preserve WAL mode and the busy timeout; avoid holding database work open while waiting on filesystem, Keychain, UI, network, or child-process operations.
- Check source readability, destination presence and writability, required free space, credentials, and lock state before invoking destructive or expensive repository work. Preflights must stay accurate and must not mutate an existing repository merely to test it.
- Make listing and history interfaces incremental, stable, and cancellable. Pagination or refresh must not duplicate, reorder unexpectedly, or erase the user's current selection when new output arrives.
- Measure before and after meaningful performance work. Use Instruments, signposts, structured timing, memory graphs, Energy Log, representative repositories, and real installed-app runs as appropriate; do not replace evidence with intuition.
- Exercise large and slow scenarios, not only tiny local smoke tests. Observe launch and Activity latency, memory high-water mark, CPU and energy use, output throughput, database growth, cancellation latency, disconnected destinations, network stalls, large restore-point sets, and long backup or restore operations.

When changing process execution, parsing, persistence, scheduling, or repository browsing, state the expected resource behavior in code or architecture documentation, add regression coverage where practical, and validate the real installed app with a representative workload.

## Repository map

- `Sources/Delta`: SwiftUI/AppKit application, app model, Dashboard and workflow surfaces, menu-bar controller, settings, diagnostics, acceptance commands, and Sparkle integration.
- `Sources/DeltaCore`: domain models, policies, validation, scheduling, GRDB persistence, Keychain integration, bookmark handling, restic command construction and parsing, process control, notifications, diagnostics, and shared presentation contracts.
- `Sources/DeltaAgent`: short-lived scheduled-work agent entry point.
- `Sources/DeltaSecretBridge`: restricted noninteractive Keychain compatibility path.
- `Sources/DeltaSecurity`: small C security support module used by the Swift targets.
- `Tests/DeltaCoreTests`: Swift/XCTest policy, persistence, security, scheduling, command, parser, presentation-contract, and real local restic integration coverage.
- `Packaging`: bundle metadata, entitlements, Login Item configuration, and distribution inputs.
- `Resources`: privacy declaration, source icon assets, and bundled-tool metadata. Generated `.icns` and downloaded restic/rclone binaries are not source.
- `Documentation` and `docs`: architecture, release process, release notes, production acceptance, and restic-compliance documentation.
- `Scripts`: bootstrap, build, CI, installed-app acceptance, external-backend evidence, diagnostics, packaging, notarization, and fail-closed release automation.
- `.github/workflows`: Apple-silicon and Intel macOS 26 CI plus guarded release automation.
- `dist`: generated application, acceptance, release, notarization, symbol, and distribution output. Do not hand-edit or treat it as source.

Read `README.md` for current product behavior, `Documentation/ARCHITECTURE.md` before changing process, persistence, secret, or locking boundaries, `docs/RESTIC_COMPLIANCE.md` before changing backup-engine behavior, `docs/PRODUCTION_READINESS.md` before changing acceptance requirements, and `Documentation/RELEASING.md` before touching distribution code.

## Working in the checkout

Before editing:

1. Inspect `git status --short`, the current branch, and the relevant diff. A dirty worktree is normal; preserve changes you did not create.
2. Search with `rg` or `rg --files` before introducing a new abstraction, model, helper, acceptance command, or script.
3. Trace behavior across model, policy, coordinator, process runner, persistence, view, agent, test, documentation, and release layers. Backup and restore changes frequently cross more than one of them.
4. When a sibling Reccy checkout is available, compare its established native UI, documentation, testing, installation, and release patterns before creating a parallel solution. Reuse the pattern where the invariant matches; adapt it explicitly where Delta's repository, credential, background-work, or restore-safety boundary differs.

While editing:

- Prefer small, typed changes that preserve the existing process boundaries and restic compatibility.
- Keep Swift 6 strict-concurrency checks clean. Avoid `@unchecked Sendable`, detached work, global mutable state, or actor escapes unless the safety argument is documented and tested.
- Construct restic and rclone invocations from typed models. Preserve argument ordering and backend-specific environment policy, redact credential-bearing URLs, and never interpolate commands through a shell when direct process arguments will work.
- Preserve technical exit codes and distinguish failure, cancellation, interruption, complete success, and success with known omissions throughout persistence and presentation.
- Validate profiles, bookmarks, source access, destination availability, write access, credentials, repository state, free space, and locks before starting work. Validation failures must be actionable and must not partially mutate user data.
- Treat prune, forget, check, password rotation, overwrite, original-location restore, repository initialization, and cleanup as high-consequence paths. Confirm scope, serialize correctly, preserve recoverability, and test failure between stages.
- Keep database migrations forward-safe and transactional. Never silently discard profiles, destinations, jobs, issues, restore points, settings, or the evidence needed to explain an incomplete run.
- Make schedule evaluation deterministic. Test time zones, calendar boundaries, catch-up, disabled schedules, battery and Low Power Mode policy, paused automatic runs, missed launches, duplicate agent invocations, and clock changes.
- Balance every security-scoped resource access and close every process pipe, file handle, observation, and transaction on success, failure, and cancellation.
- Keep user-facing errors actionable, redacted, and faithful to the underlying outcome. Do not turn a credential, permission, destination, repository, or partial-backup failure into a generic success or silent retry loop.
- Reuse native SwiftUI, AppKit, system pickers, Settings, notifications, and Service Management surfaces. Do not introduce a custom control when a native control carries the correct behavior and accessibility semantics.
- Reproduce defects before fixing them when the environment permits. Fix the root cause, inspect adjacent paths that share the mechanism, and add a regression test. Do not swallow an error, weaken an assertion, remove a capability, fabricate evidence, or relabel a failure to make a symptom disappear.
- Do not add telemetry, analytics, uploaded diagnostics, remote control, or any network path beyond signed update checks and user-configured backup destinations.
- Use `apply_patch` for intentional text edits. Do not run destructive Git commands or overwrite unrelated work.

Generated build products and DerivedData belong outside the repository. Release scripts default to `~/Library/Developer/Xcode/DerivedData/Delta`; preserve that convention so executable bundles do not inherit protected-folder behavior from the checkout. Delete only reproducible Delta artifacts in known Delta-specific locations, never configured repositories, source data, restored data, credentials, current release candidates, signing/notarization evidence, acceptance evidence, or unrelated directories.

## Verification

Run checks in proportion to the change, and report exactly what ran and what did not.

The certificate-free repository gate is:

```sh
Scripts/verify-ci.sh
```

It runs the Swift test suite, product-language and crash-marker checks, acceptance-matrix and release-policy self-tests, workflow and script validation, bundled-tool verification, real local restic integration tests, a warning-free ad-hoc Release app build, strict code-signature and bundle checks, external-evidence verifier self-tests, and the fail-closed boundary that prevents an ad-hoc app from becoming an update package.

For a focused test, use SwiftPM filtering and confirm that the expected test actually ran:

```sh
/usr/bin/swift test --filter BackupProfileValidatorTests
```

For the real local restic integration suite:

```sh
Scripts/bootstrap-tools.sh
DELTA_RESTIC_INTEGRATION=1 \
RESTIC_BINARY="$PWD/Resources/Tools/bin/restic" \
/usr/bin/swift test --filter ResticIntegrationTests
```

Add or update tests under `Tests/DeltaCoreTests` when policy, validation, scheduling, persistence, redaction, command construction, parsing, locking, restore selection, job outcomes, settings, menu-bar behavior, or diagnostics change. Prefer deterministic pure-policy coverage, then real local restic lifecycle tests when engine behavior is part of the contract. A test may skip only when a genuinely optional external fixture is unavailable; product logic must not be hidden behind a skip.

Code inspection and automated tests are not substitutes for navigating the app. For user-visible or workflow changes, exercise the installed app's actual controls and alternate states: keyboard and pointer entry points, loading and empty states, invalid configuration, permission denial, missing credentials, unavailable or unwritable destinations, repository busy state, cancellation, retry, relaunch, window resizing, menus, Settings, menu bar, and cross-surface behavior.

Keychain access, privacy grants, Login Items, Full Disk Access, Notifications, Sparkle, and background scheduling are tied to the installed signing identity. Ad-hoc builds are suitable for compilation, tests, and limited acceptance commands, but identity-sensitive acceptance requires a stable Apple Development or Developer ID app installed at `/Applications/Delta.app`. Never replace a current signed release candidate with an ad-hoc bundle and then claim identity-sensitive evidence still applies.

Use the installed-app and lifecycle scripts relevant to the change. `Scripts/run-local-acceptance-probe.sh /Applications/Delta.app` collects supporting evidence but does not replace the manual matrix. Deterministic local, mounted-volume, REST, S3-compatible, SFTP, rclone, scheduling, run-control, menu-bar, preferences, diagnostics, and Keychain harnesses do not substitute for manually exercising the real UI or for testing a genuine remote provider where the production matrix requires it.

When working on destination behavior, verify a complete lifecycle against an isolated disposable repository: automatic preparation, first backup, no-change and changed backups, restore-point refresh, browsing, full and selected restore, overwrite policies, data verification, check, retention/cleanup, prune, post-cleanup check, saved logs, and Keychain cleanup. For mounted or remote destinations, also test disconnects, unwritable targets, missing or wrong credentials, reconnects, latency, and interruption. Never point tests at an existing repository unless the user has explicitly authorized that exact target.

Before external distribution, follow `docs/PRODUCTION_READINESS.md` exactly. Automated or localhost evidence must not be promoted to manual or genuine-provider evidence. Keep every report bound to the exact commit, app path, bundle version, executable, bundled restic/rclone, signature, and CDHash required by its verifier.

## Documentation responsibilities

Update documentation in the same change when behavior or operator expectations move:

- `README.md` for user-visible capability, setup, privacy, permissions, supported destinations, recovery expectations, or genuine limitations.
- `Documentation/ARCHITECTURE.md` for process, concurrency, persistence, secret, locking, data-flow, update-trust, or format decisions.
- `docs/RESTIC_COMPLIANCE.md` for repository, credential, backend, backup, snapshot, restore, retention, prune, check, lock, or streaming-log semantics.
- `docs/PRODUCTION_READINESS.md` and the acceptance scripts together when a release criterion or required evidence changes.
- `Documentation/RELEASE_NOTES.md` for release-visible fixes and features. Its version heading must match `MARKETING_VERSION`.
- `Documentation/RELEASING.md` and release scripts together when a distribution invariant changes.
- `SECURITY.md` when the threat model, credential handling, privacy, diagnostic redaction, or update trust changes.

Keep documentation factual and durable. Distinguish implemented behavior, automated coverage, locally observed installed-app acceptance, genuine external-provider evidence, and work that still needs credentials, hardware, Apple services, or manual verification. Do not claim a repository protects data merely because configuration saved or a process started.

## Release safety

Release operations have materially different authority levels:

- `Scripts/release.sh prepare` and `Scripts/verify-release.sh` in their default mode are local, non-publishing rehearsals. They build and validate the release artifact graph but do not submit to Apple's notary service or publish a GitHub release.
- `Scripts/release.sh finalize` contacts Apple, requires the exact clean annotated `v<MARKETING_VERSION>` tag, notarizes and staples the app and DMG, and produces publishable artifacts.
- `Scripts/publish-release.sh`, pushing a tag, or making a GitHub release public changes external state.

Do not finalize, notarize, install over an active release candidate, tag, push, publish, enable release automation, rotate credentials, delete acceptance/notarization evidence, or replace active release outputs unless the user explicitly requests that action. Never expose Developer ID material, Sparkle private keys, App Store Connect credentials, backend credentials, repository passwords, SSH keys, Keychain contents, dSYMs, or notarization credentials in logs or commits.

A release candidate is not production-ready until all applicable gates are true:

- Version and build metadata are intentional and release notes match.
- `Scripts/verify-ci.sh` passes locally and on Apple-silicon and Intel macOS 26 CI.
- The exact candidate and every nested executable are universal, correctly entitled, timestamp-signed with Developer ID, and identified by checksums and provenance.
- The stable-signed app installed at `/Applications/Delta.app` matches the verified candidate and passes relevant backup, restore, schedule, Keychain, permission, menu-bar, notification, diagnostics, recovery, accessibility, and update acceptance.
- Required genuine mounted-network, SFTP, S3-compatible, and other configured provider lifecycles have current evidence; deterministic localhost harnesses remain correctly labeled as supporting evidence.
- The manual acceptance report is complete, current, and bound to the same commit and candidate.
- The app and DMG are notarized and stapled, Gatekeeper accepts them, Sparkle verifies the archive/feed signatures, and release evidence identifies the exact source commit and CDHash.
- `Scripts/verify-production-readiness.sh` passes without bypassing or weakening a gate.
- Any credential, provider, signing, notarization, hardware, permission, or environment gap is written down rather than inferred away.

## Handoff expectations

At completion, summarize the outcome first, then list changed files, verification results, manually exercised scenarios, inspected backup and restored artifacts, and remaining external gaps. Do not say a task is complete when tests are failing, a required artifact or report is stale, a real provider was replaced by localhost evidence, the exact signed installed candidate was not exercised where required, or an external dependency still blocks the requested outcome.
