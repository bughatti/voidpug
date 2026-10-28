----------------------------------------------------------------------
-- VoidLib — shared utility library for Void* addons.
--
-- EMBEDDED, never an external dependency. Each addon ships its own copy under
-- Libs/VoidLib/ and loads these three files at the TOP of its .toc (VoidLib.lua
-- first). This keeps every published addon self-contained — players installing
-- one addon from CurseForge need nothing else. Do NOT reintroduce a
-- `## Dependencies: VoidLib` line or a runtime LoadAddOn("VoidLib") call.
-- Keep embedded copies in sync via: tools/cmd/sync-libs  (see OPERATIONS.md).
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
