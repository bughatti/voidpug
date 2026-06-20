----------------------------------------------------------------------
-- VoidLib — shared utility library for Void* addons.
--
-- Loaded as a hard dependency by Void* addons via:
--   ## Dependencies: VoidLib
--
-- Public surface:
--   VoidLib.VERSION                -- semver string
--   VoidLib.Secrets                -- secret-value safety helpers
--   VoidLib.Logger                 -- SavedVariables-backed event logger
--
-- Convention: addons grab a short local alias at file top, e.g.
--   local VL = VoidLib
--   local S  = VL.Secrets
----------------------------------------------------------------------

VoidLib = VoidLib or {}
VoidLib.VERSION = "0.1.0"

-- Sub-namespaces are populated by sibling files (Secrets.lua, Logger.lua).
-- Order matters in TOC: VoidLib.lua FIRST so the table exists.
VoidLib.Secrets = VoidLib.Secrets or {}
VoidLib.Logger  = VoidLib.Logger  or {}
