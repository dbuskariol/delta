# Delta 0.3.3

Delta 0.3.3 restores live Activity output following:

- Keeps the Output view scrolled to the newest line as backup logs arrive.
- Continues refreshing long runs after the bounded live-log window reaches 200 entries by tracking the newest persisted log rather than the unchanged row count.
- Retains bounded, lazy log rendering and stable loading of earlier output.

Requires macOS 26 or later. Install from the notarized DMG for drag-to-Applications setup; the signed/notarized ZIP is provided for Sparkle updates and manual installation.
