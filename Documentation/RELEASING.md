# Releasing Delta

Delta ships outside the Mac App Store as a universal, hardened, Developer ID-signed and notarized app. `Scripts/release.sh` is the only shipping build entry point. It archives and exports through Xcode's Developer ID distribution flow; it never assembles or outer `--deep` re-signs an app bundle.

## Invariants

A release must prove all of the following:

- A clean worktree, coherent semantic version and positive build number, and release notes headed exactly for that version.
- Bundle ID `com.delta.backup`, minimum macOS 26.0, and `arm64` plus `x86_64` slices in the app, helper tools, bundled backup tools, and Sparkle code.
- Timestamped Developer ID Application signatures from team `BJCVJ5G7MJ`, Hardened Runtime, strict nested signature validity, and no debug/runtime-exception entitlements.
- A provisioned `DeltaTimeMachineFS` extension carrying the exact `com.apple.developer.fskit.fsmodule` capability and App Sandbox; the exact public macOS App Group `BJCVJ5G7MJ.deltatm` on the app, storage service, and extension; no client-network, server-network, or temporary-exception entitlement on the extension; an all-device Developer ID profile for `BJCVJ5G7MJ.com.delta.backup.timemachine-filesystem`; and the same team identity throughout.
- A no-tracking/no-collection privacy manifest with the required-reason declarations used by Delta.
- A product-specific Sparkle key, signed feeds, signed ZIP and external release notes, and verification before extraction.
- Separate Apple notarization submissions for the app archive and signed DMG, both accepted with zero issues, followed by stapling and Gatekeeper acceptance.
- Matching ZIP/DMG executables, dSYM UUIDs, checksums, and a manifest bound to the exact Git commit and tag.

The Developer ID private key, Sparkle private key, notarization credentials, dSYMs, `.xcarchive`, and Apple evidence stay private. Only the DMG, ZIP, appcast, release notes, checksums, and release manifest are public assets.

The release build discovers an installed all-device FSKit distribution profile by its exact team, application identifier, and `com.apple.developer.fskit.fsmodule` grant. Xcode archives the complete graph with team-managed automatic provisioning so restricted capabilities and Swift-package resource targets retain coherent signing. The required `developer-id` export then uses Xcode's managed-profile flow to re-sign every nested component inside-out with the exact Developer ID certificate. The final validator independently requires the matching all-device profile, FSKit capability, App Sandbox, and exact Team-ID-prefixed macOS App Group on all three IPC peers, while rejecting client/server-network or temporary-exception entitlements on the extension. Team-ID-prefixed App Groups are a supported macOS form and do not require a separately provisioned group; they are not used here as a Keychain access group. Missing or mismatched provisioning stops before archive; the build never clears the shipping entitlement to work around provisioning.

## Rehearsal

After committing release-source changes, run:

```sh
DELTA_CODESIGN_IDENTITY="Developer ID Application: Daniel Buskariol (BJCVJ5G7MJ)" \
DELTA_DEVELOPMENT_TEAM="BJCVJ5G7MJ" \
DELTA_SPARKLE_KEY_ACCOUNT="com.delta.backup.sparkle" \
Scripts/release.sh prepare
```

Rehearsal mode builds and validates the complete artifact graph but does not submit to Apple, mutate GitHub, launch the transient candidate as the user's app, or register its embedded Service Management components. Identity-sensitive launch, Login Items, and privileged-helper acceptance run only against the exact candidate after it is installed under `/Applications`. The rehearsal manifest explicitly records that artifacts are not notarized, so rehearsal output cannot be confused with a shipping release.

## Finalize

Finalization is allowed only from the clean commit pointed to by the annotated `v<version>` tag. The tagger must be `dbuskariol <32349796+dbuskariol@users.noreply.github.com>`.

```sh
git tag -a v0.3.0 -m "Delta 0.3.0"

DELTA_CODESIGN_IDENTITY="Developer ID Application: Daniel Buskariol (BJCVJ5G7MJ)" \
DELTA_DEVELOPMENT_TEAM="BJCVJ5G7MJ" \
DELTA_NOTARY_KEYCHAIN_PROFILE="Reccy Notary" \
DELTA_SPARKLE_KEY_ACCOUNT="com.delta.backup.sparkle" \
Scripts/release.sh finalize
```

The Keychain profile name is not product metadata; the existing `Reccy Notary` profile may be used because it represents the same Apple developer account. CI uses an App Store Connect API key from protected secrets instead. Credentials must never be supplied inline or written into the repository.

Finalization writes public candidates under `dist/updates`, private notarization evidence under `dist/notarization`, and private dSYMs under `dist/symbols`.

Before publishing, install the exact finalized candidate and prove its privileged Time Machine support on a clean acceptance host:

```sh
Scripts/install-app.sh dist/Delta.app
Scripts/run-installed-time-machine-system-support-acceptance.sh /Applications/Delta.app
```

The host must begin with both Delta Time Machine Service Management items unregistered. Apple's public `SMAppService` contract requires an administrator to approve a launch daemon in System Settings before it is eligible to run, so this is deliberately an interactive installed-candidate gate rather than a headless CI simulation. The script waits for the native approval, requires both items to become enabled, authenticates the running helper against the exact embedded helper code hash, unregisters both items through public APIs, and writes candidate-bound evidence under `dist/time-machine-system-support`. It never runs a helper directly, edits Background Task Management or launchd state, or accepts a renamed, `dist`, DerivedData, archive, or worktree app.

## Publish

`Scripts/publish-release.sh` performs the publishing transaction. Before contacting GitHub it re-runs the history/security audit, verifies the complete artifact graph, and requires `Scripts/verify-production-readiness.sh` to pass for the exact installed candidate, current manual acceptance report, and genuine external-backend evidence. It then creates a draft with the six intended public assets, downloads those bytes into a new temporary directory, repeats the full signature/notarization/Gatekeeper/ZIP/DMG/provenance/Sparkle verification, and only then makes the release public and latest.

Production readiness also verifies the clean-install Time Machine system-support report against the exact installed app, source commit, immutable build identity, app CDHash, helper CDHash, enabled registration states, authenticated readiness result, and supported cleanup state. A report from a different candidate or a development machine with retained registration state cannot satisfy the gate.

One marketing-version/build-number pair identifies one immutable signed app. `Scripts/install-app.sh` refuses to replace an installed Delta app with different signed bytes carrying the same `CFBundleShortVersionString` and `CFBundleVersion`; advance `CURRENT_PROJECT_VERSION` before building a replacement. This prevents local build/test churn from presenting macOS Service Management with two helper executables under one release identity and makes installed acceptance match the update topology users receive through Sparkle.

## GitHub Actions

CI runs the certificate-free gate on `macos-26` and `macos-26-intel`. This path uses the real Xcode target graph with an ad-hoc signature and cannot create a publishable artifact. Because Apple only grants the restricted FSKit module entitlement through provisioning, the certificate-free builder embeds an intentionally inert extension compiled without that entitlement or a provisioning profile. Its contract self-test proves the extension remains ad-hoc, teamless, unprovisioned, and unentitled, and proves that entitlement-bearing or profile-bearing fixtures are rejected. Normal Xcode and Developer ID builds keep the entitlement input enabled; the shipping validator independently rejects any archive missing the exact entitlement or matching distribution profile.

Automated release publishing is disabled unless repository variable `DELTA_RELEASE_AUTOMATION_ENABLED` is exactly `true` and the protected `release` environment contains:

- `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_DEVELOPMENT_TEAM`
- `APP_STORE_CONNECT_KEY_P8_BASE64`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY_BASE64`

The workflow keeps notarization logs and dSYMs as private workflow artifacts and removes materialized credentials even after failure.
