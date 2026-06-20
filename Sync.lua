----------------------------------------------------------------------
-- VoidPug Sync — broadcast and receive lockout summaries via addon
-- channel so two characters in the same group can exchange:
--   - leader name + battletag
--   - rating + tags (the freeform pug-quality intel)
--   - lastSeen timestamp (for "is this stale?" comparisons)
--
-- Limitations / scope of v1:
--   - Roster names NOT synced (would exceed the 255-byte addon-message
--     limit for 25-player raids without chunking).
--   - Per-character btag map NOT synced (privacy + size).
--   - One-shot broadcast on join + on user-driven Save, no continuous
--     sync. Other clients merge what they receive via VPT.MergeEntries.
--
-- Channel selection: "INSTANCE_CHAT" for LFG-formed groups (PARTY silently
-- drops in those), "RAID" for raid context, "PARTY" otherwise. The
-- detection rule is critical — see wow-12-group-pug-apis memory.
----------------------------------------------------------------------
local ADDON_NAME, VPT = ...
local mod = VPT:NewModule("Sync")

-- VoidSpy hook: enable with /vspy enable VoidPug (no-op if VoidSpy missing)
local function dbg(fmt, ...)
    if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidPug", fmt, ...) end
end

local PREFIX  = "VPUG"        -- max 16 chars per Blizzard
local VERSION = "V1"          -- bump if we change the wire format
local DELIM   = "^"           -- top-level field separator
local TAG_SEP = "~"           -- tags-list separator within the tags field

----------------------------------------------------------------------
-- Channel detection — LFG groups need INSTANCE_CHAT
----------------------------------------------------------------------
local function PugChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return nil
end

----------------------------------------------------------------------
-- Serialization — escape DELIM + TAG_SEP in any user-typed field
----------------------------------------------------------------------
local function escapeField(s)
    if s == nil then return "" end
    s = tostring(s)
    -- Strip our delimiters and any pipe (pipes are color-code escape in
    -- WoW chat which would break the wire format)
    return (s:gsub("[%^~|]", " "))
end

local function packLockout(entry)
    if not entry or not entry.key then return nil end
    local parts = {
        VERSION,
        "LOCKOUT",
        escapeField(entry.key),
        escapeField(entry.leader or ""),
        escapeField(entry.btag   or ""),
        tostring(entry.lastSeen   or 0),
        tostring(entry.resetTime  or 0),
        tostring(entry.rating     or 0),
    }
    -- Tags as ~-joined
    local tagsCsv = ""
    if entry.tags and #entry.tags > 0 then
        local cleaned = {}
        for _, t in ipairs(entry.tags) do
            local c = escapeField(t)
            if c ~= "" then table.insert(cleaned, c) end
        end
        tagsCsv = table.concat(cleaned, TAG_SEP)
    end
    table.insert(parts, tagsCsv)
    return table.concat(parts, DELIM)
end

local function unpackLockout(msg)
    if not msg then return nil end
    -- Split by DELIM
    local parts = {}
    for token in (msg .. DELIM):gmatch("([^" .. DELIM .. "]*)" .. DELIM) do
        table.insert(parts, token)
    end
    if parts[1] ~= VERSION then return nil end
    if parts[2] ~= "LOCKOUT" then return nil end
    local entry = {
        key       = parts[3],
        leader    = parts[4] ~= "" and parts[4] or nil,
        btag      = parts[5] ~= "" and parts[5] or "",
        lastSeen  = tonumber(parts[6]) or 0,
        resetTime = tonumber(parts[7]) or 0,
        rating    = tonumber(parts[8]),
    }
    if entry.rating == 0 then entry.rating = nil end
    if parts[9] and parts[9] ~= "" then
        entry.tags = {}
        for tag in (parts[9] .. TAG_SEP):gmatch("([^" .. TAG_SEP .. "]+)" .. TAG_SEP) do
            table.insert(entry.tags, tag)
        end
    end
    -- Derive minimum extras so MergeEntries can take it
    entry.firstJoined = entry.lastSeen  -- we don't know first-joined from peers
    return entry
end

----------------------------------------------------------------------
-- Broadcast: send all our active lockouts (or just the current one if in
-- a group). Throttled internally so we don't spam.
----------------------------------------------------------------------
local _lastBroadcast = {}  -- [key] = GetTime() of last send for that key

function mod:BroadcastLockout(entry)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessageLogged then return end
    if not entry or not entry.key then return end
    -- Throttle: at most once per lockout per 30s
    local now = GetTime()
    if (_lastBroadcast[entry.key] or 0) > now - 30 then return end
    local channel = PugChannel()
    if not channel then return end
    local msg = packLockout(entry)
    if not msg or #msg > 250 then return end  -- 255-byte cap with safety margin
    _lastBroadcast[entry.key] = now
    -- Use the logged variant since this contains user-typed content (tags, notes)
    pcall(C_ChatInfo.SendAddonMessageLogged, PREFIX, msg, channel)
    dbg("Sync broadcast %s → %s (%d bytes)", entry.key, channel, #msg)
end

function mod:BroadcastCurrent()
    -- Pull current lockout from Events module
    local Events = VPT._modules and VPT._modules["Events"]
    if not Events or not Events.GetCurrentKey then return end
    local key = Events:GetCurrentKey()
    if not key then return end
    local entry = VPT.GetLockout(key)
    if entry then mod:BroadcastLockout(entry) end
end

----------------------------------------------------------------------
-- Receive: parse, merge, refresh UI
----------------------------------------------------------------------
local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX then return end
    if not message then return end
    -- Don't process our own broadcasts
    local pName = UnitName("player") or ""
    local pFull = pName .. "-" .. (GetRealmName() or "")
    if sender == pName or sender == pFull then return end
    local entry = unpackLockout(message)
    if not entry or not entry.key then return end

    dbg("Sync received %s from %s (chan=%s)", entry.key, sender, channel)

    -- Merge with existing local entry (if any). MergeEntries handles
    -- conflict resolution (prefer-newer leader, union of tags, max rating).
    local existing = VPT.GetLockout(entry.key)
    local merged = VPT.MergeEntries(existing or {}, entry)
    VPT.PutLockout(entry.key, merged)

    -- Refresh the panel if shown
    local UI = VPT._modules and VPT._modules["UI"]
    if UI and UI.Refresh then UI:Refresh() end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function mod:Init()
    if not C_ChatInfo or not C_ChatInfo.RegisterAddonMessagePrefix then return end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:RegisterEvent("CHAT_MSG_ADDON_LOGGED")
    f:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
        OnAddonMessage(prefix, message, channel, sender)
    end)
    mod._eventFrame = f

    -- Broadcast our current lockout on key events:
    --   - RAID_INSTANCE_WELCOME: we just zoned in, group is established
    --   - GROUP_ROSTER_UPDATE: someone joined/left, may include a new VPug user
    local g = CreateFrame("Frame")
    g:RegisterEvent("RAID_INSTANCE_WELCOME")
    g:RegisterEvent("GROUP_ROSTER_UPDATE")
    g:SetScript("OnEvent", function(_, event)
        -- Small delay so the Events module has refreshed its current key
        C_Timer.After(2, function() mod:BroadcastCurrent() end)
    end)
    mod._broadcastFrame = g
end

-- Public API
VPT.Sync = mod
