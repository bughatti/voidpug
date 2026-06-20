----------------------------------------------------------------------
-- VoidPug Events — auto-capture raid lockout data.
--
-- Strategy: on every raid-related event we poll WoW's GetInstanceInfo,
-- GetSavedInstanceInfo, GetRaidRosterInfo to update the current lockout
-- entry. We DON'T try to track every event in real time — we just
-- refresh the entry whenever something interesting fires.
----------------------------------------------------------------------
local _, VPT = ...
local mod = VPT:NewModule("Events")

local C_CYAN, C_GOLD, C_GREEN, C_RED, C_DIM, C_WHITE =
    VPT.C_CYAN, VPT.C_GOLD, VPT.C_GREEN, VPT.C_RED, VPT.C_DIM, VPT.C_WHITE

local eventFrame
local currentLockoutKey   -- key of the lockout we're actively tracking, or nil
local wasInRaid = false   -- previous-tick raid state for end-detection
local sessionStartTime = time()  -- when this addon session started (load/reload)

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Returns the "Name-Realm" form, defaulting realm to player's realm if absent.
-- 12.0.5 secret-string guard via VPT.SafeIsEmpty (returns true for nil,
-- secret-tainted values, or empty strings).
local function NormalizeName(name, realm)
    if VPT.SafeIsEmpty(name) then return nil end
    if realm and VoidLib.Secrets.IsSecret(realm) then realm = nil end
    if name:find("-") then return name end  -- already qualified
    if not VPT.SafeIsEmpty(realm) then return name .. "-" .. realm end
    return name .. "-" .. (GetRealmName() or "?")
end

-- Battletag regex: letters/digits then # then 4-5 digits.
-- WoW battletag spec: 3-12 char display name + # + 4-5 digit discriminator.
local BTAG_PATTERN = "([%w][%w_%-]+#%d+)"

-- Extract battletags from a chat message body. Returns array of matches.
local function ExtractBtags(message)
    if VPT.SafeIsEmpty(message) then return {} end
    local found = {}
    for m in string.gmatch(message, BTAG_PATTERN) do
        -- Sanity check: discriminator must be 4-5 digits
        local discriminator = m:match("#(%d+)")
        if discriminator and #discriminator >= 4 and #discriminator <= 5 then
            table.insert(found, m)
        end
    end
    return found
end

-- Discord patterns. The new Discord username format (no #discriminator) is
-- ambiguous so we ONLY match when preceded by an explicit label.
-- Examples we catch:
--   "discord: bonkdk"
--   "discord - bonkdk"
--   "Discord = bonkdk"
--   "disc: bonkdk"
--   "dc: bonkdk"
--   "my discord is bonkdk"
--   Old format: "bonkdk#1234" — but we lean on btag pattern for those
local DISCORD_LABEL_PATTERNS = {
    "[Dd][Ii][Ss][Cc][Oo][Rr][Dd]%s*[:=%-]%s*([%w][%w_%.]+)",
    "[Dd][Ii][Ss][Cc]%s*[:=%-]%s*([%w][%w_%.]+)",
    "[Dd][Cc]%s*[:=%-]%s*([%w][%w_%.]+)",
    "[Dd][Ii][Ss][Cc][Oo][Rr][Dd]%s+[Ii][Ss]%s+([%w][%w_%.]+)",
    "[Dd][Ii][Ss][Cc][Oo][Rr][Dd]%s+([%w][%w_%.]+#%d+)",  -- old-format Discord
}

-- Words that look like Discord matches but are actually false positives
local DISCORD_FALSE_POSITIVES = {
    ["server"] = true, ["channel"] = true, ["link"] = true,
    ["is"] = true, ["the"] = true, ["a"] = true, ["my"] = true,
    ["our"] = true, ["their"] = true, ["his"] = true, ["her"] = true,
    ["chat"] = true, ["voice"] = true, ["call"] = true, ["app"] = true,
}

-- Extract Discord handles from a chat message body. Returns array of matches.
local function ExtractDiscords(message)
    if VPT.SafeIsEmpty(message) then return {} end
    local found = {}
    local seen = {}
    for _, pat in ipairs(DISCORD_LABEL_PATTERNS) do
        for m in string.gmatch(message, pat) do
            -- Filter: minimum 2 chars, max 32 chars (Discord limits), no leading/trailing dots
            if m and #m >= 2 and #m <= 32 and not m:find("^%.") and not m:find("%.$") then
                local lower = m:lower()
                if not DISCORD_FALSE_POSITIVES[lower] and not seen[lower] then
                    seen[lower] = true
                    table.insert(found, m)
                end
            end
        end
    end
    return found
end

-- Look up a character's battletag via the user's Battle.net friend list.
-- Returns btag string if found, nil otherwise. Only works if the user is
-- already friends with this person.
local function GetBtagFromBnetFriends(charNameRealm)
    if not charNameRealm or not C_BattleNet then return nil end
    if not BNGetNumFriends then return nil end

    local nameOnly = charNameRealm:match("^([^-]+)") or charNameRealm
    local realmOnly = charNameRealm:match("-(.+)$")

    local numFriends = BNGetNumFriends() or 0
    for i = 1, numFriends do
        local ok, accountInfo = pcall(C_BattleNet.GetFriendAccountInfo, i)
        if ok and accountInfo and accountInfo.battleTag then
            -- Check active game character first
            local gameInfo = accountInfo.gameAccountInfo
            if gameInfo and gameInfo.characterName then
                local cn = gameInfo.characterName
                local rn = gameInfo.realmName
                if cn == nameOnly and (not realmOnly or rn == realmOnly) then
                    return accountInfo.battleTag
                end
            end
            -- Check all alts
            local numAccounts = C_BattleNet.GetFriendNumGameAccounts and
                C_BattleNet.GetFriendNumGameAccounts(i) or 0
            for j = 1, numAccounts do
                local okj, alt = pcall(C_BattleNet.GetFriendGameAccountInfo, i, j)
                if okj and alt and alt.characterName then
                    if alt.characterName == nameOnly and
                       (not realmOnly or alt.realmName == realmOnly) then
                        return accountInfo.battleTag
                    end
                end
            end
        end
    end
    return nil
end

VPT.GetBtagFromBnetFriends = GetBtagFromBnetFriends  -- exposed for UI

-- Save a discovered btag for a specific character in the current lockout.
-- Updates entry.btagsByName, and if it's the leader's name also updates the
-- top-level entry.btag for the Whisper Btag button to use.
local function SaveBtagForChar(entry, charNameRealm, btag)
    if not entry or not charNameRealm or not btag or btag == "" then return end
    entry.btagsByName = entry.btagsByName or {}
    if entry.btagsByName[charNameRealm] == btag then return end  -- already known
    entry.btagsByName[charNameRealm] = btag

    -- Promote leader's btag to the top-level field
    if entry.leader == charNameRealm and (not entry.btag or entry.btag == "") then
        entry.btag = btag
    end

    -- Cluster this character with the btag (account-wide alt linking)
    if VPT.LinkCharToBtag then VPT.LinkCharToBtag(charNameRealm, btag) end

    print(VPT.C_CYAN .. "[VoidPug]|r " .. VPT.C_GREEN ..
        "Auto-detected btag:|r " .. VPT.C_WHITE .. btag .. "|r " ..
        VPT.C_DIM .. "for " .. charNameRealm .. "|r")
end

VPT.SaveBtagForChar = SaveBtagForChar  -- exposed for UI

-- Save a discovered Discord handle for a specific character in the current lockout.
local function SaveDiscordForChar(entry, charNameRealm, discord)
    if not entry or not charNameRealm or not discord or discord == "" then return end
    entry.discordsByName = entry.discordsByName or {}
    if entry.discordsByName[charNameRealm] == discord then return end
    entry.discordsByName[charNameRealm] = discord

    if entry.leader == charNameRealm and (not entry.discord or entry.discord == "") then
        entry.discord = discord
    end

    print(VPT.C_CYAN .. "[VoidPug]|r " .. VPT.C_GREEN ..
        "Auto-detected Discord:|r " .. VPT.C_WHITE .. discord .. "|r " ..
        VPT.C_DIM .. "for " .. charNameRealm .. "|r")
end

VPT.SaveDiscordForChar = SaveDiscordForChar

-- Find current group's leader, returns "Name-Realm" or nil.
local function GetGroupLeader()
    if not IsInGroup() then return nil end
    local numMembers = GetNumGroupMembers() or 0
    if IsInRaid() then
        for i = 1, numMembers do
            local name, rank = GetRaidRosterInfo(i)
            if name and rank == 2 then  -- 2 = leader in raid
                return NormalizeName(name, nil)
            end
        end
    else
        -- Party: UnitIsGroupLeader / iterate party1..party4
        for i = 0, numMembers - 1 do
            local unit = (i == 0) and "player" or ("party" .. i)
            if UnitIsGroupLeader(unit) then
                local name, realm = UnitName(unit)
                return NormalizeName(name, realm)
            end
        end
    end
    return nil
end

-- Returns array of rich roster entries for the current group:
--   { { name = "Vede-Elune", classFile = "DEATHKNIGHT", class = "Death Knight",
--       role = "DAMAGER", level = 80 }, ... }
-- Party path uses unit tokens (party1..4 + player). Raid path uses
-- GetRaidRosterInfo + raid1..40 unit tokens for the unit-only fields.
local function GetGroupRoster()
    if not IsInGroup() then return {} end
    local roster = {}
    local seen = {}
    local function add(name, classFile, class, role, level)
        if not name or seen[name] then return end
        seen[name] = true
        table.insert(roster, {
            name      = name,
            classFile = classFile,  -- "DEATHKNIGHT", uppercase English
            class     = class,       -- localized display name
            role      = role,        -- "TANK"|"HEALER"|"DAMAGER"|"NONE"
            level     = level,
        })
    end
    if IsInRaid() then
        local numMembers = GetNumGroupMembers() or 0
        for i = 1, numMembers do
            local rname, _, _, level, class, classFile = GetRaidRosterInfo(i)
            if rname then
                local qualified = NormalizeName(rname, nil)
                if qualified then
                    local unit = "raid" .. i
                    local role = (UnitGroupRolesAssigned and UnitExists(unit))
                        and UnitGroupRolesAssigned(unit) or "NONE"
                    add(qualified, classFile, class, role, level)
                end
            end
        end
    else
        local numMembers = GetNumGroupMembers() or 0
        for i = 0, numMembers - 1 do
            local unit = (i == 0) and "player" or ("party" .. i)
            if UnitExists(unit) then
                local name, realm = UnitName(unit)
                local qualified = NormalizeName(name, realm)
                if qualified then
                    local class, classFile = UnitClass(unit)
                    local role = UnitGroupRolesAssigned
                        and UnitGroupRolesAssigned(unit) or "NONE"
                    local level = UnitLevel(unit)
                    add(qualified, classFile, class, role, level)
                end
            end
        end
    end
    return roster
end

-- Look up the saved-instance entry for the current raid. Returns the
-- index into GetSavedInstanceInfo() or nil if no matching save exists.
local function FindSavedInstanceForCurrentRaid()
    local rname, _, difficultyID = GetInstanceInfo()
    if not rname then return nil end
    local num = GetNumSavedInstances() or 0
    for i = 1, num do
        local name, _, reset, difficulty, locked, _, _, _, _, difficultyName = GetSavedInstanceInfo(i)
        if name == rname and (difficulty == difficultyID or difficultyName == VPT.RAID_DIFFICULTY[difficultyID]) and locked then
            return i, name, reset, difficulty, difficultyName
        end
    end
    return nil
end

-- Returns: raidName, difficultyName, difficultyID, resetTimestamp, savedIdx
-- or nil if not in a tracked raid difficulty.
local function GetCurrentRaidContext()
    if not IsInInstance() then return nil end
    local name, instanceType, difficultyID = GetInstanceInfo()
    if instanceType ~= "raid" then return nil end
    local diffName = VPT.RAID_DIFFICULTY[difficultyID]
    if not diffName then return nil end

    -- Primary: saved-instance API. Only valid AFTER you've been saved
    -- (at least one boss killed). Returns nil/false on fresh-enter.
    local savedIdx, savedName, resetSec = FindSavedInstanceForCurrentRaid()
    local resetTimestamp = 0
    if resetSec and resetSec > 0 then
        resetTimestamp = time() + resetSec
    end

    -- Fallback: if no saved-instance entry yet (haven't killed a boss, or
    -- API not populated), use the next weekly raid reset moment. This
    -- gives us a stable resetTimestamp so the lockout key doesn't change
    -- once the first kill saves us.
    if resetTimestamp == 0 then
        if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
            local sec = C_DateAndTime.GetSecondsUntilWeeklyReset()
            if sec and sec > 0 then
                resetTimestamp = time() + sec
            end
        end
    end

    return name, diffName, difficultyID, resetTimestamp, savedIdx
end

-- Is the difficulty at-or-above the minimum tracked level?
local function MeetsDifficultyThreshold(diffName)
    local cfg = VPT.GetDB().config
    local order = { Normal = 1, Heroic = 2, Mythic = 3, LFR = 0, Timewalking = 0 }
    local minLevel = order[cfg.minDifficultyToTrack or "Heroic"] or 2
    local thisLevel = order[diffName or ""] or 0
    return thisLevel >= minLevel
end

----------------------------------------------------------------------
-- Boss kill name resolution. ENCOUNTER_END gives us name + encounterID;
-- BOSS_KILL gives encounterID + name. We cache to handle the case where
-- one event fires without the other.
----------------------------------------------------------------------
local function RecordBossKill(entry, encounterID, encounterName)
    if not entry then return end
    -- Dedupe: don't record the same encounterID twice in this lockout
    entry.kills = entry.kills or {}
    if encounterID then
        for _, k in ipairs(entry.kills) do
            if k.encounterID == encounterID then return end
        end
    end
    table.insert(entry.kills, {
        boss        = encounterName or ("Encounter " .. tostring(encounterID or "?")),
        encounterID = encounterID,
        time        = time(),
    })
end

----------------------------------------------------------------------
-- Main update: refresh or create the lockout entry for current raid.
----------------------------------------------------------------------
local function RefreshCurrentLockout()
    local rname, diffName, diffID, resetTimestamp, savedIdx = GetCurrentRaidContext()
    if not rname then
        currentLockoutKey = nil
        return nil
    end
    if not MeetsDifficultyThreshold(diffName) then
        currentLockoutKey = nil
        return nil
    end

    local key = VPT.MakeLockoutKey(rname, diffName, resetTimestamp)
    local entry = VPT.GetLockout(key) or {
        key         = key,
        raidName    = rname,
        difficulty  = diffName,
        firstJoined = time(),
        kills       = {},
        roster      = {},
        btag        = "",
        discord     = "",
        notes       = "",
    }
    entry.lastSeen   = time()
    entry.resetTime  = resetTimestamp
    entry.instanceID = select(8, GetInstanceInfo())  -- engine instance ID for reference

    -- Capture leader + roster (only update if we got fresh data)
    local leader = GetGroupLeader()
    if leader then
        local prevLeader = entry.leader
        entry.leader = leader
        -- If the leader CHANGED, re-promote btag/discord from the per-name
        -- maps so the UI shows the right contact info. Without this, a
        -- mid-raid leader swap leaves entry.btag pointing at the old leader.
        if prevLeader and prevLeader ~= leader then
            entry.btag    = (entry.btagsByName and entry.btagsByName[leader]) or ""
            entry.discord = (entry.discordsByName and entry.discordsByName[leader]) or ""
        end
        -- If we don't yet have a btag for the leader, try the BNet friends list
        if not entry.btag or entry.btag == "" then
            local btag = GetBtagFromBnetFriends(leader)
            if btag then
                SaveBtagForChar(entry, leader, btag)
            end
        end
    end

    local roster = GetGroupRoster()
    if #roster > 0 then
        -- rosterDetails is now the single source of truth. firstSeen +
        -- lastSeen track presence; classFile/class/role/level capture
        -- composition (overwritten with latest values each refresh). The
        -- old flat entry.roster array is kept only for legacy callers and
        -- is rebuilt from rosterDetails keys.
        entry.rosterDetails = entry.rosterDetails or {}
        local now = time()
        for _, info in ipairs(roster) do
            local d = entry.rosterDetails[info.name]
            if not d then
                d = { firstSeen = now }
                entry.rosterDetails[info.name] = d
            end
            d.lastSeen  = now
            -- Only overwrite class/role/level if we actually got values
            -- (raid-roster iteration sometimes returns nil for offline alts).
            if info.classFile then d.classFile = info.classFile end
            if info.class     then d.class     = info.class     end
            if info.role and info.role ~= "NONE" then d.role = info.role end
            if info.level and info.level > 0     then d.level = info.level end
        end
        entry.rosterLastRefresh = now

        -- Migrate any pre-rich-data entries (from .roster array) into
        -- rosterDetails with best-effort firstSeen/lastSeen timestamps.
        -- Future captures fill in class/role/level when those players reappear.
        for _, oldName in ipairs(entry.roster or {}) do
            if not entry.rosterDetails[oldName] then
                entry.rosterDetails[oldName] = {
                    firstSeen = entry.firstJoined or now,
                    lastSeen  = entry.firstJoined or now,
                }
            end
        end

        -- Rebuild legacy flat array for callers that still read entry.roster
        local merged = {}
        for n, _ in pairs(entry.rosterDetails) do
            table.insert(merged, n)
        end
        table.sort(merged)
        entry.roster = merged
    end

    -- Pull boss-kill list from saved-instance API (authoritative — survives logout).
    -- savedIdx was captured at the top of this function — don't re-call.
    if savedIdx then
        local numEncounters = select(9, GetSavedInstanceInfo(savedIdx)) or 0
        for e = 1, numEncounters do
            local bossName, _, isKilled = GetSavedInstanceEncounterInfo(savedIdx, e)
            if isKilled and bossName then
                -- We don't have encounterID from saved-instance API, so dedupe by name
                local already = false
                for _, k in ipairs(entry.kills) do
                    if k.boss == bossName then already = true; break end
                end
                if not already then
                    table.insert(entry.kills, {
                        boss        = bossName,
                        encounterID = nil,
                        time        = time(),
                    })
                end
            end
        end
    end

    VPT.PutLockout(key, entry)
    currentLockoutKey = key
    return entry, key
end

----------------------------------------------------------------------
-- Event dispatch
--
-- GROUP_ROSTER_UPDATE fires constantly inside a Mythic raid (every
-- combat-roster-change). Each fire walks the full roster + sorts + rebuilds
-- entry.roster, allocating garbage on the hot path. Throttle to 1.5s.
-- Other events (RAID_INSTANCE_WELCOME, PARTY_LEADER_CHANGED) need immediate
-- refresh — they're rare and we want responsive UI for them.
----------------------------------------------------------------------
local _refreshThrottle = { pending = false, lastRun = 0 }
local function ThrottledRefresh()
    local now = GetTime()
    if (now - _refreshThrottle.lastRun) < 1.5 then
        if _refreshThrottle.pending then return end
        _refreshThrottle.pending = true
        C_Timer.After(1.5 - (now - _refreshThrottle.lastRun) + 0.05, function()
            _refreshThrottle.pending = false
            _refreshThrottle.lastRun = GetTime()
            RefreshCurrentLockout()
        end)
        return
    end
    _refreshThrottle.lastRun = now
    RefreshCurrentLockout()
end

local function OnEvent(_, event, ...)
    if event == "ZONE_CHANGED_NEW_AREA"
       or event == "RAID_INSTANCE_WELCOME"
       or event == "PLAYER_ENTERING_WORLD"
       or event == "PARTY_LEADER_CHANGED" then
        -- Immediate refresh — these events are user-perceivable
        local entry, key = RefreshCurrentLockout()
        if entry and event == "RAID_INSTANCE_WELCOME" then
            local cfg = VPT.GetDB().config
            if cfg.autoPrintOnJoin then
                VPT.Print("Tracking " .. C_GOLD .. entry.raidName .. "|r " ..
                    C_DIM .. "(" .. entry.difficulty .. ")|r — leader: " ..
                    C_WHITE .. (entry.leader or "?") .. "|r")
            end
        end

        -- Raid-end detection: was in raid last tick, now not. Print save prompt.
        local nowInRaid = IsInRaid()
        if wasInRaid and not nowInRaid then
            -- Find the most-recent active lockout to report on
            local lastEntry, lastTime = nil, 0
            VPT.ForEachLockout(function(k, e, expired)
                if not expired and (e.lastSeen or 0) > lastTime then
                    lastEntry = e
                    lastTime = e.lastSeen or 0
                end
            end)
            if lastEntry then
                local kills = #(lastEntry.kills or {})
                local rosterSize = #(lastEntry.roster or {})
                print(VPT.C_CYAN .. "[VoidPug]|r " .. VPT.C_GOLD ..
                    "🚨 Raid session ended.|r")
                print("  " .. VPT.C_DIM .. "Captured: |r" ..
                    VPT.C_WHITE .. kills .. "|r kills, " ..
                    VPT.C_WHITE .. rosterSize .. "|r-player roster, leader: " ..
                    VPT.C_WHITE .. (lastEntry.leader or "?") .. "|r")
                print("  " .. VPT.C_RED .. "⚠ Data is in memory only.|r " ..
                    VPT.C_DIM .. "Type|r " .. VPT.C_CYAN .. "/vpt save|r " ..
                    VPT.C_DIM .. "to write to disk now.|r")
            end
        end
        wasInRaid = nowInRaid
    elseif event == "GROUP_ROSTER_UPDATE"
        or event == "UPDATE_INSTANCE_INFO" then
        -- High-frequency events — throttle to avoid combat-time allocation churn
        ThrottledRefresh()
    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        if success == 1 then
            -- Capture kill — refresh first to ensure entry exists
            RefreshCurrentLockout()
            if currentLockoutKey then
                local entry = VPT.GetLockout(currentLockoutKey)
                if entry then
                    RecordBossKill(entry, encounterID, encounterName)
                    VPT.PutLockout(currentLockoutKey, entry)
                    VPT.Print(C_GREEN .. "Recorded kill:|r " .. C_GOLD ..
                        tostring(encounterName) .. "|r in " ..
                        C_WHITE .. entry.raidName .. "|r")
                end
            end
        end
    elseif event == "BOSS_KILL" then
        local encounterID, encounterName = ...
        RefreshCurrentLockout()
        if currentLockoutKey then
            local entry = VPT.GetLockout(currentLockoutKey)
            if entry then
                RecordBossKill(entry, encounterID, encounterName)
                VPT.PutLockout(currentLockoutKey, entry)
            end
        end
    elseif event == "CHAT_MSG_RAID"
        or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_PARTY"
        or event == "CHAT_MSG_PARTY_LEADER"
        or event == "CHAT_MSG_WHISPER"
        or event == "CHAT_MSG_WHISPER_INFORM"
        or event == "CHAT_MSG_BN_WHISPER"
        or event == "CHAT_MSG_BN_WHISPER_INFORM" then
        -- Args: message, sender (Name-Realm or Name), language, ...
        local message, sender = ...
        if not currentLockoutKey or not message or not sender then return end
        local entry = VPT.GetLockout(currentLockoutKey)
        if not entry then return end

        local btags = ExtractBtags(message)
        local discords = ExtractDiscords(message)
        if #btags == 0 and #discords == 0 then return end

        -- Normalize sender to Name-Realm
        local senderNorm = NormalizeName(sender, nil)

        -- Resolve a target character (Name-Realm) for whatever was shared.
        -- Returns the matched roster name, or nil if no match.
        local function ResolveTarget()
            if senderNorm then
                local senderShort = senderNorm:match("^([^-]+)") or senderNorm
                for _, rosterName in ipairs(entry.roster or {}) do
                    local rosterShort = rosterName:match("^([^-]+)") or rosterName
                    if rosterShort == senderShort then
                        return rosterName
                    end
                end
            end
            -- Try message-body name match
            local msgLower = message:lower()
            for _, rosterName in ipairs(entry.roster or {}) do
                local rosterShort = rosterName:match("^([^-]+)") or rosterName
                if msgLower:find(rosterShort:lower(), 1, true) then
                    return rosterName
                end
            end
            return nil
        end

        local target = ResolveTarget()
        local saved = false

        if target then
            for _, btag in ipairs(btags) do
                SaveBtagForChar(entry, target, btag)
                saved = true
            end
            for _, discord in ipairs(discords) do
                SaveDiscordForChar(entry, target, discord)
                saved = true
            end
        end

        if saved then
            VPT.PutLockout(currentLockoutKey, entry)
        end
    end
end

----------------------------------------------------------------------
-- Reset reminder check on login: any lockout reset within 24h with
-- unfinished bosses gets a chat alert.
----------------------------------------------------------------------
local function CheckResetReminders()
    local cfg = VPT.GetDB().config
    if not cfg.resetReminderEnabled then return end

    local now = time()
    local DAY = 86400
    local alerts = {}
    VPT.ForEachLockout(function(key, entry, isExpired)
        if isExpired then return end
        if not entry.resetTime then return end  -- nil guard
        local hoursLeft = (entry.resetTime - now) / 3600
        if hoursLeft <= 24 and hoursLeft > 0 then
            table.insert(alerts, entry)
        end
    end)

    if #alerts > 0 then
        VPT.Print(C_GOLD .. "⏰ Lockouts resetting within 24 hours:|r")
        for _, entry in ipairs(alerts) do
            local kills = #(entry.kills or {})
            local leader = entry.leader or "?"
            local raidName = entry.raidName or "?"
            local difficulty = entry.difficulty or "?"
            print("  " .. C_WHITE .. raidName .. "|r " .. C_DIM ..
                "(" .. difficulty .. ", " .. kills .. " kills, lead: " ..
                leader .. ")|r")
        end
        VPT.Print(C_DIM .. "Type /vpt to view contacts.|r")
    end
end

----------------------------------------------------------------------
-- Module lifecycle
----------------------------------------------------------------------
function mod:Init()
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("RAID_INSTANCE_WELCOME")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PARTY_LEADER_CHANGED")
    eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
    eventFrame:RegisterEvent("ENCOUNTER_END")
    eventFrame:RegisterEvent("BOSS_KILL")
    -- BOSS_KILL_UNFILTERED removed in WoW 12.0 — only BOSS_KILL exists now
    -- Chat scanning for btag auto-detection
    eventFrame:RegisterEvent("CHAT_MSG_RAID")
    eventFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
    eventFrame:RegisterEvent("CHAT_MSG_PARTY")
    eventFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
    eventFrame:RegisterEvent("CHAT_MSG_WHISPER")
    eventFrame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    eventFrame:RegisterEvent("CHAT_MSG_BN_WHISPER")
    eventFrame:RegisterEvent("CHAT_MSG_BN_WHISPER_INFORM")
    eventFrame:SetScript("OnEvent", OnEvent)
end

function mod:Enable()
    -- Force a saved-instance refresh on login so reset timers populate
    if RequestRaidInfo then RequestRaidInfo() end
    -- Capture initial raid state so we don't false-trigger raid-end at login
    wasInRaid = IsInRaid()
    -- Run reminder check after a short delay so saved-instance API has data
    C_Timer.After(3, function()
        CheckResetReminders()
        RefreshCurrentLockout()
        wasInRaid = IsInRaid()  -- re-capture after refresh
    end)
end

-- Exposed for UI: when was this addon session loaded
function mod:GetSessionStartTime() return sessionStartTime end

-- Exposed for UI module
function mod:RefreshNow()
    return RefreshCurrentLockout()
end

function mod:GetCurrentKey()
    return currentLockoutKey
end
