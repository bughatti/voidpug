# Changelog

## [0.5.2] — 2026-06-20

### Compatibility
- Updated for WoW **12.0.7** (Sporefall). Verified every C_* API call against the patched client — all present; no code changes needed.


## [0.5.1] — 2026-06-03

### Bug fixes
- **Embedded VoidLib.** Previous releases declared `## Dependencies: VoidLib`
  but VoidLib was never published to CurseForge as a standalone addon, so
  installs from CurseForge would fail to load with "Dependency: VoidLib is
  missing." VoidLib is now bundled under `Libs/VoidLib/` — no separate
  addon required.

All notable changes to VoidPug will be documented here.

## [0.1.2] — 2026-05-21

### Bug fixes
- **Fix Lua error on BN whispers**: Chat-message body and sender strings from
  CHAT_MSG_BN_WHISPER and similar events can arrive as 12.0.5 "secret string
  values" that throw `attempt to compare local 'message' (a secret string
  value)` errors. Added `issecretvalue()` guards in `ExtractBtags`,
  `ExtractDiscords`, and `NormalizeName` — secret-tainted strings are skipped
  silently (we can't parse battletags/Discord handles out of them anyway).
- No functional change for regular guild/party chat parsing; this only
  affected BN-whisper-derived messages.

## [0.1.1] — 2026-05-17

### Bug fixes
- Removed registration for `BOSS_KILL_UNFILTERED` — that event doesn't exist
  in WoW 12.0 (Midnight). The bad registration was throwing an Init error
  on every login: `Frame:RegisterEvent(): Attempt to register unknown event
  "BOSS_KILL_UNFILTERED"`. Boss-kill capture still works via `BOSS_KILL` and
  `ENCOUNTER_END` (the active codepaths) — the unfiltered variant was a
  redundant fallback that never fired anyway.

## [0.1.0] — 2026-05-15

Initial release.

### Features
- Auto-captures raid lockout data (name, difficulty, leader, roster, boss kills, reset time)
- Chat scanner auto-detects Battle.net tags (`Name#1234`) shared by raid members
- Chat scanner auto-detects Discord handles (`discord: name`, `disc: name`, `dc: name`, old-format `name#1234`)
- Battle.net friend lookup auto-fills btag if the leader is already on your friend list
- Smart roster tracking: per-player `firstSeen`/`lastSeen` timestamps distinguish current vs dropped raiders
- Whisper button adapts: uses btag if known, falls back to character whisper
- Add WoW Friend + Add Bnet helpers
- Raid-end auto-alert with save-to-disk prompt
- Save (/reload) button + `/vpt save` slash command for explicit flush
- Last-saved indicator in panel header (green/gold/red based on age)
- 24-hour reset reminder on login for unfinished lockouts
- Standardized minimap button (drag-to-orbit, per-character position)
- Migration system handles old data with key drift or missing reset timestamps
- ESC closes panel

### WoW 12.0.5 (Midnight) compatibility
- Uses `C_DateAndTime.GetSecondsUntilWeeklyReset()` as reset fallback when saved-instance API hasn't populated
- Respects all public APIs; no combat operations; no taint
