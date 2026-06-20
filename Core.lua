-- VoidSpy hook: enable with /vspy enable VoidPug  (no-op if VoidSpy missing/disabled)
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidPug", fmt, ...) end end

----------------------------------------------------------------------
-- VoidPug Core — namespace, saved vars, utilities
-- Tracks raid lockouts you joined via pug groups so you can re-contact
-- leaders for follow-up clears. Captures roster + bosses + leader info
-- automatically; you add btag/Discord/notes by hand.
----------------------------------------------------------------------
local ADDON_NAME, VPT = ...
_G.VoidPug = VPT

VPT.version = "0.5.0"

----------------------------------------------------------------------
-- Color palette (matches VoidFisher / VoidUI cyan theme)
----------------------------------------------------------------------
VPT.palette = {
    accent  = { 0.00, 0.78, 1.00 },
    text    = { 0.92, 0.92, 0.95 },
    textDim = { 0.55, 0.55, 0.62 },
    green   = { 0.10, 0.80, 0.35 },
    gold    = { 1.00, 0.84, 0.00 },
    red     = { 1.00, 0.30, 0.30 },
}

VPT.C_CYAN   = "|cFF00C7FF"
VPT.C_GOLD   = "|cFFFFD100"
VPT.C_GREEN  = "|cFF00FF00"
VPT.C_RED    = "|cFFFF4444"
VPT.C_DIM    = "|cFF8C8C9E"
VPT.C_WHITE  = "|cFFFFFFFF"
VPT.C_PURPLE = "|cFFB48EF7"
VPT.C_ORANGE = "|cFFFF9900"

----------------------------------------------------------------------
-- Difficulty IDs we care about (raid difficulties only)
-- Source: WoW API Enum.Difficulty
----------------------------------------------------------------------
VPT.RAID_DIFFICULTY = {
    [14] = "Normal",       -- Normal raid
    [15] = "Heroic",       -- Heroic raid
    [16] = "Mythic",       -- Mythic raid
    [17] = "LFR",          -- Looking for Raid
    [33] = "Timewalking",  -- Timewalking raid
}

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
function VPT.SetFont(fs, size, flags)
    if not fs or not fs.SetFont then return end
    fs:SetFont("Fonts\\FRIZQT__.TTF", size or 11, flags or "")
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
end

function VPT.CreateBackdrop(frame, opacity)
    if not frame or not frame.SetBackdrop then return end
    opacity = opacity or 0.92
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.05, 0.07, opacity)
    frame:SetBackdropBorderColor(0, 0.78, 1, 0.5)
end

function VPT.FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

function VPT.FormatTimestamp(ts)
    if not ts or ts == 0 then return "?" end
    return date("%m/%d %H:%M", ts)
end

----------------------------------------------------------------------
-- Lockout key — uniquely identifies a raid lockout for tracking.
-- WoW's GetInstanceInfo() doesn't expose a stable lockoutID, so we use
-- (raidName + difficulty + weekAnchor) as a composite key. The week
-- anchor rounds resetTime to a 7-day window — any captures within the
-- same lockout (which is at most 7 days) share an anchor and dedupe.
--
-- Earlier version used 60-second rounding which produced duplicate
-- entries every minute due to WoW's GetSavedInstanceInfo resetSec
-- jitter of ±1s. Week-rounding is robust to that.
----------------------------------------------------------------------
function VPT.MakeLockoutKey(raidName, difficulty, resetTime)
    local rt = tonumber(resetTime) or 0
    local anchor = math.floor(rt / 604800) * 604800   -- 7 days in seconds
    return string.format("%s|%s|%d",
        tostring(raidName or "?"),
        tostring(difficulty or "?"),
        anchor)
end

----------------------------------------------------------------------
-- Saved-data accessors. Each lockout entry:
-- {
--   key             = string (MakeLockoutKey output),
--   raidName        = "The Voidspire",
--   difficulty      = "Mythic",
--   instanceID      = number (engine instance ID — not stable cross-session),
--   firstJoined     = unix time when first detected,
--   lastSeen        = unix time of latest activity,
--   resetTime       = unix time when lockout expires,
--   leader          = "Name-Realm" of group leader at last capture,
--   roster          = { "Name-Realm", ... } unique names from last roster capture,
--   rosterDetails   = { ["Name-Realm"] = { firstSeen, lastSeen, class?, classFile?, role?, level? } },
--   kills           = { { boss = "Name", time = unix, encounterID = id }, ... },
--   btag            = user-filled string (e.g. "Bonk#1234"),
--   discord         = user-filled string,
--   notes           = user-filled string,
-- }
-- NOTE: "expired" is computed on read (resetTime < now), never persisted.
-- NOTE: difficultyID and knownEncounters were removed — never read by anything.
----------------------------------------------------------------------
function VPT.GetDB()
    if not VoidPugDB then VoidPugDB = {} end
    if not VoidPugDB.lockouts then VoidPugDB.lockouts = {} end
    if not VoidPugDB.config then VoidPugDB.config = {} end
    local cfg = VoidPugDB.config
    if cfg.resetReminderEnabled == nil then cfg.resetReminderEnabled = true end
    if cfg.autoPrintOnJoin       == nil then cfg.autoPrintOnJoin       = true end
    if cfg.minDifficultyToTrack  == nil then cfg.minDifficultyToTrack  = "Heroic" end
    if cfg.retentionDays         == nil then cfg.retentionDays         = 30   end
    return VoidPugDB
end

----------------------------------------------------------------------
-- Alt linking — cluster character names by battletag so we know which
-- toons belong to the same human. Populated by Events.lua whenever a
-- btag gets associated with a Name-Realm (from chat scrape or BNet
-- friend lookup). Stored under VoidPugDB.players for cross-character
-- query: "give me all known alts of Bewarl#2607" or "who's the human
-- behind Beews-Frostmourne?".
----------------------------------------------------------------------
function VPT.LinkCharToBtag(charNameRealm, btag)
    if not charNameRealm or not btag or btag == "" then return end
    local db = VPT.GetDB()
    db.players = db.players or {}
    local p = db.players[btag]
    if not p then
        p = { chars = {}, lastSeen = time() }
        db.players[btag] = p
    end
    -- Add char if not already present
    local seen = false
    for _, n in ipairs(p.chars) do if n == charNameRealm then seen = true; break end end
    if not seen then table.insert(p.chars, charNameRealm) end
    p.lastSeen = time()
end

function VPT.GetCharsForBtag(btag)
    if not btag then return {} end
    local db = VPT.GetDB()
    if not db.players or not db.players[btag] then return {} end
    return db.players[btag].chars or {}
end

function VPT.GetBtagForChar(charNameRealm)
    if not charNameRealm then return nil end
    local db = VPT.GetDB()
    if not db.players then return nil end
    for btag, p in pairs(db.players) do
        for _, n in ipairs(p.chars or {}) do
            if n == charNameRealm then return btag end
        end
    end
    return nil
end

----------------------------------------------------------------------
-- PruneOldLockouts — remove entries whose resetTime expired more than
-- retentionDays ago (default 30). Run once at PLAYER_LOGIN. User can
-- disable by setting VoidPugDB.config.retentionDays = 0.
----------------------------------------------------------------------
function VPT.PruneOldLockouts()
    local db = VPT.GetDB()
    local days = db.config.retentionDays or 30
    if days <= 0 then return 0 end
    local cutoff = time() - (days * 86400)
    local pruned = 0
    for key, entry in pairs(db.lockouts) do
        local rt = entry.resetTime or entry.lastSeen or 0
        if rt > 0 and rt < cutoff then
            db.lockouts[key] = nil
            pruned = pruned + 1
        end
    end
    return pruned
end

function VPT.GetCharDB()
    if not VoidPugCharDB then VoidPugCharDB = {} end
    if VoidPugCharDB.minimapAngle == nil then
        VoidPugCharDB.minimapAngle = 195
    end
    if VoidPugCharDB.minimapHidden == nil then
        VoidPugCharDB.minimapHidden = false
    end
    return VoidPugCharDB
end

----------------------------------------------------------------------
-- SaveNow — flush to disk via /reload. SavedVariables only persist on
-- /reload or /logout, so for "save" we issue a UI reload. Combat-safe.
-- Hoisted from 4 duplicate call sites (UI buttons + minimap right-click +
-- /vpt save command).
----------------------------------------------------------------------
function VPT.SaveNow()
    if InCombatLockdown() then
        VPT.Print(VPT.C_RED .. "Can't /reload during combat.|r")
        return false
    end
    VPT.Print(VPT.C_GREEN .. "Saving to disk...|r")
    C_Timer.After(0.3, function() ReloadUI() end)
    return true
end

----------------------------------------------------------------------
-- SafeIsEmpty — guard for 12.0+ secret values in chat strings.
-- Returns true if `s` is nil, a secret value, or an empty string.
-- Replaces 3 separate pcall sandwiches in Events.lua.
-- The secret-value predicate is now sourced from VoidLib.
----------------------------------------------------------------------
function VPT.SafeIsEmpty(s)
    if s == nil then return true end
    if VoidLib.Secrets.IsSecret(s) then return true end
    local ok, empty = pcall(function() return s == "" end)
    if not ok then return true end
    return empty
end

----------------------------------------------------------------------
-- Merge two lockout entries into one (entry A is the keeper).
-- - kills: union, dedupe by encounterID (or boss name if no ID)
-- - roster: union, dedupe
-- - timestamps: keep min(firstJoined), max(lastSeen), max(resetTime)
-- - user fields (btag/discord/notes): prefer non-empty
-- - leader: prefer non-empty, prefer later capture if both set
----------------------------------------------------------------------
function VPT.MergeEntries(a, b)
    if not a then return b end
    if not b then return a end

    -- Kills: dedupe by encounterID, fall back to boss name
    local seenID, seenName = {}, {}
    local merged = {}
    local function addKills(list)
        if not list then return end
        for _, k in ipairs(list) do
            local idKey = k.encounterID and ("id:" .. k.encounterID) or nil
            local nameKey = k.boss and ("n:" .. k.boss) or nil
            if (idKey and seenID[idKey]) or (nameKey and seenName[nameKey]) then
                -- duplicate
            else
                if idKey then seenID[idKey] = true end
                if nameKey then seenName[nameKey] = true end
                table.insert(merged, k)
            end
        end
    end
    addKills(a.kills)
    addKills(b.kills)
    -- Sort kills by time ascending
    table.sort(merged, function(x, y) return (x.time or 0) < (y.time or 0) end)
    a.kills = merged

    -- Roster: union
    local rseen = {}
    local rmerged = {}
    for _, n in ipairs(a.roster or {}) do
        if not rseen[n] then rseen[n] = true; table.insert(rmerged, n) end
    end
    for _, n in ipairs(b.roster or {}) do
        if not rseen[n] then rseen[n] = true; table.insert(rmerged, n) end
    end
    a.roster = rmerged

    -- Timestamps
    a.firstJoined = math.min(a.firstJoined or math.huge, b.firstJoined or math.huge)
    if a.firstJoined == math.huge then a.firstJoined = time() end
    a.lastSeen   = math.max(a.lastSeen or 0, b.lastSeen or 0)
    a.resetTime  = math.max(a.resetTime or 0, b.resetTime or 0)

    -- Leader: prefer most recent non-empty
    if (not a.leader or a.leader == "") and b.leader and b.leader ~= "" then
        a.leader = b.leader
    elseif a.leader and b.leader and (a.lastSeen or 0) < (b.lastSeen or 0) then
        a.leader = b.leader
    end

    -- User fields: prefer non-empty (a wins if both set)
    if (not a.btag    or a.btag    == "") and b.btag    then a.btag    = b.btag    end
    if (not a.discord or a.discord == "") and b.discord then a.discord = b.discord end
    if (not a.notes   or a.notes   == "") and b.notes   then a.notes   = b.notes   end

    -- Rating: prefer the higher rating (someone explicitly set it; null
    -- means unrated so a real value always wins)
    if b.rating and (not a.rating or b.rating > a.rating) then a.rating = b.rating end

    -- Tags: union by lowercase, preserve original casing from `a` when both
    if b.tags and #b.tags > 0 then
        a.tags = a.tags or {}
        local seen = {}
        for _, t in ipairs(a.tags) do seen[t:lower()] = true end
        for _, t in ipairs(b.tags) do
            if not seen[t:lower()] then
                table.insert(a.tags, t)
                seen[t:lower()] = true
            end
        end
    end

    -- rosterDetails: merge maps. firstSeen = min, lastSeen = max,
    -- class/role/level prefer non-nil (most recent wins via lastSeen tiebreak)
    if b.rosterDetails then
        a.rosterDetails = a.rosterDetails or {}
        for name, bInfo in pairs(b.rosterDetails) do
            local aInfo = a.rosterDetails[name]
            if not aInfo then
                a.rosterDetails[name] = {
                    firstSeen = bInfo.firstSeen,
                    lastSeen  = bInfo.lastSeen,
                    classFile = bInfo.classFile,
                    class     = bInfo.class,
                    role      = bInfo.role,
                    level     = bInfo.level,
                }
            else
                aInfo.firstSeen = math.min(aInfo.firstSeen or math.huge, bInfo.firstSeen or math.huge)
                if aInfo.firstSeen == math.huge then aInfo.firstSeen = time() end
                local bNewer = (bInfo.lastSeen or 0) > (aInfo.lastSeen or 0)
                if bNewer then
                    aInfo.lastSeen = bInfo.lastSeen
                    if bInfo.classFile then aInfo.classFile = bInfo.classFile end
                    if bInfo.class     then aInfo.class     = bInfo.class     end
                    if bInfo.role      then aInfo.role      = bInfo.role      end
                    if bInfo.level     then aInfo.level     = bInfo.level     end
                else
                    -- Fill in any nil fields from b without overwriting newer values
                    if not aInfo.classFile and bInfo.classFile then aInfo.classFile = bInfo.classFile end
                    if not aInfo.class     and bInfo.class     then aInfo.class     = bInfo.class     end
                    if not aInfo.role      and bInfo.role      then aInfo.role      = bInfo.role      end
                    if not aInfo.level     and bInfo.level     then aInfo.level     = bInfo.level     end
                end
            end
        end
    end

    return a
end

----------------------------------------------------------------------
-- Migration: walk all lockouts, recompute keys with current MakeLockoutKey,
-- merge collisions. Idempotent — safe to run multiple times.
-- Run once per session at PLAYER_LOGIN.
----------------------------------------------------------------------
function VPT.MigrateLockoutKeys()
    local db = VPT.GetDB()
    local old = db.lockouts
    if not old then return 0, 0 end

    -- Collect entries grouped by their CORRECT new key
    local groups = {}
    local examined = 0
    for oldKey, entry in pairs(old) do
        examined = examined + 1
        local newKey = VPT.MakeLockoutKey(entry.raidName, entry.difficulty, entry.resetTime)
        entry.key = newKey
        groups[newKey] = groups[newKey] or {}
        table.insert(groups[newKey], entry)
    end

    -- Build the new flat table by merging within each group
    local rebuilt = {}
    local merged = 0
    for newKey, list in pairs(groups) do
        if #list == 1 then
            rebuilt[newKey] = list[1]
        else
            -- Merge sequentially, prefer the one with most kills as base
            table.sort(list, function(x, y)
                return #(x.kills or {}) > #(y.kills or {})
            end)
            local base = list[1]
            for i = 2, #list do
                base = VPT.MergeEntries(base, list[i])
                merged = merged + 1
            end
            rebuilt[newKey] = base
        end
    end

    db.lockouts = rebuilt

    -- Second pass: clean up "bogus" entries (resetTime <= 0 or 0/nil)
    -- which were created before we had a fallback. If a bogus entry's
    -- raidName + difficulty matches an active entry, merge into the
    -- active one. Otherwise the entry has no real lockout association
    -- and gets deleted.
    local bogusKeys = {}
    for key, entry in pairs(db.lockouts) do
        if not entry.resetTime or entry.resetTime <= 0 then
            table.insert(bogusKeys, key)
        end
    end

    local cleaned = 0
    for _, bogusKey in ipairs(bogusKeys) do
        local bogus = db.lockouts[bogusKey]
        if bogus then
            -- Look for an active entry with same raidName + difficulty
            local target = nil
            for key, entry in pairs(db.lockouts) do
                if key ~= bogusKey
                   and entry.raidName == bogus.raidName
                   and entry.difficulty == bogus.difficulty
                   and entry.resetTime and entry.resetTime > 0 then
                    target = entry
                    break
                end
            end
            if target then
                -- Merge bogus into target, then delete bogus
                VPT.MergeEntries(target, bogus)
                db.lockouts[target.key or VPT.MakeLockoutKey(
                    target.raidName, target.difficulty, target.resetTime)] = target
                db.lockouts[bogusKey] = nil
                cleaned = cleaned + 1
            else
                -- No active match — delete the bogus entry outright
                db.lockouts[bogusKey] = nil
                cleaned = cleaned + 1
            end
        end
    end

    return examined, merged, cleaned
end

function VPT.GetLockout(key)
    local db = VPT.GetDB()
    return db.lockouts[key]
end

function VPT.PutLockout(key, entry)
    local db = VPT.GetDB()
    db.lockouts[key] = entry
end

function VPT.DeleteLockout(key)
    local db = VPT.GetDB()
    db.lockouts[key] = nil
end

----------------------------------------------------------------------
-- Iterate lockouts: returns sorted active first, then expired.
-- callback(key, entry, isExpired) — return false to stop.
----------------------------------------------------------------------
function VPT.ForEachLockout(callback)
    local db = VPT.GetDB()
    local now = time()
    local active, expired = {}, {}
    for key, entry in pairs(db.lockouts) do
        if entry.resetTime and entry.resetTime > now then
            table.insert(active, { key = key, entry = entry })
        else
            table.insert(expired, { key = key, entry = entry })
        end
    end
    -- Sort active by soonest reset
    table.sort(active, function(a, b)
        return (a.entry.resetTime or 0) < (b.entry.resetTime or 0)
    end)
    -- Sort expired by most recent first
    table.sort(expired, function(a, b)
        return (a.entry.lastSeen or 0) > (b.entry.lastSeen or 0)
    end)
    for _, row in ipairs(active) do
        if callback(row.key, row.entry, false) == false then return end
    end
    for _, row in ipairs(expired) do
        if callback(row.key, row.entry, true) == false then return end
    end
end

function VPT.CountLockouts()
    local active, expired = 0, 0
    local now = time()
    local db = VPT.GetDB()
    for _, e in pairs(db.lockouts) do
        if e.resetTime and e.resetTime > now then
            active = active + 1
        else
            expired = expired + 1
        end
    end
    return active, expired
end

----------------------------------------------------------------------
-- Print helper
----------------------------------------------------------------------
function VPT.Print(msg)
    print(VPT.C_CYAN .. "[VoidPug]|r " .. tostring(msg))
end

----------------------------------------------------------------------
-- Module registry (kept simple — only 2 modules: Events + UI)
----------------------------------------------------------------------
VPT._modules = {}
function VPT:NewModule(name)
    local m = { name = name }
    VPT._modules[name] = m
    return m
end

----------------------------------------------------------------------
-- ADDON_LOADED / PLAYER_LOGIN bootstrap
----------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_LOGOUT")
boot:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Migrate from the old VoidPugTracker namespace (v0.0.x).
        -- If the user has data from before the rename, the old globals will be
        -- present in the SavedVariables file. Copy them over so nothing is lost.
        if not VoidPugDB and _G.VoidPugTrackerDB then
            VoidPugDB = _G.VoidPugTrackerDB
            _G.VoidPugTrackerDB = nil  -- prevent re-migration; WoW won't persist it
            print("|cFF00C7FF[VoidPug]|r " .. "|cFF8C8C9EMigrated data from VoidPugTracker namespace.|r")
        end
        if not VoidPugCharDB and _G.VoidPugTrackerCharDB then
            VoidPugCharDB = _G.VoidPugTrackerCharDB
            _G.VoidPugTrackerCharDB = nil
        end

        VPT.GetDB()  -- ensure defaults

        -- (Removed: one-shot inline restore from the 2026-05-15 VoidPugTracker
        -- → VoidPug rename. The flag is preserved so any user who hasn't
        -- loaded since the rename still gets their data back from the OLD
        -- SavedVariables file rather than the inline literal — see
        -- VoidPugDB._restored_v1 below.)

        -- One-time-per-session migration to merge any lockout entries
        -- with drifted keys (e.g. from earlier 60s-rounding bug) and
        -- clean up bogus zero-resetTime entries.
        local examined, merged, cleaned = VPT.MigrateLockoutKeys()
        if (merged or 0) > 0 or (cleaned or 0) > 0 then
            VPT.Print(VPT.C_DIM .. "Migration: merged " .. (merged or 0) ..
                ", cleaned " .. (cleaned or 0) ..
                " bogus entries (examined " .. examined .. ").|r")
        end

        -- Auto-prune lockouts older than retentionDays (default 30)
        local pruned = VPT.PruneOldLockouts()
        if pruned > 0 then
            VPT.Print(VPT.C_DIM .. "Pruned " .. pruned ..
                " lockout(s) older than " ..
                (VoidPugDB.config.retentionDays or 30) .. " days.|r")
        end

        for name, mod in pairs(VPT._modules) do
            if mod.Init then
                local ok, err = pcall(mod.Init, mod)
                if not ok then
                    print("|cFFFF4444[VoidPug]|r Init error in " .. name .. ": " .. tostring(err))
                end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        for name, mod in pairs(VPT._modules) do
            if mod.Enable then
                local ok, err = pcall(mod.Enable, mod)
                if not ok then
                    print("|cFFFF4444[VoidPug]|r Enable error in " .. name .. ": " .. tostring(err))
                end
            end
        end
        VPT.Print(VPT.C_DIM .. "v" .. VPT.version .. " loaded. /vpt for panel.|r")
    elseif event == "PLAYER_LOGOUT" then
        -- Touch GetDB so defaults are written if user hasn't opened the
        -- panel this session. WoW persists SavedVariables on logout
        -- regardless, but this guarantees the table exists with config.
        VPT.GetDB()
    end
end)
