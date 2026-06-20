# VoidPug

**Track pug raid lockouts automatically — never lose contact with a good pug leader.**

VoidPug silently records every Mythic and Heroic raid pug you join: the leader, the full roster, every boss kill, and the reset timestamp. When next reset rolls around and the same group reforms, you'll have the contact info ready to whisper or invite.

---

## Why this exists

You spent 4 hours pugging Mythic Voidspire with a chill group. You killed 3 bosses. The raid ends, the group disbands, and... you have no way to reconnect with them next week. By reset time, you've forgotten who led, who tanked, and definitely who shared their btag in chat.

VoidPug captures all of that **automatically** so you can re-form with the same group next reset and keep clearing your lockout.

---

## Features

### 🎯 Auto-capture (no clicks needed)
- **Raid name + difficulty** detected on instance entry
- **Group leader** identified via raid LEAD flag
- **Full roster** (every player who was in the raid, with first/last-seen timestamps)
- **Boss kills** recorded with timestamps via `ENCOUNTER_END` + saved-instance API fallback
- **Reset countdown** via `GetSavedInstanceInfo` with weekly-reset fallback for fresh instances

### 🔍 Auto-detection from chat
- **Battle.net tags**: any `Name#1234` posted in raid/party/whisper chat gets captured and tied to the sender (or whoever's name appears alongside it)
- **Discord handles**: matches patterns like `discord: bonkdk`, `disc: handle`, `dc: foo`, `my discord is X`
- **Bnet friend lookup**: if the leader is already on your Battle.net friend list, btag auto-fills

### 🎨 Smart roster view
- **Current vs dropped**: white = still in raid, dimmed "(left)" = was here earlier but dropped
- **Per-player timestamps** preserved across captures so you know when people joined/left

### 📞 One-click contact
- **Whisper button**: uses btag if known, falls back to `/w Name-Realm` cross-realm whisper
- **Add WoW Friend**: instant character-only friend add (no btag required)
- **Add Bnet**: opens add-friend dialog with btag pre-printed if captured

### 💾 Reliable persistence
- **Raid-end alert**: when you leave the raid, chat prompts with a one-click save reminder
- **Save (/reload) button**: flushes in-memory data to disk on demand
- **Last-saved indicator** in the panel header so you know how stale your in-memory state is

### 🗺️ Minimap button
- Left-click: toggle panel
- Right-click: save (/reload)
- Drag to orbit around minimap edge
- Per-character position saved

---

## Slash commands

| Command | Action |
|---|---|
| `/vpt` | Toggle panel (also `/pugs`) |
| `/vpt save` | Flush data to disk (does /reload) |
| `/vpt refresh` | Re-poll WoW raid info |
| `/vpt minimap` | Toggle minimap button |
| `/vpt clear` | Delete ALL data (confirmation popup) |
| `/vpt migrate` | Re-key + merge duplicate lockout entries |
| `/vpt reminders` | Toggle 24h-reset chat alerts |
| `/vpt debug` | Print current raid context (troubleshooting) |

---

## How to use

1. **Install** to `Interface/AddOns/VoidPug/`
2. Reload your UI (`/reload`)
3. **Join any Heroic or Mythic raid** — entry auto-creates
4. **Anyone shares their btag in chat?** Auto-captured for that character
5. **Raid ends** — chat alert prompts you to save
6. Click **`💾 Save (/reload)`** in the panel or type `/vpt save`
7. **Next reset week**: open `/vpt`, find the entry, click **`Bnet Whisper`** → contact saved
8. Done.

---

## Why btags are sometimes missing

WoW's API restricts battletag lookups to your **existing Bnet friend list** for privacy. The addon can't see strangers' btags. To get someone's btag automatically:
- They share it in chat (auto-detected ✅)
- You add them as a friend first (then their btag is visible)

If neither happens, you can manually paste the btag via the **Edit** button on the Btag field.

---

## Storage

- **`VoidPugDB`** (account-wide): All lockout entries with rosters, kills, btags, notes
- **`VoidPugCharDB`** (per-character): Minimap button position, visibility preference

---

## Compatibility

- **WoW Interface 12.0.5** (Midnight)
- Works alongside any UI addon (ElvUI, VoidUI, etc.)
- No taint — uses only public APIs (`GetInstanceInfo`, `GetRaidRosterInfo`, `C_DateAndTime`, etc.)
- No combat operations — safe to use mid-raid

---

## Credits

Built for Vede on Elune. Inspired by the eternal frustration of losing track of a great pug group after one good run.
