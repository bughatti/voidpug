----------------------------------------------------------------------
-- VoidLib.Logger — SavedVariables-backed event logger factory.
--
-- The "WoW addon debugging gold standard" pattern from VoidLFG/Logger.lua:
-- when behavior is unclear, build a logger that writes to SavedVariables,
-- user reproduces issue → /reload → read the log from disk.
--
-- Usage (in <Addon>.toc add: ## SavedVariables: <Addon>DB):
--
--   local Log = VoidLib.Logger.New({
--       svKey       = "VoidLFGDB",        -- root SavedVariables table
--       maxEntries  = 500,                -- FIFO cap
--       captureEvents = {                 -- which events to capture (optional)
--           "ADDON_ACTION_FORBIDDEN",
--           "ADDON_ACTION_BLOCKED",
--           "LUA_WARNING",
--           "PLAYER_REGEN_DISABLED",
--           "PLAYER_REGEN_ENABLED",
--       },
--       label = "VoidLFG",                -- prefix shown in chat
--   })
--
--   -- Custom log entry from anywhere:
--   Log:Log("scan", "started rid=" .. rid)
--
--   -- Wrap every Button OnClick in a frame tree for context:
--   Log:InstrumentFrame(myPanel, "watchpanel")
--
--   -- Slash dispatcher (call from your /slash handler):
--   Log:OnSlash(args)   -- handles {clear|tail N|...}
--
-- Each Logger instance is independent. Two addons can have separate
-- loggers with separate SV tables — no collision.
----------------------------------------------------------------------

local Logger = VoidLib.Logger

local function Stamp()
    return date("%H:%M:%S")
end

----------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------
function Logger.New(opts)
    opts = opts or {}
    local svKey = opts.svKey or error("VoidLib.Logger.New: opts.svKey required")
    local maxEntries = opts.maxEntries or 500
    local label = opts.label or svKey
    local labelColor = opts.labelColor or "00c7ff"

    local self = {
        svKey       = svKey,
        maxEntries  = maxEntries,
        label       = label,
        labelColor  = labelColor,
        _lastTag    = nil,
        _lastCount  = 0,
    }

    --------------------------------------------------------------
    -- SavedVariables access — table is created on first push so
    -- addons can call New() before PLAYER_LOGIN.
    --------------------------------------------------------------
    local function GetLog()
        _G[svKey] = _G[svKey] or {}
        _G[svKey].taintLog = _G[svKey].taintLog or {}
        return _G[svKey].taintLog
    end

    local function Push(line, dedupTag)
        local log = GetLog()
        if dedupTag and dedupTag == self._lastTag and #log > 0 then
            self._lastCount = self._lastCount + 1
            log[#log] = line:gsub("] ", ("] x%d "):format(self._lastCount), 1)
            return
        end
        self._lastTag = dedupTag
        self._lastCount = 1
        log[#log + 1] = line
        while #log > self.maxEntries do
            table.remove(log, 1)
        end
    end

    self._push = Push
    self._getLog = GetLog

    --------------------------------------------------------------
    -- Public: log a custom event
    --------------------------------------------------------------
    function self:Log(category, message)
        Push(("[%s] %s :: %s"):format(Stamp(), category or "log", tostring(message)))
    end

    --------------------------------------------------------------
    -- InstrumentFrame — walk a frame tree, wrap every Button child's
    -- OnClick so it logs (label, button) before invoking the original.
    --
    -- Idempotent via _loggerWrapped flag — call repeatedly to catch
    -- newly-created buttons. The label prefers the button's _label
    -- fontstring text, falling back to GetName() or path.
    --
    -- CRITICAL: skips IsProtected() frames. SetScript on a
    -- SecureActionButton triggers ADDON_ACTION_FORBIDDEN.
    --------------------------------------------------------------
    local function LabelOf(frame, path)
        if frame._label and frame._label.GetText then
            local t = frame._label:GetText()
            if t and t ~= "" then
                t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                return t
            end
        end
        return frame:GetName() or path or "?"
    end

    function self:InstrumentFrame(rootFrame, prefix)
        if not rootFrame or not rootFrame.GetObjectType then return end
        local count = 0
        local function walk(frame, path)
            if not frame.GetObjectType then return end
            local ok, ftype = pcall(frame.GetObjectType, frame)
            if not ok then return end
            if ftype == "Button" and not frame._loggerWrapped then
                local isProtected = false
                if frame.IsProtected then
                    local okp, p = pcall(frame.IsProtected, frame)
                    if okp and p then isProtected = true end
                end
                if not isProtected then
                    local orig = frame:GetScript("OnClick")
                    local btnLabel = LabelOf(frame, path)
                    frame:SetScript("OnClick", function(f, btn, ...)
                        self:Log("click", (btnLabel or "?") .. " mouse=" .. tostring(btn))
                        if orig then return orig(f, btn, ...) end
                    end)
                    frame._loggerWrapped = true
                    count = count + 1
                else
                    frame._loggerWrapped = true
                end
            end
            if frame.GetChildren then
                local okC, children = pcall(function() return { frame:GetChildren() } end)
                if okC and children then
                    for i, child in ipairs(children) do
                        walk(child, (path or prefix or "panel") .. "/" .. (child:GetName() or ("#" .. i)))
                    end
                end
            end
        end
        walk(rootFrame, prefix or "panel")
        if count > 0 then
            self:Log("instrument", ("wrapped %d new button(s) under %s"):format(count, prefix or "panel"))
        end
    end

    --------------------------------------------------------------
    -- Event capture
    --------------------------------------------------------------
    if opts.captureEvents and #opts.captureEvents > 0 then
        local ef = CreateFrame("Frame")
        for _, ev in ipairs(opts.captureEvents) do ef:RegisterEvent(ev) end
        ef:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
            if event == "ADDON_ACTION_FORBIDDEN" then
                local tag = "FORBIDDEN:" .. tostring(arg1) .. ":" .. tostring(arg2)
                Push(("[%s] FORBIDDEN :: addon=%s func=%s"):format(
                    Stamp(), tostring(arg1), tostring(arg2)), tag)
            elseif event == "ADDON_ACTION_BLOCKED" then
                local tag = "BLOCKED:" .. tostring(arg1) .. ":" .. tostring(arg2)
                Push(("[%s] BLOCKED :: addon=%s func=%s"):format(
                    Stamp(), tostring(arg1), tostring(arg2)), tag)
            elseif event == "LUA_WARNING" then
                Push(("[%s] LUA_WARN :: %s %s"):format(
                    Stamp(), tostring(arg1), tostring(arg2)))
            elseif event == "PLAYER_REGEN_DISABLED" then
                Push(("[%s] combat-enter"):format(Stamp()))
            elseif event == "PLAYER_REGEN_ENABLED" then
                Push(("[%s] combat-leave"):format(Stamp()))
            else
                Push(("[%s] %s :: %s %s"):format(
                    Stamp(), event, tostring(arg1), tostring(arg2)))
            end
        end)
    end

    --------------------------------------------------------------
    -- Boot stamp
    --------------------------------------------------------------
    Push(("[%s] === %s Logger started (session boot) ==="):format(Stamp(), label))

    --------------------------------------------------------------
    -- Slash dispatcher
    --------------------------------------------------------------
    function self:OnSlash(args)
        args = (args or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        local log = GetLog()
        local prefix = ("|cff%s%s log:|r"):format(self.labelColor, self.label)
        if args == "clear" then
            wipe(log)
            Push(("[%s] === log cleared ==="):format(Stamp()))
            print(prefix .. " cleared.")
        elseif args:match("^tail") then
            local n = tonumber(args:match("^tail%s+(%d+)")) or 20
            local start = math.max(1, #log - n + 1)
            print(("%s last %d of %d entries"):format(prefix, math.min(n, #log), #log))
            for i = start, #log do print("  " .. log[i]) end
        else
            print(("%s %d entries (use 'tail 30' to see recent)"):format(prefix, #log))
            print("  clear   — wipe the log")
            print("  tail N  — print last N entries")
            print(("  Raw log: WTF/Account/<acct>/SavedVariables/%s.lua → %s.taintLog"):format(self.label, self.svKey))
        end
    end

    return self
end
