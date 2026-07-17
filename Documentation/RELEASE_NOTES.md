# Delta 0.3.2

Delta 0.3.2 completes the Scheduled Backups upgrade repair:

- Repairs a stale macOS scheduled-backup registration left in the missing-service state by an earlier Delta version when the current signed bundle contains the corrected scheduler.
- Uses the same direct Service Management registration that macOS accepts manually, without deleting profiles, credentials, local history, or backup repositories.
- Keeps a genuinely incomplete app bundle fail-closed: Delta still requires both the bundled scheduler and its launch-agent property list before attempting repair.

Requires macOS 26 or later. Install from the notarized DMG for drag-to-Applications setup; the signed/notarized ZIP is provided for Sparkle updates and manual installation.
