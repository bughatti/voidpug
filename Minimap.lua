----------------------------------------------------------------------
-- VoidPug Minimap — standardized minimap button matching
-- VoidFisher / VoidProf / VoidDice spec from void-addons-architecture
-- memory.
--
--   Size: 28x28 button, 20x20 icon, 54x54 border
--   Border offset: (-2, 2)
--   Radius: (Minimap:GetWidth() / 2) + 6
--   Angle stored in VoidPugCharDB.minimapAngle as DEGREES
--   Default angle: 195
--
-- Click behavior:
--   Left-click  -> toggle /vpt panel
--   Right-click -> Save now (/reload prompt)
--   Drag        -> orbit around minimap edge
----------------------------------------------------------------------
local _, VPT = ...
local mod = VPT:NewModule("Minimap")

local btn

local function PositionButton(b)
    local cdb = VPT.GetCharDB()
    local angle = math.rad(cdb.minimapAngle or 195)
    local radius = (Minimap:GetWidth() / 2) + 6
    local x = radius * math.cos(angle)
    local y = radius * math.sin(angle)
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if btn then return btn end

    btn = CreateFrame("Button", "VoidPugMinimapBtn", Minimap)
    btn:SetSize(28, 28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 10)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    -- INV_Misc_GroupLooking = the universal LFG/group icon, perfect for
    -- pug tracking. Known-stable path that ships in every WoW build.
    icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn._icon = icon

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Click handlers
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, button)
        local UI = VPT._modules["UI"]
        if button == "RightButton" then
            VPT.SaveNow()
        else
            if UI and UI.Toggle then UI:Toggle() end
        end
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff00c7ffVoidPug|r", 1, 1, 1)
        local active, expired = VPT.CountLockouts()
        GameTooltip:AddLine("Active: |cffffffff" .. active .. "|r  Expired: |cff8c8c9e" .. expired .. "|r", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: toggle panel", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-click: save (/reload)", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Drag: reposition around minimap", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Drag to orbit. Angle stored in DEGREES to char-DB; PositionButton converts.
    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self) self._dragging = true end)
    btn:SetScript("OnDragStop",  function(self) self._dragging = false end)
    btn:SetScript("OnUpdate", function(self)
        if self._dragging then
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            if not mx or not px or not scale then return end
            px = px / scale; py = py / scale
            local angle = math.deg(math.atan2(py - my, px - mx))
            local cdb = VPT.GetCharDB()
            cdb.minimapAngle = angle
            PositionButton(self)
        end
    end)

    PositionButton(btn)
    return btn
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function mod:Init()
    -- Build at PLAYER_LOGIN so Minimap exists
end

function mod:Enable()
    VPT.GetCharDB()  -- ensure defaults
    CreateMinimapButton()
    if VoidPugCharDB.minimapHidden then
        btn:Hide()
    end
end

----------------------------------------------------------------------
-- Public toggle
----------------------------------------------------------------------
function mod:Toggle()
    if not btn then return end
    if btn:IsShown() then
        btn:Hide()
        VoidPugCharDB.minimapHidden = true
        VPT.Print(VPT.C_DIM .. "Minimap button hidden — /vpt minimap to show again.|r")
    else
        btn:Show()
        VoidPugCharDB.minimapHidden = false
        VPT.Print(VPT.C_DIM .. "Minimap button shown.|r")
    end
end
