-- VoidSpy hook: enable with /vspy enable VoidPug  (no-op if VoidSpy missing/disabled)
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidPug", fmt, ...) end end

----------------------------------------------------------------------
-- VoidPug UI — main panel listing all tracked lockouts with
-- expand/collapse rows, contact fields, and quick actions.
--
-- Slash:
--   /vpt              — toggle panel
--   /vpt show         — open panel
--   /vpt hide         — close panel
--   /vpt refresh      — re-poll WoW and update current raid entry
--   /vpt clear        — wipe all data (with confirmation)
----------------------------------------------------------------------
local _, VPT = ...
local mod = VPT:NewModule("UI")

local C_CYAN, C_GOLD, C_GREEN, C_RED, C_DIM, C_WHITE =
    VPT.C_CYAN, VPT.C_GOLD, VPT.C_GREEN, VPT.C_RED, VPT.C_DIM, VPT.C_WHITE

local panel
local rowFrames = {}     -- pooled per-lockout rows
local expandedKey = nil  -- which lockout row is currently expanded (nil = all collapsed)
local detailFrame        -- the expanded detail box rebuilt on each expansion

local PANEL_W, PANEL_H = 640, 480
local ROW_H = 32
local DETAIL_H = 240

----------------------------------------------------------------------
-- Shared copyable-text popup (Ctrl+A / Ctrl+C). Used by Copy Roster +
-- View Btags. Registered once at module load so we don't redefine it
-- inside click handlers.
----------------------------------------------------------------------
StaticPopupDialogs["VPT_COPY_TEXT"] = {
    text           = "Ctrl+A then Ctrl+C to copy:",
    button1        = OKAY or "OK",
    hasEditBox     = true,
    editBoxWidth   = 350,
    timeout        = 0,
    whileDead      = true,
    hideOnEscape   = true,
    preferredIndex = 3,
    OnShow = function(self, data)
        if self.editBox and data and data.text then
            self.editBox:SetText(data.text)
            self.editBox:HighlightText()
            self.editBox:SetFocus()
        end
    end,
}

local function ShowCopyPopup(text)
    -- StaticPopup_Show's OnShow(self, data) callback doesn't reliably
    -- receive the data param in all client versions. Set the editbox
    -- contents directly on the returned popup frame as a belt-and-suspenders
    -- guarantee.
    local popup = StaticPopup_Show("VPT_COPY_TEXT", "", "", { text = text })
    if popup and popup.editBox then
        popup.editBox:SetText(text or "")
        popup.editBox:HighlightText()
        popup.editBox:SetFocus()
    end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function ColorForDifficulty(diff)
    if diff == "Mythic" then return "|cFFFF7F00" end
    if diff == "Heroic" then return "|cFF0070DD" end
    if diff == "Normal" then return "|cFF1EFF00" end
    return "|cFFAAAAAA"
end

local function CountKills(entry)
    return #(entry.kills or {})
end

local function FormatResetCountdown(entry)
    if not entry.resetTime then return C_DIM .. "no reset|r" end
    local seconds = entry.resetTime - time()
    if seconds <= 0 then return C_RED .. "expired|r" end
    if seconds < 86400 then
        return C_GOLD .. "resets " .. VPT.FormatDuration(seconds) .. "|r"
    end
    return C_GREEN .. "resets " .. VPT.FormatDuration(seconds) .. "|r"
end

----------------------------------------------------------------------
-- Edit-popup helper for btag / discord / notes fields
----------------------------------------------------------------------
local function ShowEditPopup(title, currentValue, callback)
    if not StaticPopupDialogs.VPT_EDIT_FIELD then
        StaticPopupDialogs.VPT_EDIT_FIELD = {
            text         = "",
            button1      = ACCEPT or "Accept",
            button2      = CANCEL or "Cancel",
            hasEditBox   = true,
            maxLetters   = 200,
            timeout      = 0,
            whileDead    = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnShow = function(self, data)
                if self.editBox and data and data.initial then
                    self.editBox:SetText(data.initial or "")
                end
            end,
            OnAccept = function(self, data)
                if data and data.cb and self.editBox then
                    data.cb(self.editBox:GetText() or "")
                end
            end,
            EditBoxOnEnterPressed = function(self, data)
                if data and data.cb then data.cb(self:GetText() or "") end
                self:GetParent():Hide()
            end,
        }
    end
    StaticPopupDialogs.VPT_EDIT_FIELD.text = title
    StaticPopup_Show("VPT_EDIT_FIELD", "", "", {
        initial = currentValue or "",
        cb      = callback,
    })
end

----------------------------------------------------------------------
-- Delete-confirmation popup
----------------------------------------------------------------------
local function ShowDeleteConfirm(entry, onYes)
    if not StaticPopupDialogs.VPT_CONFIRM_DELETE then
        StaticPopupDialogs.VPT_CONFIRM_DELETE = {
            text         = "",
            button1      = YES or "Yes",
            button2      = NO or "No",
            timeout      = 0,
            whileDead    = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnAccept = function(self, data) if data and data.cb then data.cb() end end,
        }
    end
    StaticPopupDialogs.VPT_CONFIRM_DELETE.text =
        "Delete lockout entry for:\n\n" ..
        (entry.raidName or "?") .. " (" .. (entry.difficulty or "?") .. ")\nLeader: " ..
        (entry.leader or "?")
    StaticPopup_Show("VPT_CONFIRM_DELETE", "", "", { cb = onYes })
end

----------------------------------------------------------------------
-- Detail (expanded) frame
----------------------------------------------------------------------
local function BuildDetailFrame()
    if detailFrame then return detailFrame end
    local f = CreateFrame("Frame", "VoidPug_Detail", panel.scroll, "BackdropTemplate")
    f:SetHeight(DETAIL_H)
    VPT.CreateBackdrop(f, 0.75)
    f:SetBackdropBorderColor(0, 0.78, 1, 0.3)
    detailFrame = f
    return f
end

local function RenderDetail(entry, parentRow)
    local f = BuildDetailFrame()
    f:SetParent(parentRow)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", parentRow, "BOTTOMLEFT", 0, -2)
    f:SetPoint("TOPRIGHT", parentRow, "BOTTOMRIGHT", 0, -2)
    f:Show()

    -- Clear old children
    if f._children then
        for _, c in ipairs(f._children) do c:Hide() end
    end
    f._children = {}
    local function adopt(child) table.insert(f._children, child); return child end

    local y = -8

    -- Header row: kills count + leader
    local hdr = adopt(f:CreateFontString(nil, "OVERLAY"))
    VPT.SetFont(hdr, 11, "OUTLINE")
    hdr:SetPoint("TOPLEFT", 10, y)
    hdr:SetText(C_CYAN .. "Lockout details|r")
    y = y - 18

    -- Boss kill list
    local kills = entry.kills or {}
    if #kills == 0 then
        local none = adopt(f:CreateFontString(nil, "OVERLAY"))
        VPT.SetFont(none, 10)
        none:SetPoint("TOPLEFT", 14, y)
        none:SetText(C_DIM .. "No bosses killed yet.|r")
        y = y - 14
    else
        local killHdr = adopt(f:CreateFontString(nil, "OVERLAY"))
        VPT.SetFont(killHdr, 10, "OUTLINE")
        killHdr:SetPoint("TOPLEFT", 14, y)
        killHdr:SetText(C_GOLD .. "Bosses killed (" .. #kills .. "):|r")
        y = y - 14
        for _, k in ipairs(kills) do
            local line = adopt(f:CreateFontString(nil, "OVERLAY"))
            VPT.SetFont(line, 10)
            line:SetPoint("TOPLEFT", 22, y)
            line:SetText(C_WHITE .. "• " .. (k.boss or "?") .. "|r " ..
                C_DIM .. VPT.FormatTimestamp(k.time) .. "|r")
            y = y - 13
        end
    end
    y = y - 4

    -- Roster summary — distinguish CURRENT (in raid at last refresh) from
    -- HISTORICAL (was in raid at some point but has since dropped).
    local rosterCount = entry.roster and #entry.roster or 0
    local lastRefresh = entry.rosterLastRefresh or 0
    -- Consider a player "current" if they were seen in the last 60s before
    -- the last refresh — this handles the case where the addon hasn't run
    -- a fresh capture in a minute but the raid is still active.
    local currentThreshold = lastRefresh - 60
    local currentCount, droppedCount = 0, 0
    if entry.rosterDetails then
        for name, info in pairs(entry.rosterDetails) do
            if (info.lastSeen or 0) >= currentThreshold then
                currentCount = currentCount + 1
            else
                droppedCount = droppedCount + 1
            end
        end
    else
        currentCount = rosterCount  -- legacy fallback
    end

    local rosterRow = adopt(f:CreateFontString(nil, "OVERLAY"))
    VPT.SetFont(rosterRow, 10, "OUTLINE")
    rosterRow:SetPoint("TOPLEFT", 14, y)
    if droppedCount > 0 then
        rosterRow:SetText(C_GOLD .. "Roster: |r" .. C_WHITE .. currentCount ..
            "|r " .. C_DIM .. "currently / |r" .. C_WHITE .. rosterCount ..
            "|r " .. C_DIM .. "total seen (" .. droppedCount .. " dropped)|r")
    else
        rosterRow:SetText(C_GOLD .. "Roster: |r" .. C_WHITE .. currentCount ..
            "|r " .. C_DIM .. "players|r")
    end
    y = y - 13

    if rosterCount > 0 then
        -- Per-name click-to-copy buttons with class colors + role icons.
        -- Each name is a clickable button → click opens chat input with the
        -- name pre-filled and highlighted (Ctrl+C to copy, or type /w + Enter).
        local NAME_PAD_X, NAME_PAD_Y = 6, 2
        local ROW_GAP_X, ROW_GAP_Y = 4, 2
        local maxWidth = f:GetWidth() - 30
        local startX = 22
        local cursorX, rowY = startX, y
        local lineH = 14

        -- Class colors keyed by RAID_CLASS_COLORS (Blizzard global). Falls
        -- back to white if the class isn't known.
        local function ClassColorCode(classFile)
            if not classFile then return "ffffffff" end
            local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
            if not c then return "ffffffff" end
            return string.format("ff%02x%02x%02x", c.r*255, c.g*255, c.b*255)
        end

        -- Tiny single-letter role tag (T/H/D) so we don't need icon textures
        local ROLE_TAG = {
            TANK    = "|cff4080ffT|r",
            HEALER  = "|cff40ff80H|r",
            DAMAGER = "|cffff8040D|r",
        }

        -- Sort: current first, then dropped, each group sorted by name
        local ordered = {}
        if entry.rosterDetails then
            local cur, drp = {}, {}
            for name, info in pairs(entry.rosterDetails) do
                local rec = {
                    name      = name,
                    current   = (info.lastSeen or 0) >= currentThreshold,
                    classFile = info.classFile,
                    role      = info.role,
                    level     = info.level,
                }
                if rec.current then table.insert(cur, rec) else table.insert(drp, rec) end
            end
            local byName = function(a, b) return a.name < b.name end
            table.sort(cur, byName); table.sort(drp, byName)
            for _, rec in ipairs(cur) do table.insert(ordered, rec) end
            for _, rec in ipairs(drp) do table.insert(ordered, rec) end
        else
            for _, n in ipairs(entry.roster or {}) do
                table.insert(ordered, { name = n, current = false })
            end
        end

        for _, item in ipairs(ordered) do
            -- Build display label: [role] Name (in class color, dimmed if dropped)
            local roleTag = item.role and ROLE_TAG[item.role] or ""
            local classCode = ClassColorCode(item.classFile)
            local nameColored
            if item.current then
                nameColored = "|c" .. classCode .. item.name .. "|r"
            else
                -- Dropped: half-saturate the class color
                nameColored = "|cff707070" .. item.name .. " (left)|r"
            end
            local labelText = (roleTag ~= "" and (roleTag .. " ") or "") .. nameColored

            local btn = adopt(CreateFrame("Button", nil, f))
            local fs = btn:CreateFontString(nil, "OVERLAY")
            VPT.SetFont(fs, 10)
            fs:SetText(labelText)
            fs:SetPoint("CENTER")
            local tw, th = fs:GetStringWidth(), fs:GetStringHeight()
            local bw, bh = tw + NAME_PAD_X * 2, th + NAME_PAD_Y * 2

            if cursorX + bw > maxWidth then
                cursorX = startX
                rowY = rowY - (lineH + ROW_GAP_Y)
            end
            btn:SetSize(bw, bh)
            btn:SetPoint("TOPLEFT", cursorX, rowY)

            local hl = btn:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            hl:SetColorTexture(0.0, 0.78, 1.0, 0.0)
            btn:SetScript("OnEnter", function()
                hl:SetColorTexture(0.0, 0.78, 1.0, 0.15)
                GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                GameTooltip:SetText(item.name, 1, 1, 1)
                if item.classFile or item.role or item.level then
                    local detail = {}
                    if item.classFile then table.insert(detail, item.classFile:sub(1,1) .. item.classFile:sub(2):lower()) end
                    if item.role then table.insert(detail, item.role) end
                    if item.level then table.insert(detail, "L" .. item.level) end
                    GameTooltip:AddLine(table.concat(detail, " · "), 0.7, 0.85, 1)
                end
                GameTooltip:AddLine("Click to copy to chat input", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function()
                hl:SetColorTexture(0.0, 0.78, 1.0, 0.0)
                GameTooltip:Hide()
            end)
            btn:SetScript("OnClick", function()
                ChatFrame_OpenChat(item.name)
                local edit = ChatEdit_GetActiveWindow()
                if edit and edit.HighlightText then edit:HighlightText() end
            end)

            cursorX = cursorX + bw + ROW_GAP_X
        end

        local consumedH = (y - rowY) + lineH + 4
        y = y - math.max(14, consumedH)
    end
    y = y - 4

    -- Editable fields: btag, discord, notes
    local function FieldRow(label, key)
        local row = adopt(CreateFrame("Frame", nil, f))
        row:SetPoint("TOPLEFT", 14, y)
        row:SetPoint("RIGHT", -10, 0)
        row:SetHeight(18)

        local lbl = adopt(row:CreateFontString(nil, "OVERLAY"))
        VPT.SetFont(lbl, 10, "OUTLINE")
        lbl:SetPoint("LEFT", 0, 0)
        lbl:SetText(C_GOLD .. label .. ":|r")
        lbl:SetWidth(70)
        lbl:SetJustifyH("LEFT")

        local val = adopt(row:CreateFontString(nil, "OVERLAY"))
        VPT.SetFont(val, 10)
        val:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
        val:SetPoint("RIGHT", -50, 0)
        val:SetJustifyH("LEFT")
        local v = entry[key] or ""
        if v == "" then
            val:SetText(C_DIM .. "(empty — click Edit)|r")
        else
            val:SetText(C_WHITE .. v .. "|r")
        end

        local btn = adopt(CreateFrame("Button", nil, row, "BackdropTemplate"))
        btn:SetSize(40, 16)
        btn:SetPoint("RIGHT", 0, 0)
        VPT.CreateBackdrop(btn, 0.85)
        local btnText = btn:CreateFontString(nil, "OVERLAY")
        VPT.SetFont(btnText, 9, "OUTLINE")
        btnText:SetPoint("CENTER")
        btnText:SetText("Edit")
        btn:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(0, 0.78, 1, 1) end)
        btn:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(0, 0.78, 1, 0.5) end)
        btn:SetScript("OnClick", function()
            ShowEditPopup("Edit " .. label .. ":", entry[key] or "", function(newVal)
                entry[key] = newVal
                VPT.PutLockout(entry.key, entry)
                RenderDetail(entry, parentRow)
            end)
        end)

        y = y - 20
    end

    FieldRow("Btag", "btag")
    FieldRow("Discord", "discord")
    FieldRow("Notes", "notes")

    -- Alt-linking display: if the leader's btag has other known characters,
    -- show them so the user knows "this is the same human as X-Realm".
    if entry.btag and entry.btag ~= "" and VPT.GetCharsForBtag then
        local alts = VPT.GetCharsForBtag(entry.btag)
        if alts and #alts > 1 then
            local altRow = adopt(f:CreateFontString(nil, "OVERLAY"))
            VPT.SetFont(altRow, 10)
            altRow:SetPoint("TOPLEFT", 14, y)
            altRow:SetPoint("RIGHT", -10, 0)
            altRow:SetJustifyH("LEFT")
            altRow:SetWordWrap(true)
            local others = {}
            for _, n in ipairs(alts) do
                if n ~= entry.leader then table.insert(others, n) end
            end
            altRow:SetText(C_GOLD .. "Known alts:|r " .. C_DIM .. table.concat(others, ", ") .. "|r")
            y = y - math.max(14, altRow:GetStringHeight() + 2)
        end
    end

    -- Star rating row — click a star to set entry.rating (1-5), click the
    -- same star again to clear.
    local rateRow = adopt(CreateFrame("Frame", nil, f))
    rateRow:SetPoint("TOPLEFT", 14, y)
    rateRow:SetPoint("RIGHT", -10, 0)
    rateRow:SetHeight(18)
    local rateLbl = adopt(rateRow:CreateFontString(nil, "OVERLAY"))
    VPT.SetFont(rateLbl, 10, "OUTLINE")
    rateLbl:SetPoint("LEFT", 0, 0)
    rateLbl:SetText(C_GOLD .. "Rating:|r")
    rateLbl:SetWidth(70)
    rateLbl:SetJustifyH("LEFT")

    local STAR_FULL  = "★"
    local STAR_EMPTY = "☆"
    local rating = entry.rating or 0
    for i = 1, 5 do
        local star = adopt(CreateFrame("Button", nil, rateRow))
        star:SetSize(18, 18)
        star:SetPoint("LEFT", rateLbl, "RIGHT", 4 + (i - 1) * 18, 0)
        local sfs = star:CreateFontString(nil, "OVERLAY")
        VPT.SetFont(sfs, 14, "OUTLINE")
        sfs:SetPoint("CENTER")
        if i <= rating then
            sfs:SetText("|cffffd100" .. STAR_FULL .. "|r")
        else
            sfs:SetText("|cff606060" .. STAR_EMPTY .. "|r")
        end
        star:SetScript("OnEnter", function() sfs:SetScale(1.2) end)
        star:SetScript("OnLeave", function() sfs:SetScale(1.0) end)
        star:SetScript("OnClick", function()
            -- Toggle: clicking the current star clears the rating
            if entry.rating == i then
                entry.rating = nil
            else
                entry.rating = i
            end
            VPT.PutLockout(entry.key, entry)
            RenderDetail(entry, parentRow)
        end)
    end
    -- "Clear rating" hint when set
    if rating > 0 then
        local hint = adopt(rateRow:CreateFontString(nil, "OVERLAY"))
        VPT.SetFont(hint, 9, "")
        hint:SetPoint("LEFT", rateLbl, "RIGHT", 4 + 5 * 18 + 8, 0)
        hint:SetText(C_DIM .. "(click again to clear)|r")
    end
    y = y - 20

    -- Tags row — comma-separated freeform list, editable like other fields.
    -- Common tags: drama, ninja, smooth, fast, slow, great-caller, friendly
    local tagsRow = adopt(CreateFrame("Frame", nil, f))
    tagsRow:SetPoint("TOPLEFT", 14, y)
    tagsRow:SetPoint("RIGHT", -10, 0)
    tagsRow:SetHeight(18)
    local tagLbl = adopt(tagsRow:CreateFontString(nil, "OVERLAY"))
    VPT.SetFont(tagLbl, 10, "OUTLINE")
    tagLbl:SetPoint("LEFT", 0, 0)
    tagLbl:SetText(C_GOLD .. "Tags:|r")
    tagLbl:SetWidth(70)
    tagLbl:SetJustifyH("LEFT")
    local tagsVal = adopt(tagsRow:CreateFontString(nil, "OVERLAY"))
    VPT.SetFont(tagsVal, 10)
    tagsVal:SetPoint("LEFT", tagLbl, "RIGHT", 4, 0)
    tagsVal:SetPoint("RIGHT", -50, 0)
    tagsVal:SetJustifyH("LEFT")
    local tagsStr = (entry.tags and #entry.tags > 0)
        and table.concat(entry.tags, ", ") or ""
    if tagsStr == "" then
        tagsVal:SetText(C_DIM .. "(empty — click Edit, comma-separated)|r")
    else
        -- Color tags subtly so they read as chips even without backdrop
        tagsVal:SetText("|cff9cb4ff" .. tagsStr .. "|r")
    end
    local tagBtn = adopt(CreateFrame("Button", nil, tagsRow, "BackdropTemplate"))
    tagBtn:SetSize(40, 16)
    tagBtn:SetPoint("RIGHT", 0, 0)
    VPT.CreateBackdrop(tagBtn, 0.85)
    local tagBtnText = tagBtn:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(tagBtnText, 9, "OUTLINE")
    tagBtnText:SetPoint("CENTER")
    tagBtnText:SetText("Edit")
    tagBtn:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(0, 0.78, 1, 1) end)
    tagBtn:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(0, 0.78, 1, 0.5) end)
    tagBtn:SetScript("OnClick", function()
        ShowEditPopup("Edit Tags (comma-separated):", tagsStr, function(newVal)
            -- Split on comma, trim whitespace, drop empties
            local arr = {}
            for tok in (newVal or ""):gmatch("[^,]+") do
                local clean = tok:gsub("^%s+", ""):gsub("%s+$", "")
                if clean ~= "" then table.insert(arr, clean) end
            end
            entry.tags = (#arr > 0) and arr or nil
            VPT.PutLockout(entry.key, entry)
            RenderDetail(entry, parentRow)
        end)
    end)
    y = y - 20

    y = y - 4

    -- Action buttons: Whisper Btag, Delete
    local function ActionBtn(label, xOffset, color, onClick)
        local btn = adopt(CreateFrame("Button", nil, f, "BackdropTemplate"))
        btn:SetSize(110, 18)
        btn:SetPoint("TOPLEFT", 14 + xOffset, y)
        VPT.CreateBackdrop(btn, 0.85)
        if color then btn:SetBackdropBorderColor(color[1], color[2], color[3], 0.7) end
        local txt = btn:CreateFontString(nil, "OVERLAY")
        VPT.SetFont(txt, 10, "OUTLINE")
        txt:SetPoint("CENTER")
        txt:SetText(label)
        btn:SetScript("OnEnter", function(s)
            if color then s:SetBackdropBorderColor(color[1], color[2], color[3], 1) end
        end)
        btn:SetScript("OnLeave", function(s)
            if color then s:SetBackdropBorderColor(color[1], color[2], color[3], 0.7) end
        end)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    -- Row 1: contact actions
    -- "Bnet Whisper" — only works if target is already a Battle.net friend.
    -- We check the friends list first: if the btag matches a current friend,
    -- open the chat with /bnwhisper pre-filled. Otherwise tell the user they
    -- need to add the person as a Bnet friend first (the /bnwhisper command
    -- silently does nothing for non-friends — common user confusion source).
    local whisperLabel = (entry.btag and entry.btag ~= "")
        and ("Bnet Whisper") or ("Whisper " .. (entry.leader and entry.leader:match("^[^-]+") or "Lead"))
    ActionBtn(whisperLabel, 0, VPT.palette.green, function()
        if entry.btag and entry.btag ~= "" then
            local cleanBtag = entry.btag:gsub("^%s+", ""):gsub("%s+$", "")
            -- Look up the BNet friend by battletag (case-insensitive). If
            -- found, use ChatFrame_SendBNetTell which opens the Bnet whisper
            -- conversation properly — this is what Blizzard's friends UI
            -- uses when you double-click a friend.
            local foundFriend, accountName = nil, nil
            if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
                for i = 1, BNGetNumFriends() do
                    local info = C_BattleNet.GetFriendAccountInfo(i)
                    if info and info.battleTag
                       and info.battleTag:lower() == cleanBtag:lower() then
                        foundFriend = info
                        accountName = info.accountName
                        break
                    end
                end
            end
            if foundFriend then
                -- ChatFrame_SendBNetTell takes the BNet ACCOUNT NAME (the
                -- display name, NOT the battletag). Opens a whisper window
                -- targeted at that friend.
                if ChatFrame_SendBNetTell and accountName then
                    ChatFrame_SendBNetTell(accountName)
                else
                    -- Fallback: pre-fill chat with /bnwhisper
                    ChatFrame_OpenChat("/bnwhisper " .. cleanBtag .. " ")
                end
            else
                VPT.Print(VPT.C_GOLD .. cleanBtag .. "|r " .. C_DIM ..
                    "isn't on your Bnet friends list — /bnwhisper only works for friends.|r")
                VPT.Print("  " .. C_DIM .. "Click |r" .. C_CYAN .. "Add Bnet|r " ..
                    C_DIM .. "to invite them first, then try Bnet Whisper after they accept.|r")
            end
        elseif entry.leader and entry.leader ~= "" then
            ChatFrame_OpenChat("/w " .. entry.leader .. " ")
        else
            VPT.Print(C_RED .. "No leader name captured yet.|r")
        end
    end)

    -- "Add WoW Friend" — character-only friend. Instant, no btag needed.
    -- Best for same-realm or connected-realm leaders.
    ActionBtn("Add WoW Friend", 120, VPT.palette.accent, function()
        if not entry.leader or entry.leader == "" then
            VPT.Print(C_RED .. "No leader name captured.|r")
            return
        end
        if C_FriendList and C_FriendList.AddFriend then
            C_FriendList.AddFriend(entry.leader)
            VPT.Print(C_GREEN .. "Added " .. entry.leader .. " as WoW friend.|r " ..
                C_DIM .. "(character-level — only works cross-realm if connected)|r")
        else
            ChatFrame_OpenChat("/friend " .. entry.leader)
        end
    end)

    -- "Add Bnet" — opens the Friends panel Add-Friend dialog, pre-fills the
    -- name field with the leader's btag (if we have one). The user just has
    -- to click "Send Invite" to send the BNet friend request.
    ActionBtn("Add Bnet", 240, VPT.palette.gold, function()
        if not FriendsFrame:IsShown() then ToggleFriendsFrame(1) end
        if FriendsFrame_AddFriendClick then FriendsFrame_AddFriendClick() end
        -- Try to pre-fill the name editbox in the popup. Blizzard's popup is
        -- StaticPopup "ADD_FRIEND" using the standard editBox slot. Defer
        -- briefly so the popup has time to spawn.
        if entry.btag and entry.btag ~= "" then
            local cleanBtag = entry.btag:gsub("^%s+", ""):gsub("%s+$", "")
            C_Timer.After(0.1, function()
                -- STATICPOPUP_NUMDIALOGS isn't reliably defined in 12.0;
                -- walk until we run out of StaticPopupN frames (Blizzard
                -- typically allocates 4-5).
                local i = 1
                while true do
                    local popup = _G["StaticPopup" .. i]
                    if not popup then break end
                    if popup:IsShown() and popup.which == "ADD_FRIEND" then
                        if popup.editBox then
                            popup.editBox:SetText(cleanBtag)
                            popup.editBox:HighlightText()
                            popup.editBox:SetFocus()
                        end
                        break
                    end
                    i = i + 1
                    if i > 20 then break end  -- safety
                end
            end)
            VPT.Print(C_GREEN .. "Pre-filled btag:|r " .. C_WHITE .. cleanBtag ..
                "|r " .. C_DIM .. "(click Send Invite)|r")
        else
            VPT.Print(C_DIM .. "No btag captured yet. Paste manually in the Add Friend dialog.|r")
        end
    end)

    -- (Removed Copy Roster — per-name click-to-copy is the new flow,
    -- see the roster-name buttons rendered above.)

    y = y - 22

    -- Row 2: secondary actions — Save first so it's the most visible after edits
    ActionBtn("💾 Save (/reload)", 0, VPT.palette.green, VPT.SaveNow)

    ActionBtn("Delete Entry", 120, VPT.palette.red, function()
        ShowDeleteConfirm(entry, function()
            VPT.DeleteLockout(entry.key)
            expandedKey = nil
            mod:Refresh()
        end)
    end)

    -- If we have any auto-detected btags for OTHER raid members, show count
    local extraBtagCount = 0
    if entry.btagsByName then
        for char, btag in pairs(entry.btagsByName) do
            if char ~= entry.leader then extraBtagCount = extraBtagCount + 1 end
        end
    end
    if extraBtagCount > 0 then
        ActionBtn("View Btags (" .. extraBtagCount .. ")", 240, VPT.palette.accent, function()
            local lines = { "Auto-detected btags for raid members:", "" }
            for char, btag in pairs(entry.btagsByName or {}) do
                table.insert(lines, char .. "  →  " .. btag)
            end
            ShowCopyPopup(table.concat(lines, "\n"))
        end)
    end

    -- "Recreate next week" — opens the calendar event editor pre-filled
    -- with this lockout's raid + difficulty + leader. User picks date/time
    -- and confirms. Uses C_Calendar.CreateGuildSignUpEvent (or PlayerEvent
    -- as fallback). MUST be triggered from this button click — AddEvent
    -- is hardware-event-protected.
    ActionBtn("Recreate Next Week", 360, VPT.palette.gold, function()
        if not (C_Calendar and C_Calendar.OpenCalendar) then
            VPT.Print(C_RED .. "Calendar API unavailable.|r")
            return
        end
        -- Determine target date: 7 days from lockout's lastSeen (or now)
        local seed = entry.lastSeen or time()
        local targetUnix = seed + 7 * 86400
        local t = date("*t", targetUnix)
        -- Build a title from raid name + difficulty
        local title = (entry.difficulty or "") .. " " .. (entry.raidName or "Pug")
        title = title:gsub("^%s+", ""):gsub("%s+$", "")
        if title == "" then title = "Pug Raid" end
        -- Build a description with leader, btag, rating, tags for reference
        local descParts = {}
        if entry.leader then table.insert(descParts, "Leader: " .. entry.leader) end
        if entry.btag and entry.btag ~= "" then table.insert(descParts, "Btag: " .. entry.btag) end
        if entry.rating then table.insert(descParts, "Rating: " .. string.rep("*", entry.rating)) end
        if entry.tags and #entry.tags > 0 then
            table.insert(descParts, "Tags: " .. table.concat(entry.tags, ", "))
        end
        table.insert(descParts, "")
        table.insert(descParts, "(Auto-prefilled by VoidPug. Edit time/title before saving.)")
        local desc = table.concat(descParts, "\n")
        -- Force open the calendar to the target date so the user can hit Save
        pcall(C_Calendar.OpenCalendar)
        pcall(C_Calendar.SetAbsMonth, t.month, t.year)
        -- Create event (Guild Sign-up if in a guild, else PlayerEvent)
        local createdSignUp = false
        if IsInGuild and IsInGuild() and C_Calendar.CreateGuildSignUpEvent then
            local ok = pcall(C_Calendar.CreateGuildSignUpEvent)
            if ok then createdSignUp = true end
        end
        if not createdSignUp and C_Calendar.CreatePlayerEvent then
            pcall(C_Calendar.CreatePlayerEvent)
        end
        -- Set fields on the in-progress event
        if C_Calendar.EventSetTitle       then pcall(C_Calendar.EventSetTitle, title) end
        if C_Calendar.EventSetDescription then pcall(C_Calendar.EventSetDescription, desc) end
        if C_Calendar.EventSetDate        then pcall(C_Calendar.EventSetDate, t.month, t.day, t.year) end
        if C_Calendar.EventSetTime        then pcall(C_Calendar.EventSetTime, t.hour, t.min) end
        VPT.Print(C_GREEN .. "Calendar event prefilled.|r " .. C_DIM ..
            "Edit time/title in the open dialog, then click Create.|r")
    end)

    y = y - 24

    -- Adjust detail height to fit content (cap at DETAIL_H)
    local needed = math.max(60, -y + 8)
    f:SetHeight(needed)
end

----------------------------------------------------------------------
-- Row factory
----------------------------------------------------------------------
local function CreateRow(index, parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_H)
    VPT.CreateBackdrop(row, 0.75)
    row:SetBackdropBorderColor(0, 0.78, 1, 0.25)

    -- Indicator triangle (expand state)
    local tri = row:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(tri, 12, "OUTLINE")
    tri:SetPoint("LEFT", 6, 0)
    tri:SetTextColor(0, 0.78, 1)
    row._tri = tri

    -- Raid name
    local name = row:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(name, 11, "OUTLINE")
    name:SetPoint("LEFT", tri, "RIGHT", 8, 0)
    row._name = name

    -- Difficulty
    local diff = row:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(diff, 10)
    diff:SetPoint("LEFT", name, "RIGHT", 6, 0)
    row._diff = diff

    -- Kills
    local kills = row:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(kills, 10)
    kills:SetPoint("LEFT", diff, "RIGHT", 12, 0)
    row._kills = kills

    -- Reset countdown
    local reset = row:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(reset, 10)
    reset:SetPoint("LEFT", kills, "RIGHT", 12, 0)
    row._reset = reset

    -- Leader (right-aligned)
    local leader = row:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(leader, 10)
    leader:SetPoint("RIGHT", -8, 0)
    leader:SetJustifyH("RIGHT")
    leader:SetWidth(180)
    row._leader = leader

    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
        if not self._key then return end
        if expandedKey == self._key then
            expandedKey = nil
        else
            expandedKey = self._key
        end
        mod:Refresh()
    end)

    row:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0, 0.78, 1, 0.7)
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0, 0.78, 1, 0.25)
    end)

    return row
end

----------------------------------------------------------------------
-- Panel builder
----------------------------------------------------------------------
local function CreatePanel()
    if panel then return panel end

    local f = CreateFrame("Frame", "VoidPugPanel", UIParent, "BackdropTemplate")
    f:SetSize(PANEL_W, PANEL_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    VPT.CreateBackdrop(f, 0.95)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(title, 14, "OUTLINE")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetTextColor(0, 0.78, 1)
    title:SetText("VoidPug")
    f.title = title

    -- Subtitle / counts
    local sub = f:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(sub, 10)
    sub:SetPoint("LEFT", title, "RIGHT", 10, 0)
    sub:SetTextColor(0.7, 0.7, 0.7)
    f.sub = sub

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Refresh button
    local refresh = CreateFrame("Button", nil, f, "BackdropTemplate")
    refresh:SetSize(70, 18)
    refresh:SetPoint("TOPRIGHT", -26, -10)
    VPT.CreateBackdrop(refresh, 0.85)
    local rt = refresh:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(rt, 10, "OUTLINE")
    rt:SetPoint("CENTER")
    rt:SetText(C_CYAN .. "Refresh|r")
    refresh:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(0, 0.78, 1, 1) end)
    refresh:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(0, 0.78, 1, 0.5) end)
    refresh:SetScript("OnClick", function()
        if RequestRaidInfo then RequestRaidInfo() end
        local Events = VPT._modules["Events"]
        if Events and Events.RefreshNow then Events:RefreshNow() end
        C_Timer.After(0.5, function() mod:Refresh() end)
    end)

    -- Save Now button — pops a confirm then does /reload to flush data to disk.
    local saveBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    saveBtn:SetSize(90, 18)
    saveBtn:SetPoint("RIGHT", refresh, "LEFT", -6, 0)
    VPT.CreateBackdrop(saveBtn, 0.85)
    saveBtn:SetBackdropBorderColor(0.10, 0.80, 0.35, 0.7)
    local st = saveBtn:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(st, 10, "OUTLINE")
    st:SetPoint("CENTER")
    st:SetText(C_GREEN .. "Save (/reload)|r")
    saveBtn:SetScript("OnEnter", function(s)
        s:SetBackdropBorderColor(0.10, 0.80, 0.35, 1)
        GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Save to Disk")
        GameTooltip:AddLine("Triggers /reload — flushes all in-memory", 0.85, 0.85, 0.85, true)
        GameTooltip:AddLine("data (kills, roster, btags, notes) to disk", 0.85, 0.85, 0.85, true)
        GameTooltip:AddLine("permanently. Takes ~1-2 seconds.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    saveBtn:SetScript("OnLeave", function(s)
        s:SetBackdropBorderColor(0.10, 0.80, 0.35, 0.7)
        GameTooltip:Hide()
    end)
    saveBtn:SetScript("OnClick", VPT.SaveNow)

    -- Filter / search row (between header and scroll list)
    local filterBar = CreateFrame("Frame", nil, f)
    filterBar:SetPoint("TOPLEFT", 10, -32)
    filterBar:SetPoint("TOPRIGHT", -28, -32)
    filterBar:SetHeight(22)
    f.filterBar = filterBar

    -- "Search" label
    local searchLbl = filterBar:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(searchLbl, 10, "OUTLINE")
    searchLbl:SetPoint("LEFT", 0, 0)
    searchLbl:SetText(C_DIM .. "Search:|r")

    -- Search EditBox (free-text name / leader / btag substring match)
    local searchBox = CreateFrame("EditBox", nil, filterBar, "BackdropTemplate")
    searchBox:SetSize(180, 18)
    searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 6, 0)
    searchBox:SetFontObject(ChatFontNormal)
    searchBox:SetAutoFocus(false)
    VPT.CreateBackdrop(searchBox, 0.85)
    searchBox:SetBackdropBorderColor(0, 0.78, 1, 0.4)
    searchBox:SetTextInsets(4, 4, 0, 0)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); mod:Refresh() end)
    searchBox:SetScript("OnTextChanged", function(self)
        VPT._searchFilter = self:GetText() or ""
        mod:Refresh()
    end)
    f.searchBox = searchBox

    -- Difficulty filter — chips that toggle. Default: all on.
    VPT._diffFilter = VPT._diffFilter or { Mythic = true, Heroic = true, Normal = true, LFR = true }
    local diffOrder = { "Mythic", "Heroic", "Normal", "LFR" }
    local prev = nil
    for _, d in ipairs(diffOrder) do
        local chip = CreateFrame("Button", nil, filterBar, "BackdropTemplate")
        chip:SetSize(58, 18)
        if prev then chip:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else chip:SetPoint("LEFT", searchBox, "RIGHT", 12, 0) end
        VPT.CreateBackdrop(chip, 0.85)
        local ct = chip:CreateFontString(nil, "OVERLAY")
        VPT.SetFont(ct, 9, "OUTLINE")
        ct:SetPoint("CENTER")
        local function paint()
            if VPT._diffFilter[d] then
                ct:SetText(ColorForDifficulty(d) .. d .. "|r")
                chip:SetBackdropBorderColor(0, 0.78, 1, 0.7)
            else
                ct:SetText(C_DIM .. d .. "|r")
                chip:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.5)
            end
        end
        paint()
        chip:SetScript("OnClick", function()
            VPT._diffFilter[d] = not VPT._diffFilter[d]
            paint()
            mod:Refresh()
        end)
        prev = chip
    end

    -- Active-only toggle (default off — show all by default)
    local activeChip = CreateFrame("Button", nil, filterBar, "BackdropTemplate")
    activeChip:SetSize(72, 18)
    activeChip:SetPoint("LEFT", prev, "RIGHT", 8, 0)
    VPT.CreateBackdrop(activeChip, 0.85)
    local at = activeChip:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(at, 9, "OUTLINE")
    at:SetPoint("CENTER")
    local function paintActive()
        if VPT._activeOnly then
            at:SetText(C_GREEN .. "Active only|r")
            activeChip:SetBackdropBorderColor(0.10, 0.80, 0.35, 0.9)
        else
            at:SetText(C_DIM .. "Active only|r")
            activeChip:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.5)
        end
    end
    paintActive()
    activeChip:SetScript("OnClick", function()
        VPT._activeOnly = not VPT._activeOnly
        paintActive()
        mod:Refresh()
    end)

    -- Scroll frame for lockout list
    local scroll = CreateFrame("ScrollFrame", "VoidPugScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -58)
    scroll:SetPoint("BOTTOMRIGHT", -28, 32)
    f.scroll = scroll

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(PANEL_W - 38, 1)
    scroll:SetScrollChild(child)
    f.scrollChild = child

    -- Footer hint
    local foot = f:CreateFontString(nil, "OVERLAY")
    VPT.SetFont(foot, 9)
    foot:SetPoint("BOTTOM", 0, 10)
    foot:SetTextColor(0.5, 0.5, 0.55)
    foot:SetText("/vpt to toggle  •  Click row to expand  •  Refresh polls live raid info")
    f.foot = foot

    -- ESC closes
    tinsert(UISpecialFrames, "VoidPugPanel")

    f:Hide()
    panel = f
    return f
end

----------------------------------------------------------------------
-- Refresh the row list
----------------------------------------------------------------------
function mod:Refresh()
    if not panel or not panel:IsShown() then return end

    -- Hide all existing rows + detail
    for _, r in ipairs(rowFrames) do r:Hide() end
    if detailFrame then detailFrame:Hide() end

    local activeCount, expiredCount = VPT.CountLockouts()

    -- Show "Last saved" — this addon session loaded at sessionStartTime.
    -- That's the last guaranteed disk write. Any changes since then are
    -- in-memory only until next /reload or logout.
    local Events = VPT._modules["Events"]
    local sessionStart = Events and Events.GetSessionStartTime and
        Events:GetSessionStartTime() or time()
    local minutesSince = math.floor((time() - sessionStart) / 60)
    local savedColor = C_GREEN
    local savedSuffix = ""
    if minutesSince > 60 then
        savedColor = C_RED
        savedSuffix = " ⚠ /reload to save"
    elseif minutesSince > 15 then
        savedColor = C_GOLD
    end
    panel.sub:SetText(C_DIM .. "(" .. activeCount .. " active, " ..
        expiredCount .. " expired)  •  " .. savedColor .. "last saved " ..
        VPT.FormatDuration(time() - sessionStart) .. " ago" .. savedSuffix .. "|r")

    local child = panel.scrollChild
    local y = 0
    local index = 0

    -- Apply filters from the search row before each iteration. Skip a row
    -- entirely if it doesn't pass.
    local searchTerm = (VPT._searchFilter or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local function passesFilters(entry, isExpired)
        -- Active-only: hide expired
        if VPT._activeOnly and isExpired then return false end
        -- Difficulty: must be in the enabled set (default all on)
        local f = VPT._diffFilter
        if f and entry.difficulty and not f[entry.difficulty] then return false end
        -- Search: substring match against raid name, difficulty, leader, btag, discord, notes, tags, roster names
        if searchTerm ~= "" then
            local hay = (entry.raidName or "") .. " " ..
                        (entry.difficulty or "") .. " " ..
                        (entry.leader or "") .. " " ..
                        (entry.btag or "") .. " " ..
                        (entry.discord or "") .. " " ..
                        (entry.notes or "")
            if entry.tags then
                for _, t in ipairs(entry.tags) do hay = hay .. " " .. t end
            end
            if entry.rosterDetails then
                for n, _ in pairs(entry.rosterDetails) do hay = hay .. " " .. n end
            end
            if not hay:lower():find(searchTerm, 1, true) then return false end
        end
        return true
    end

    VPT.ForEachLockout(function(key, entry, isExpired)
        if not passesFilters(entry, isExpired) then return end
        index = index + 1
        local row = rowFrames[index]
        if not row then
            row = CreateRow(index, child)
            rowFrames[index] = row
        end
        row:SetParent(child)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
        row._key = key

        local isExpanded = (expandedKey == key)
        row._tri:SetText(isExpanded and "▼" or "▶")

        row._name:SetText((isExpired and C_DIM or C_WHITE) ..
            (entry.raidName or "?") .. "|r")
        row._diff:SetText(ColorForDifficulty(entry.difficulty) ..
            (entry.difficulty or "?") .. "|r")
        row._kills:SetText(C_GOLD .. CountKills(entry) .. "|r " ..
            C_DIM .. "kills|r")
        row._reset:SetText(isExpired and (C_DIM .. "expired|r") or FormatResetCountdown(entry))
        -- Leader text with optional star-rating prefix (★★★☆☆-style)
        local starsPrefix = ""
        if entry.rating and entry.rating > 0 then
            local filled = string.rep("★", entry.rating)
            local empty  = string.rep("☆", 5 - entry.rating)
            starsPrefix = "|cffffd100" .. filled .. "|r|cff606060" .. empty .. "|r "
        end
        row._leader:SetText(starsPrefix .. C_DIM .. "lead: |r" .. C_WHITE ..
            (entry.leader or "?") .. "|r")

        if isExpired then
            row:SetBackdropBorderColor(0.4, 0.4, 0.45, 0.4)
        else
            row:SetBackdropBorderColor(0, 0.78, 1, 0.25)
        end
        row:Show()
        y = y - ROW_H - 2

        if isExpanded then
            RenderDetail(entry, row)
            y = y - (detailFrame:GetHeight() + 4)
        end
    end)

    -- Hide any pooled rows beyond the filtered count
    for i = index + 1, #rowFrames do
        if rowFrames[i] then rowFrames[i]:Hide() end
    end

    if index == 0 then
        if not child._emptyText then
            child._emptyText = child:CreateFontString(nil, "OVERLAY")
            VPT.SetFont(child._emptyText, 11)
            child._emptyText:SetPoint("TOP", child, "TOP", 0, -40)
            child._emptyText:SetTextColor(0.6, 0.6, 0.7)
        end
        local hasFilter = (VPT._searchFilter and VPT._searchFilter ~= "")
                       or VPT._activeOnly
        if hasFilter then
            child._emptyText:SetText(
                "No lockouts match the current filters.\n\n" ..
                C_DIM .. "Clear the search box or toggle filters off to see all.|r")
        else
            child._emptyText:SetText(
                "No tracked pug lockouts yet.\n\n" ..
                C_DIM .. "Join a Heroic or Mythic raid and it will appear here automatically.|r")
        end
        child._emptyText:Show()
    elseif child._emptyText then
        child._emptyText:Hide()
    end

    -- Resize scroll child to fit content
    child:SetHeight(math.max(1, -y + 10))
end

----------------------------------------------------------------------
-- Toggle / open / close
----------------------------------------------------------------------
function mod:Toggle()
    CreatePanel()
    if panel:IsShown() then panel:Hide() else
        panel:Show()
        local Events = VPT._modules["Events"]
        if Events and Events.RefreshNow then Events:RefreshNow() end
        mod:Refresh()
    end
end

function mod:Show()
    CreatePanel()
    panel:Show()
    local Events = VPT._modules["Events"]
    if Events and Events.RefreshNow then Events:RefreshNow() end
    mod:Refresh()
    -- If something (e.g. VoidCalendar's plugin button) set a hint key,
    -- expand + scroll to that specific lockout so the user doesn't have to search.
    if VPT._calendarHintKey then
        local hint = VPT._calendarHintKey
        VPT._calendarHintKey = nil  -- consume — only use once per Show
        C_Timer.After(0.05, function() mod:ExpandKey(hint) end)
    end
end

-- Expand a specific lockout row and scroll it into view
function mod:ExpandKey(key)
    if not panel or not panel:IsShown() then return end
    expandedKey = key
    mod:Refresh()
    -- After Refresh re-renders rows, find the one matching the key and scroll to it
    C_Timer.After(0.05, function()
        for _, row in ipairs(rowFrames) do
            if row:IsShown() and row._key == key then
                if panel.scroll and row:GetTop() and panel.scrollChild then
                    -- Compute scroll offset to bring row into view at the top
                    local rowTop = row:GetTop()
                    local viewTop = panel.scroll:GetTop()
                    local rowOffset = (viewTop or 0) - (rowTop or 0)
                    panel.scroll:SetVerticalScroll(math.max(0, rowOffset))
                end
                return
            end
        end
    end)
end

function mod:Hide()
    if panel then panel:Hide() end
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_VOIDPUG1 = "/vpt"
SLASH_VOIDPUG2 = "/pugs"
SlashCmdList["VOIDPUG"] = function(msg)
    dbg("slash: %s", tostring(msg))
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "" or msg == "toggle" then
        mod:Toggle()
    elseif msg == "show" then
        mod:Show()
    elseif msg == "hide" then
        mod:Hide()
    elseif msg == "refresh" then
        if RequestRaidInfo then RequestRaidInfo() end
        local Events = VPT._modules["Events"]
        if Events and Events.RefreshNow then Events:RefreshNow() end
        VPT.Print("Refreshed.")
        if panel and panel:IsShown() then C_Timer.After(0.5, function() mod:Refresh() end) end
    elseif msg == "clear" then
        if not StaticPopupDialogs.VPT_CLEAR_ALL then
            StaticPopupDialogs.VPT_CLEAR_ALL = {
                text         = "Delete ALL VoidPug lockout entries?\nThis cannot be undone.",
                button1      = "Delete All",
                button2      = CANCEL or "Cancel",
                timeout      = 0,
                whileDead    = true,
                hideOnEscape = true,
                preferredIndex = 3,
                OnAccept = function()
                    VoidPugDB.lockouts = {}
                    VPT.Print("All lockout data cleared.")
                    if panel and panel:IsShown() then mod:Refresh() end
                end,
            }
        end
        StaticPopup_Show("VPT_CLEAR_ALL")
    elseif msg == "config" or msg == "settings" then
        VPT.Print("Config (edit in /vpt panel — TODO):")
        local cfg = VPT.GetDB().config
        print("  resetReminderEnabled = " .. tostring(cfg.resetReminderEnabled))
        print("  autoPrintOnJoin      = " .. tostring(cfg.autoPrintOnJoin))
        print("  minDifficultyToTrack = " .. tostring(cfg.minDifficultyToTrack))
    elseif msg == "reminders" then
        local cfg = VPT.GetDB().config
        cfg.resetReminderEnabled = not cfg.resetReminderEnabled
        VPT.Print("Reset reminders " .. (cfg.resetReminderEnabled and
            (C_GREEN .. "enabled|r") or (C_RED .. "disabled|r")))
    elseif msg == "minimap" or msg == "mini" then
        local Minimap = VPT._modules["Minimap"]
        if Minimap and Minimap.Toggle then Minimap:Toggle() end
    elseif msg == "save" or msg == "flush" then
        VPT.SaveNow()
    elseif msg == "migrate" or msg == "merge" then
        local examined, merged, cleaned = VPT.MigrateLockoutKeys()
        VPT.Print("Migration: examined " .. examined ..
            ", merged " .. (merged or 0) .. ", cleaned " .. (cleaned or 0) .. ".")
        if panel and panel:IsShown() then mod:Refresh() end
    elseif msg == "debug" then
        local Events = VPT._modules["Events"]
        local key = Events and Events.GetCurrentKey and Events:GetCurrentKey() or nil
        local name, instanceType, diffID = GetInstanceInfo()
        local nsi = GetNumSavedInstances() or 0
        local lines = {
            "VoidPug debug snapshot:",
            "currentKey: " .. tostring(key),
            "GetInstanceInfo: " .. tostring(name) .. " / " ..
                tostring(instanceType) .. " / diff=" .. tostring(diffID),
            "IsInRaid: " .. tostring(IsInRaid()) .. " / IsInGroup: " .. tostring(IsInGroup()),
            "Saved instances: " .. nsi,
            "Lockout count: " .. tostring(VoidPugDB and VoidPugDB.lockouts and
                (function() local n=0; for _ in pairs(VoidPugDB.lockouts) do n=n+1 end return n end)() or 0),
            "Version: " .. tostring(VPT.version),
        }
        ShowCopyPopup(table.concat(lines, "\n"))
    else
        print(C_CYAN .. "[VoidPug]|r commands:")
        print("  /vpt                  - toggle panel")
        print("  /vpt show             - open panel")
        print("  /vpt hide             - close panel")
        print("  /vpt refresh          - re-poll WoW raid info")
        print("  /vpt save             - write data to disk (does /reload)")
        print("  /vpt minimap          - toggle minimap button")
        print("  /vpt clear            - delete ALL data (confirm)")
        print("  /vpt migrate          - merge duplicate lockout entries")
        print("  /vpt reminders        - toggle 24h-reset chat alerts")
        print("  /vpt config           - show current config")
        print("  /vpt debug            - print raid context")
    end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function mod:Init()
    -- Panel built on first open (no work at load)
end
