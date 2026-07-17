# Delta 0.3.1

Delta 0.3.1 is a focused Scheduled Backups hotfix:

- Fixes fresh installations reporting that the scheduled-backup service is missing even though `DeltaAgent` is present in the app.
- Places the signed scheduler executable in the Service Management resource location referenced by its bundled launch-agent property list.
- Keeps scheduler-to-app execution correct from the new bundle location.
- Adds installed-app verification of the real `SMAppService` discovery status so a directly executable helper can no longer be mistaken for a registerable scheduled service.

Requires macOS 26 or later. Install from the notarized DMG for drag-to-Applications setup; the signed/notarized ZIP is provided for Sparkle updates and manual installation.
