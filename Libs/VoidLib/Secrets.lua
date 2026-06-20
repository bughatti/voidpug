----------------------------------------------------------------------
-- VoidLib.Secrets — 12.0.5 secret-value safety helpers.
--
-- Strategy (from VoidAH v1.1.0, originally adapted from
-- ChonkyCharacterSheet utils.lua:2625):
--
--   1. AreSecretsDisabled() — short-circuit code paths early when
--      we know secret values WILL be returned (combat, M+, encounter,
--      arena, BG). Cheaper than per-field checking.
--
--   2. IsSecret(v) — predicate. Uses `issecretvalue` global if present;
--      false otherwise. Pure check, no side effects.
--
--   3. SafeNum(v) — number-or-nil. Use before arithmetic/comparison.
--      Strips secret values, coerces strings via tonumber.
--
--   4. SafeMoney(copper) — money string or "—". Uses VoidUI:FormatMoney
--      if available, else tostring.
--
--   5. SafeMul(a, b) — multiplication of potentially-secret operands.
--
--   6. SafeKey(s) — string scrubbed via scrubsecretvalues for use as
--      a Lua table key. Returns nil if scrub fails. UnitName/nameplate
--      strings can be "secret strings" that error when used as keys.
--
--   7. SafeGet(t, k) / SafeSet(t, k, v) — table access wrappers that
--      SafeKey the key first. Use when keying off names/GUIDs from
--      tainted unit APIs.
--
-- All helpers are no-ops on non-12.0 clients (issecretvalue absent).
----------------------------------------------------------------------

local S = VoidLib.Secrets

----------------------------------------------------------------------
-- Whole-context gating
----------------------------------------------------------------------
function S.AreSecretsDisabled()
    if InCombatLockdown() then return true end
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID
       and C_ChallengeMode.GetActiveChallengeMapID() then return true end
    if C_InstanceEncounter and C_InstanceEncounter.IsEncounterInProgress
       and C_InstanceEncounter.IsEncounterInProgress() then return true end
    local _, instanceType = IsInInstance()
    if instanceType == "pvp" or instanceType == "arena" then return true end
    return false
end

----------------------------------------------------------------------
-- Predicate
----------------------------------------------------------------------
function S.IsSecret(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return true end
    return false
end

----------------------------------------------------------------------
-- Number coercion
----------------------------------------------------------------------
function S.SafeNum(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    if type(v) == "number" then return v end
    return tonumber(v)
end

----------------------------------------------------------------------
-- Money formatting
----------------------------------------------------------------------
function S.SafeMoney(copper)
    local n = S.SafeNum(copper)
    if not n then return "—" end
    if VoidUI and VoidUI.FormatMoney then return VoidUI:FormatMoney(n) end
    return tostring(n)
end

----------------------------------------------------------------------
-- Arithmetic on possibly-secret operands
----------------------------------------------------------------------
function S.SafeMul(a, b)
    local na, nb = S.SafeNum(a), S.SafeNum(b)
    if not na or not nb then return nil end
    return na * nb
end

function S.SafeAdd(a, b)
    local na, nb = S.SafeNum(a), S.SafeNum(b)
    if not na or not nb then return nil end
    return na + nb
end

----------------------------------------------------------------------
-- String → safe table key
----------------------------------------------------------------------
function S.SafeKey(s)
    if s == nil then return nil end
    if type(s) ~= "string" then return s end
    if scrubsecretvalues then
        local ok, scrubbed = pcall(scrubsecretvalues, s)
        if ok and scrubbed then return scrubbed end
        return nil
    end
    return s
end

----------------------------------------------------------------------
-- Table access wrappers
----------------------------------------------------------------------
function S.SafeGet(t, k)
    if not t then return nil end
    local sk = S.SafeKey(k)
    if sk == nil then return nil end
    return t[sk]
end

function S.SafeSet(t, k, v)
    if not t then return end
    local sk = S.SafeKey(k)
    if sk == nil then return end
    t[sk] = v
end
