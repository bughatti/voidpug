# VoidPug

**Track pug raid lockouts automatically — never lose contact with a good pug leader.**

VoidPug quietly records every Heroic and Mythic raid pug you join: the leader, the full roster, every boss kill, and when the lockout resets. When the same group re-forms next week, you'll have their contact info ready to whisper or invite.

---

## Features

### Auto-capture — no clicks needed
- **Raid and difficulty** — detected when you zone in
- **Group leader** — identified from the raid's leader flag
- **Full roster** — everyone who was in the raid, with first- and last-seen times
- **Boss kills** — recorded with timestamps
- **Reset countdown** — how long until the lockout expires

### Contact details from chat
- **Battle.net tags** — any `Name#1234` posted in raid, party, or whisper chat is captured and tied to the sender
- **Discord handles** — picks up `discord: name`, `disc: name`, `dc: name`, and "my discord is …"
- **Friends list** — if the leader is already your Battle.net friend, their tag fills in automatically

### Smart roster view
- **Current vs dropped** — white = still in the raid, dimmed "(left)" = dropped earlier
- **Join/leave times** are kept so you know who stuck around

### One-click contact
- **Whisper** — uses their Battle.net tag if known, otherwise a cross-realm `/w Name-Realm`
- **Add WoW Friend** — character friend add, no tag needed
- **Add Battle.net friend** — opens the add-friend dialog with the tag pre-filled

### Never lose a capture
- **Raid-end reminder** — when you leave the raid, chat offers a one-click save
- **Save button** and a **last-saved** indicator in the panel header
- **Reset reminders** — a heads-up 24 hours before your lockout resets

### Minimap button
- Left-click to open the panel, right-click to save, drag to move it around the minimap
- Grouped under the shared **Void hub** icon by default — `/vhub satellites` shows individual Void icons

---

## Slash Commands

| Command | What it does |
|---|---|
| `/vpt` | Open or close the panel (also `/pugs`) |
| `/vpt save` | Save data to disk now (does a /reload) |
| `/vpt refresh` | Re-check your raid lockouts |
| `/vpt minimap` | Show or hide VoidPug's own minimap icon (when individual Void icons are on — `/vhub satellites`) |
| `/vpt reminders` | Turn the reset reminders on or off |
| `/vpt migrate` | Merge duplicate lockout entries |
| `/vpt clear` | Delete ALL data (asks to confirm) |
| `/vpt debug` | Print the current raid info (troubleshooting) |

---

## Getting Started

1. Install with the CurseForge app, or copy the `VoidPug` folder into `World of Warcraft/_retail_/Interface/AddOns/`.
2. Restart WoW or `/reload`.
3. Join any Heroic or Mythic raid pug — an entry is created automatically.
4. When the raid ends, click **Save** when the chat reminder appears.
5. Next week: open `/vpt`, find the group, and whisper the leader.

---

## Good to Know

- **Why tags are sometimes missing:** WoW only reveals Battle.net tags of people already on your friends list. VoidPug fills them in when someone shares theirs in chat or after you add them — or paste one in with the **Edit** button.
- Your lockout history is saved account-wide, so every character sees it.

---

## Compatibility

- **WoW 12.1** (Midnight Season 2)
- Standalone — nothing else to install
- Combat-safe and taint-free — works alongside any UI addon

---

*Part of the Void addon family by Vede · MIT licensed · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more addons & apps at [tinkerline.io](https://tinkerline.io) · [Discord](https://discord.gg/7ZHmx7zMDh)*
