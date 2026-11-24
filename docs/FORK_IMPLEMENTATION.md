# RuTor and playback changes in the personal fork

## Approved scope

- Refresh the fork from upstream main and retain the two issue screenshots.
- Add one public RuTor provider to the existing search view.
- Copy the selected torrent file's local stream URL.
- Generate/open and save UTF-8 M3U playlists for an already added torrent.
- Add independent extension theme selection: system, light, dark, follow Multron.

Upstream base: `636903113c4df86a2083b591f96a025c8b2d33ce` (v1.0.2).
Screenshot preservation commit: `75c65e83e11af31985c8e3681068d8330f3a8eff`.
Original fork is retained in `codex/backup-before-upstream-20261124` at `84e9c1aaad23e13de89a9e3b8fc2cfa79dbe7e48`.
Development branch: `codex/rutor-stream-playlists`.

## Implementation and verification

RuTor uses its public HTTP search page and bounded HTML parsing, with existing result/download UI. Provider redirects are validated before following each hop. Playback URLs authorize a single torrent file for this app session; request logs redact their tokens. Deselection and removal revoke permissions and cancel active readers, including when a player stops consuming the HTTP response. Playlist destinations are generated in the app cache or explicitly selected by the user.

Copy Stream URL is available for any included torrent file. Play/save actions cover the common audio/video formats, including MPEG, M2TS, VOB and WMA. A playlist association or a player that can open network streams is required for playback. Cached/exported URLs stop working when this app exits or access to the file is revoked.

The extension keeps its chosen theme mode separately from the cached desktop theme, defaults to following Multron, and updates open popups/overlays when the OS theme changes. Shared binding code handles initialization, storage changes and live system changes. A portable copy only removes Windows Native Messaging registrations that belong to its own data directory.

Required checks: parser/playlist tests, live public RuTor search, full repository tests and checks, Windows build, and independent theme persistence/OS-change checks. Runtime verification must use a separate portable data directory and app identity so the installed Multron and its downloads continue running.

Browser-session transport, protected trackers, viewing directly from search, browser preview, accent synchronization and glass styles are outside this first implementation.
