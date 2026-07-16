# Releasing Delta

Delta ships outside the Mac App Store as a universal, hardened, Developer ID-signed and notarized app. `Scripts/release.sh` is the only shipping build entry point. It archives and exports through Xcode's Developer ID distribution flow; it never assembles or outer `--deep` re-signs an app bundle.

## Invariants

A release must prove all of the following:

- A clean worktree, coherent semantic version and positive build number, and release notes headed exactly for that version.
- Bundle ID `com.delta.backup`, minimum macOS 26.0, and `arm64` plus `x86_64` slices in the app, helper tools, bundled backup tools, and Sparkle code.
- Timestamped Developer ID Application signatures from team `BJCVJ5G7MJ`, Hardened Runtime, strict nested signature validity, and no debug/runtime-exception entitlements.
- A no-tracking/no-collection privacy manifest with the required-reason declarations used by Delta.
- A product-specific Sparkle key, signed feeds, signed ZIP and external release notes, and verification before extraction.
- Separate Apple notarization submissions for the app archive and signed DMG, both accepted with zero issues, followed by stapling and Gatekeeper acceptance.
- Matching ZIP/DMG executables, dSYM UUIDs, checksums, and a manifest bound to the exact Git commit and tag.

The Developer ID private key, Sparkle private key, notarization credentials, dSYMs, `.xcarchive`, and Apple evidence stay private. Only the DMG, ZIP, appcast, release notes, checksums, and release manifest are public assets.

## Rehearsal

After committing release-source changes, run:

```sh
DELTA_CODESIGN_IDENTITY="Developer ID Application: Daniel Buskariol (BJCVJ5G7MJ)" \
DELTA_DEVELOPMENT_TEAM="BJCVJ5G7MJ" \
DELTA_SPARKLE_KEY_ACCOUNT="com.delta.backup.sparkle" \
Scripts/release.sh prepare
```

Rehearsal mode builds and validates the complete artifact graph but does not submit to Apple or mutate GitHub. Its manifest explicitly records that artifacts are not notarized, so rehearsal output cannot be confused with a shipping release.

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

## Publish

`Scripts/publish-release.sh` performs the publishing transaction. It re-runs the history/security audit, creates a draft with the six intended public assets, downloads those bytes into a new temporary directory, repeats the full signature/notarization/Gatekeeper/ZIP/DMG/provenance/Sparkle verification, and only then makes the release public and latest.

## GitHub Actions

CI runs the certificate-free gate on `macos-26` and `macos-26-intel`. This path uses the real Xcode target graph with an ad-hoc signature and cannot create a publishable artifact.

Automated release publishing is disabled unless repository variable `DELTA_RELEASE_AUTOMATION_ENABLED` is exactly `true` and the protected `release` environment contains:

- `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_DEVELOPMENT_TEAM`
- `APP_STORE_CONNECT_KEY_P8_BASE64`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY_BASE64`

The workflow keeps notarization logs and dSYMs as private workflow artifacts and removes materialized credentials even after failure.
