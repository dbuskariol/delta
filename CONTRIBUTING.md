# Contributing to Delta

Delta targets macOS 26 and Swift 6. Keep changes focused, fail closed on backup/restore safety, and include tests for policy or persistence behavior.

## Development setup

```sh
Scripts/bootstrap-tools.sh
swift test
Scripts/verify-ci.sh
```

Use Xcode 26.5 or later. The app can be run from the `Delta.xcodeproj` scheme after its packages resolve. A stable Apple Development or Developer ID signature is recommended for installed-app testing because Keychain and macOS privacy grants are tied to code identity.

## Change expectations

- Preserve restic's technical exit status and audit evidence; do not convert an incomplete backup into a successful one.
- Keep secrets out of arguments, logs, diagnostics, fixtures, and the repository.
- Add or update tests when command construction, validation, scheduling, restore behavior, persistence, redaction, or UI contracts change.
- Run the CI gate before submitting a change. Release-related changes must also pass rehearsal mode.
- Keep user-facing wording aligned between the app, README, release notes, and production-readiness documentation.
- Do not commit `dist`, bundled downloaded tools, local acceptance evidence, dSYMs, notarization logs, certificates, provisioning material, or private update keys.

## Issues and pull requests

Describe the user-visible problem, the safety implications, and how the change was verified. Use private vulnerability reporting for security issues that could expose data or credentials.
