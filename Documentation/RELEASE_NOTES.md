# Delta 0.4.0

Delta 0.4.0 adds native Time Machine-format destinations:

- Presents a Delta-managed encrypted APFS sparsebundle to macOS Time Machine without first staging the complete disk locally.
- Stores changed 8 MiB bands as immutable remote objects behind a strictly bounded cache, and acknowledges synchronization only after remote verification and authenticated generation publication.
- Treats the cache as a performance window rather than a backup-size limit: verified dirty bands spill to invisible content-addressed remote objects under pressure, so a user-selected cache size cannot make a larger valid backup fail with local `ENOSPC`.
- Keeps repeated DiskImages reads fast with a fixed two-band authenticated memory window, in-place band-buffer reuse across local and rclone reads, and per-request temporary-object lifetime, without retaining an attachment's complete read stream in memory.
- Supports local or mounted paths, SFTP, S3-compatible storage, Backblaze B2, Azure Blob, Google Cloud Storage, OpenStack Swift, and configured rclone remotes. Restic REST and custom restic URLs remain Delta-format only.
- Adds native destination creation, connection, disconnection, backup triggering, remote verification, recovery-key export, existing-disk reconnection, permission guidance, dashboard status, menu-bar status, diagnostics, and update-safety controls.
- Makes ordinary disconnect behave like unplugging a physical Time Machine disk: the APFS disk detaches while its exact macOS destination identity remains available for native reconnect. Explicit removal requires the verified disk to be connected before deregistration and local cleanup.
- Routes Time Machine add/remove prerequisites through Delta's existing Permissions surface. Missing Full Disk Access stops before connection writes begin, opens the exact recovery page, and never exposes tmutil's Terminal-specific diagnostic as product guidance.
- Uses a user-approved FSKit extension, same-user storage service, and narrowly scoped on-demand setup helper with signed-peer validation, bounded operations, conservative rollback, remote writer leases, and fail-closed recovery.
- Enforces an owner-only sparsebundle source directory before every attach and accepts identical authenticated band rewrites without manufacturing a redundant remote payload or invalid generation.
- Persists an authenticated generation-and-digest rollback witness, verifies an unbroken retained manifest chain before mounting or maintenance, and binds cleanup to the exact verified head so a provider rollback cannot silently become authoritative.
- Presents missing or corrupt remote Time Machine data as a verification failure with one `Check Again` recovery action, while Activity retains the exact redacted object evidence for diagnosis and Dashboard reuses the same typed, nontechnical guidance.
- Distinguishes a detached drive, unavailable mounted path, rejected remote command, or provider timeout from damaged history; existing disks are never recreated on a fallback volume and receive one `Storage Unavailable` recovery action.
- Labels destination evidence as `Last Verified`, so a preserved successful timestamp cannot be mistaken for the time of a newer failed check.
- Verifies that an app-managed disk recovery key is retained under the immutable remote disk identity before removing any local configuration or bounded cache, including safe migration from early repository-scoped development keys.
- Keeps the bundled rclone backend working when Delta is installed in a folder or app name containing spaces, while still pinning execution to the verified sibling tool.
- Keeps Time Machine and restic repository semantics separate: macOS remains authoritative for Time Machine history and restores, while restic continues to own Delta-format backup, restore, retention, prune, and check behavior.
- Keeps automatic Time Machine system-support retries current without adding the same unchanged failure to Activity every minute.
- Keeps an automatic system-support check from monopolizing the Set Up action, and lets an explicit Set Up repair a stale helper or user-service registration through macOS Service Management.

This release also restores live Activity output following:

- Keeps the Output view scrolled to the newest line as backup logs arrive.
- Continues refreshing long runs after the bounded live-log window reaches 200 entries by tracking the newest persisted log rather than the unchanged row count.
- Retains bounded, lazy log rendering and stable loading of earlier output.
- Gives every timestamped output row one complete VoiceOver announcement containing its level and saved message.

Requires macOS 26 or later. Install from the notarized DMG for drag-to-Applications setup; the signed/notarized ZIP is provided for Sparkle updates and manual installation.
