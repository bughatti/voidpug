----------------------------------------------------------------------
-- VoidPug LFGHook — surface pug history on Premade Groups search results.
-- When you hover an LFG result, if the leader matches someone you've
-- raided with before, append a tooltip section showing:
--   - past lockout title + boss count
--   - rating (★) you gave them
--   - tags
--   - last seen date
--
-- 12.0.5 secret-value awareness: C_LFGList.GetApplicantInfo fields are
-- secret in chat lockdown, but GetSearchResultInfo.leaderName is clean
-- (it's the result LEADER, not an applicant). Safe to read.
----------------------------------------------------------------------
local ADDON_NAME, VPT = ...
local mod = VPT:NewModule("LFGHook")

local function FormatRelative(unix)
    if not unix or unix == 0 then return "unknown" end
    local delta = time() - unix
    if delta < 60 then return "just now" end
    if delta < 3600 then return ("%dm ago"):format(math.floor(delta / 60)) end
    if delta < 86400 then return ("%dh ago"):format(math.floor(delta / 3600)) end
    return ("%dd ago"):format(math.floor(delta / 86400))
end

-- Find all past lockouts whose leader matches the given name. Match by
-- exact "Name-Realm" first, then by name-only prefix (handles realm
-- differences across pugs).
local function FindLockoutsForLeader(leaderName)
    if not leaderName or leaderName == "" then return {} end
    local results = {}
    local exactWanted = leaderName
    local nameOnly = leaderName:match("^([^-]+)") or leaderName
    VPT.ForEachLockout(function(key, entry, isExpired)
        if not entry.leader then return end
        if entry.leader == exactWanted or entry.leader:find("^" .. nameOnly .. "%-") then
            table.insert(results, { entry = entry, expired = isExpired })
        end
    end)
    -- Most-recent first
    table.sort(results, function(a, b)
        return (a.entry.lastSeen or 0) > (b.entry.lastSeen or 0)
    end)
    return results
end

local function AppendHistoryToTooltip(tooltip, leaderName)
    if not tooltip or not leaderName then return end
    local matches = FindLockoutsForLeader(leaderName)
    if #matches == 0 then return end

    tooltip:AddLine(" ")
    tooltip:AddLine("|cff00c7ffVoidPug history|r", 1, 1, 1)
    -- Show up to 3 most-recent
    local shown = 0
    for _, m in ipairs(matches) do
        if shown >= 3 then break end
        shown = shown + 1
        local e = m.entry
        local stars = ""
        if e.rating and e.rating > 0 then
            stars = "|cffffd100" .. string.rep("★", e.rating) ..
                    "|r|cff606060" .. string.rep("☆", 5 - e.rating) .. "|r  "
        end
        local kills = #(e.kills or {})
        local line1 = stars .. (e.raidName or "?") .. " " ..
                      "|cff8c8c9e(" .. (e.difficulty or "?") .. ", " ..
                      kills .. " kills, " .. FormatRelative(e.lastSeen) .. ")|r"
        tooltip:AddLine(line1, 1, 1, 1)
        if e.tags and #e.tags > 0 then
            tooltip:AddLine("  |cff9cb4ff" .. table.concat(e.tags, ", ") .. "|r")
        end
        if e.notes and e.notes ~= "" then
            tooltip:AddLine("  |cff8c8c9e" .. e.notes .. "|r")
        end
    end
    if #matches > shown then
        tooltip:AddLine("|cff606060... and " .. (#matches - shown) .. " more|r")
    end
    tooltip:Show()
end

----------------------------------------------------------------------
-- Hook into Blizzard's LFG search-result tooltip. The tooltip is built
-- via LFGListUtil_SetSearchEntryTooltip(tooltip, resultID, autoAccept)
-- when the user hovers a result row. We hook AFTER Blizzard's call so
-- our lines append at the bottom.
----------------------------------------------------------------------
local function InstallHook()
    if mod._installed then return end
    if not LFGListUtil_SetSearchEntryTooltip then return false end
    hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID, autoAccept)
        if not tooltip or not resultID then return end
        if not C_LFGList or not C_LFGList.GetSearchResultInfo then return end
        local info = C_LFGList.GetSearchResultInfo(resultID)
        if not info or not info.leaderName then return end
        -- leaderName is the visible "Name-Realm" of the group leader
        AppendHistoryToTooltip(tooltip, info.leaderName)
    end)
    mod._installed = true
    return true
end

function mod:Init()
    -- The Blizzard_PremadeGroupFinder addon loads on-demand. Wait for
    -- it to load before we can hook LFGListUtil_*.
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(self, event, arg1)
        if InstallHook() then
            self:UnregisterAllEvents()
        end
    end)
    InstallHook()  -- try immediately in case it's already loaded
end

VPT.LFGHook = mod
