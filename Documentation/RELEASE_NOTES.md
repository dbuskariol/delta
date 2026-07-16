# Delta 0.3.0

Delta 0.3.0 refreshes the app's native macOS Settings experience and strengthens workflow safety, operational privacy, and release verification:

- Rebuilds every Settings category with compact native cards, inset separators, icon-led rows, and consistently aligned controls.
- Adds a dedicated Permissions page for Full Disk Access, notifications, scheduled-backup approval, and saved-password readiness.
- Uses native popup menus for Settings choices and keeps descriptions readable beside switches and actions at every supported window size.
- Pins Settings to the bottom of the sidebar and removes the redundant readiness footer.
- Simplifies Delta's app icon and aligns its colour, weight, and visual language with Reccy while preserving Delta's backup identity.
- Gives each onboarding and empty state one clear primary action instead of duplicating page-level controls, and opens destination creation directly from Dashboard, Backups, and Restore.
- Replaces Restore's disabled first-run form and Activity's competing split-view placeholders with focused, full-width empty states.
- Adds a native Settings command with the standard Command-comma shortcut plus Command-1 through Command-5 navigation for Delta's primary sections.
- Confirms cleanup before permanently forgetting restore points, names the affected destination, and explains pruning and the optional follow-up repository check.
- Prevents a second background operation from starting while Delta already owns active work.
- Redacts structured retention metadata from Activity, summarizes generic operations as items, and bounds child-process output while preserving final diagnostics and complete JSON required for parsing.
- Strengthens certificate-free CI, source-to-artifact metadata checks, and the guarded stable-identity installer used for Keychain and macOS permission continuity.
- Uses correct singular schedule wording for one-minute custom intervals.
- Records the exact commit, app path, and CDHash after a successful release rehearsal so downstream evidence and production-readiness checks cannot accept stale artifacts, correctly validates Sparkle's signed release notes after Sparkle prepends its integrity warning, and keeps app and DMG notarization evidence under one verified artifact contract.

Requires macOS 26 or later. Install from the notarized DMG for drag-to-Applications setup; the signed/notarized ZIP is provided for Sparkle updates and manual installation.
