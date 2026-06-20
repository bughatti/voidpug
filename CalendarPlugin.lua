----------------------------------------------------------------------
-- VoidPug ↔ VoidCalendar integration
--
-- Registers a button on the EventDetail popup that opens VoidPug and
-- auto-expands the matched lockout. If no auto-match is found, lets the
-- user MANUALLY link the calendar event to one of their lockouts; that
-- link is saved and used for future opens.
--
-- Auto-match scoring (highest wins):
--   +1  raidName substring-matches event title
--   +2  event creator's known BNet tag matches lockout's captured btag
--   +3  3+ event invitees overlap with lockout's roster
--   +1  1-2 invitees overlap with lockout's roster
-- Manual links override auto-match.
----------------------------------------------------------------------

local VPT = _G.VoidPug
if not VPT then return end

local function StripRealm(name)
    if not name then return nil end
    return (name:match("^(.-)-") or name):lower()
end

-- Save/load manual link store — PER CHARACTER. Each toon manages its own
-- event-to-lockout links (the lockout data itself stays account-level shared
-- in VoidPugDB, but which event maps to which lockout is character-local).
local function GetLinkStore()
    VoidPugCharDB = VoidPugCharDB or {}
    VoidPugCharDB.calendarLinks = VoidPugCharDB.calendarLinks or {}
    -- One-time migration: if the user had links in the old account-level
    -- VoidPugDB, copy them into this character's store and wipe the account
    -- store so they don't leak to other characters.
    if VoidPugDB and VoidPugDB.calendarLinks then
        for k, v in pairs(VoidPugDB.calendarLinks) do
            if VoidPugCharDB.calendarLinks[k] == nil then
                VoidPugCharDB.calendarLinks[k] = v
            end
        end
        VoidPugDB.calendarLinks = nil
    end
    return VoidPugCharDB.calendarLinks
end

local function EventKey(ev)
    if not ev or not ev.title then return nil end
    return ("%04d-%02d-%02d:%02d%02d:%s"):format(
        ev.startYear or 0, ev.startMonth or 0, ev.startDay or 0,
        ev.startHour or 0, ev.startMin or 0, ev.title:sub(1, 40))
end

local function GetBtagForCharacter(charName)
    if not charName or not VPT.ForEachLockout then return nil end
    local short = StripRealm(charName)
    local btag
    VPT.ForEachLockout(function(key, entry)
        if btag then return end
        if not entry.btag or entry.btag == "" then return end
        if entry.leader and StripRealm(entry.leader) == short then
            btag = entry.btag; return
        end
        if entry.roster then
            for _, n in ipairs(entry.roster) do
                if StripRealm(n) == short then btag = entry.btag; return end
            end
        end
    end)
    return btag
end

local function EventUnix(ev)
    if not ev or not ev.startYear then return nil end
    return time({
        year = ev.startYear, month = ev.startMonth, day = ev.startDay,
        hour = ev.startHour or 12, min = ev.startMin or 0, sec = 0,
    })
end

local function GetCurrentEventInviteNames()
    local names = {}
    if not C_Calendar or not C_Calendar.GetNumInvites or not C_Calendar.EventGetInvite then
        return names
    end
    for i = 1, (C_Calendar.GetNumInvites() or 0) do
        local inv = C_Calendar.EventGetInvite(i)
        if inv and inv.name then table.insert(names, inv.name) end
    end
    return names
end

local function CountRosterOverlap(inviteNames, lockoutRoster)
    if not lockoutRoster or #lockoutRoster == 0 then return 0 end
    if not inviteNames or #inviteNames == 0 then return 0 end
    local rs = {}
    for _, n in ipairs(lockoutRoster) do rs[StripRealm(n)] = true end
    local h = 0
    for _, n in ipairs(inviteNames) do if rs[StripRealm(n)] then h = h + 1 end end
    return h
end

----------------------------------------------------------------------
-- Resolution: manual link → auto-match. Returns {key, entry} or nil.
----------------------------------------------------------------------
local function ResolveLockoutForEvent(ev, einfo)
    local evKey = EventKey(ev)
    if not evKey then return nil end

    -- 1. Manual link wins
    local linkedKey = GetLinkStore()[evKey]
    if linkedKey then
        local entry = VPT.GetLockout and VPT.GetLockout(linkedKey)
        if entry and not entry.expired then
            return { key = linkedKey, entry = entry, source = "manual" }
        end
        -- Stale link (lockout expired/deleted); clear it
        GetLinkStore()[evKey] = nil
    end

    -- 2. Auto-match by scoring
    if not VPT.ForEachLockout then return nil end
    local eventUnix = EventUnix(ev)
    if not eventUnix then return nil end
    local titleLower = ev.title:lower()
    local creator = einfo and (einfo.creator or einfo.invitedBy) or ev.creator
    local creatorBtag = creator and GetBtagForCharacter(creator)
    local inviteNames = GetCurrentEventInviteNames()

    local best
    VPT.ForEachLockout(function(key, entry)
        if entry.expired then return end
        local resetTime = tonumber(entry.resetTime) or 0
        local windowStart = resetTime - 7 * 24 * 3600
        if eventUnix < windowStart or eventUnix > resetTime then return end

        local raidLower = (entry.raidName or ""):lower()
        local titleMatches = raidLower ~= "" and (
            titleLower:find(raidLower, 1, true) or raidLower:find(titleLower, 1, true)
        )
        local btagMatches = creatorBtag and entry.btag == creatorBtag and entry.btag ~= ""
        local overlap = CountRosterOverlap(inviteNames, entry.roster)

        local score = 0
        if titleMatches then score = score + 1 end
        if btagMatches then score = score + 2 end
        if overlap >= 3 then score = score + 3
        elseif overlap >= 1 then score = score + 1 end

        if score > 0 and (not best or score > best.score) then
            best = { key = key, entry = entry, score = score, source = "auto" }
        end
    end)

    return best
end

----------------------------------------------------------------------
-- Manual link picker — shows a list of current-week lockouts the user
-- can pick to link to this calendar event.
----------------------------------------------------------------------
local function ShowLockoutPicker(ev, einfo)
    local evKey = EventKey(ev)
    if not evKey then return end

    -- Collect candidates (current-week non-expired lockouts)
    local candidates = {}
    if VPT.ForEachLockout then
        VPT.ForEachLockout(function(key, entry)
            if entry.expired then return end
            table.insert(candidates, { key = key, entry = entry })
        end)
    end

    if #candidates == 0 then
        print("|cffff5555[VoidPug]|r No active pug lockouts to link.")
        print("|cffaaaaaa[VoidPug]|r Join a Heroic/Mythic raid and kill at least one boss to create a lockout.")
        return
    end

    if not VoidCalendar or not VoidCalendar.ContextMenu or not VoidCalendar.ContextMenu.Show then
        print("|cffff5555[VoidPug]|r ContextMenu unavailable.")
        return
    end

    local items = {
        { separator = true, label = ("Link '%s' to:"):format(ev.title or "this event") },
    }
    for _, cand in ipairs(candidates) do
        local entry = cand.entry
        local label = ("%s (%s) — leader: %s"):format(
            entry.raidName or "?",
            entry.difficulty or "?",
            entry.leader or "?")
        table.insert(items, {
            label = label,
            callback = function()
                GetLinkStore()[evKey] = cand.key
                print(("|cff00c7ff[VoidPug]|r Linked event '%s' to lockout %s."):format(
                    ev.title or "?", entry.raidName or cand.key))
                -- Open it now
                VPT._calendarHintKey = cand.key
                local uiMod = VPT._modules and VPT._modules["UI"]
                if uiMod and uiMod.Show then pcall(uiMod.Show, uiMod) end
            end,
        })
    end
    table.insert(items, { separator = true, label = "" })
    table.insert(items, {
        label = "|cffff9933[Unlink current]|r",
        callback = function()
            GetLinkStore()[evKey] = nil
            print(("|cff00c7ff[VoidPug]|r Unlinked '%s'."):format(ev.title or "?"))
        end,
    })

    VoidCalendar.ContextMenu:Show(items, 8)
end

----------------------------------------------------------------------
-- Plugin filter + callback
----------------------------------------------------------------------
local function PluginFilter(ev, einfo)
    -- Show for any community / player event (where user could plausibly
    -- link a pug). Skip system events (holidays, lockouts, etc.).
    if not ev then return false end
    local calType = ev.calendarType and ev.calendarType:upper() or ""
    if einfo and einfo.calendarType then calType = einfo.calendarType:upper() end
    if calType == "HOLIDAY" or calType == "RAID_LOCKOUT"
       or calType == "RAID_RESET" or calType == "ARENA" then
        return false
    end
    return true
end

-- (Removed PluginLabel — was never registered. The callback below already
-- handles both matched + unmatched cases at click time. The label stays
-- static "Open / Link Pug" because VoidCalendar's plugin button API takes
-- a string, not a callback.)

local function PluginCallback(ev, einfo)
    local matched = ResolveLockoutForEvent(ev, einfo)
    if matched then
        VPT._calendarHintKey = matched.key
        local mod = VPT._modules and VPT._modules["UI"]
        if not mod then
            print("|cffff5555[VoidPug]|r UI module not found.")
            return
        end
        if mod.Hide then pcall(mod.Hide, mod) end
        if mod.Show then pcall(mod.Show, mod) end
    else
        ShowLockoutPicker(ev, einfo)
    end
end

----------------------------------------------------------------------
-- Registration
----------------------------------------------------------------------
local function TryRegister()
    if not VoidCalendar or not VoidCalendar.EventDetail
       or not VoidCalendar.EventDetail.RegisterPluginButton then
        return false
    end
    -- We register with a STATIC label, but EventDetail re-evaluates the
    -- filter every refresh. So we attach our PluginLabel logic to the
    -- callback site by re-registering on each open... actually simpler:
    -- pass a callback that picks the right action at click time. The
    -- label remains generic and the action handles both cases.
    VoidCalendar.EventDetail:RegisterPluginButton(
        "VoidPug",
        PluginFilter,
        "|cffb48ef7Open / Link Pug|r",
        PluginCallback
    )
    return true
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    if TryRegister() then return end
    C_Timer.After(1, function() if not TryRegister() then C_Timer.After(3, TryRegister) end end)
end)
