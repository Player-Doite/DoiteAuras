---------------------------------------------------------------
-- DoiteTrack.lua
-- Dynamic aura duration recorder + runtime remaining-time API
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

local DoiteTrack = {}
_G["DoiteTrack"] = DoiteTrack

-- Forward declarations (these are used before the utility section is defined)
local _playerGUID_cached
local _GetPlayerGUID
local _HookCancelPlayerBuff

function DoiteTrack:_OnPlayerLogin()
    UnitExists       = _G.UnitExists
    GetUnitField     = _G.GetUnitField
    SpellInfo        = _G.SpellInfo
    CancelPlayerBuff = _G.CancelPlayerBuff

    -- Nampower: enable AuraCast events
    local SetCVar = _G.SetCVar
    if SetCVar then
        pcall(SetCVar, "NP_EnableAuraCastEvents", "1")
    end

    -- Hook right-click buff cancel (prevents false "fade" recordings on player)
    if _HookCancelPlayerBuff then
        _HookCancelPlayerBuff()
    end

    _playerGUID_cached = nil
    _GetPlayerGUID()
    self:RebuildWatchList()

    -- profile signature + arm correction checks
    self:_OnProfileMaybeChanged("entering_world")
end

---------------------------------------------------------------
-- DB wiring
---------------------------------------------------------------
local function _GetDB()
    local db = _G["DoiteAurasDB"]

    -- If the core addon hasn’t created it yet, create a minimal one.
    if not db then
        db = {}
        _G["DoiteAurasDB"] = db
    end

    db.trackedDurations     = db.trackedDurations     or {}  -- [spellId] = seconds (no combo)
    db.trackedDurationsCP   = db.trackedDurationsCP   or {}  -- [spellId] = { [cp] = seconds }
    db.trackedDurationsMeta = db.trackedDurationsMeta or {}  -- meta info (name, rank, samples, etc.)

    -- correction layer (talents/gear) overrides DBC when present. These are temporary: wiped when gear/talents signature changes.
    db.correctedDurations     = db.correctedDurations     or {}  -- [spellId] = seconds (rounded)
    db.correctedDurationsCP   = db.correctedDurationsCP   or {}  -- [spellId] = { [cp] = seconds (rounded) }
    db.correctedChecked       = db.correctedChecked       or {}  -- [spellId] = true (checked this profile/session; may or may not need override)
    db.correctedCheckedCP     = db.correctedCheckedCP     or {}  -- [spellId] = { [cp] = true }
    db.correctedProfileSig    = db.correctedProfileSig    or nil -- string signature for gear+talents

    return db
end


-- Global maps
local TrackedBySpellId      = {}  -- [spellId] = entry
local TrackedByNameNorm     = {}  -- [normName] = entry
local RecentCastBySpellId   = {}  -- [spellId] = lastCastTime

---------------------------------------------------------------
-- Local API shortcuts
---------------------------------------------------------------
local GetTime        = GetTime
local UnitClass      = UnitClass
local UnitExists     = UnitExists
local UnitIsDead     = UnitIsDead
local UnitBuff       = UnitBuff
local UnitDebuff     = UnitDebuff
local GetComboPoints = GetComboPoints

local SpellInfo                = SpellInfo
local GetSpellRecField         = GetSpellRecField
local GetSpellNameAndRankForId = GetSpellNameAndRankForId
local GetSpellIdForName        = GetSpellIdForName
local GetUnitField             = GetUnitField

local str_find = string.find
local str_gsub = string.gsub

---------------------------------------------------------------
-- Utility helpers
---------------------------------------------------------------
local function _Print(msg, r, g, b)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg or "", r or 1.0, g or 1.0, b or 1.0)
    end
end

local function _GetUnitGuidSafe(unit)
    if not unit or not UnitExists then
        return nil
    end

    -- SuperWoW: UnitExists(unit) returns existsFlag, guid
    local exists, guid = UnitExists(unit)
    if exists and guid and guid ~= "" then
        return guid
    end

    return nil
end

_GetPlayerGUID = function()
    if _playerGUID_cached then
        return _playerGUID_cached
    end
    local g = _GetUnitGuidSafe("player")
    if g and g ~= "" then
        _playerGUID_cached = g
        return g
    end
    return nil
end

local function _PlayerUsesComboPoints()
    if not UnitClass then return false end
    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    return (cls == "ROGUE" or cls == "DRUID")
end

local function _GetComboPointsSafe()
    if not GetComboPoints then
        return 0
    end

    local ok, val = pcall(GetComboPoints)
    if ok and type(val) == "number" and val >= 0 then
        return val
    end

    return 0
end

-- Find which visible unit currently matches a GUID.
local function _FindUnitByGuid(guid)
    if not guid or guid == "" then return nil end

    local pg = _GetPlayerGUID()
    if pg and pg == guid then
        return "player"
    end

    if UnitExists and UnitExists("target") then
        local tg = _GetUnitGuidSafe("target")
        if tg and tg == guid then
            return "target"
        end
    end

    return nil
end

local function _UnitExistsFlag(unit)
    if not UnitExists then return false end
    local e = UnitExists(unit)
    return (e == 1 or e == true)
end

-- Player click-off detection (CancelPlayerBuff hook)
local _clickOffAt     = nil
local _clickOffTex    = nil
local _clickOffAuraId = nil

local function _NormTexturePath(tex)
    if not tex or tex == "" then return nil end
    tex = string.gsub(tex, "/", "\\")
    tex = string.lower(tex)
    return tex
end

local function _GetSpellTextureNorm(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return nil end

    local cache = _G["DoiteTrack_SpellTextureCache"]
    if not cache then
        cache = {}
        _G["DoiteTrack_SpellTextureCache"] = cache
    end

    local v = cache[spellId]
    if v ~= nil then
        if v == false then return nil end
        return v
    end

    local tex = nil

    if SpellInfo then
        local ok, n, r, t = pcall(SpellInfo, spellId)
        if ok and type(t) == "string" and t ~= "" then
            tex = t
        end
    end

    tex = _NormTexturePath(tex)
    cache[spellId] = tex or false
    return tex
end

_HookCancelPlayerBuff = function()
    if _G["DoiteTrack_CPBHooked"] then
        return
    end

    -- hook the GLOBAL function that the UI actually calls
    local c = _G.CancelPlayerBuff
    if not c or type(c) ~= "function" then
        return
    end

    _G["DoiteTrack_CPBHooked"] = true

    local orig = c

    _G.CancelPlayerBuff = function(i)
        local tex, _, auraId = nil, nil, nil
        if UnitBuff then
            tex, _, auraId = UnitBuff("player", i)
        end

        _clickOffAt     = (GetTime and GetTime() or 0)
        _clickOffTex    = _NormTexturePath(tex)
        _clickOffAuraId = tonumber(auraId) or nil

        return orig(i)
    end
end

---------------------------------------------------------------
-- DBC correction layer (talents/gear) - runtime flags + signature
---------------------------------------------------------------
local _debugCorrections = false
local _correctionSeenThisSession = {}
local _lastProfileSig = nil

local function _CorrectionKey(spellId, cp, baseRounded)
    return tostring(tonumber(spellId) or 0) .. ":" .. tostring(tonumber(cp) or 0) .. ":" .. tostring(tonumber(baseRounded) or 0)
end

local function _DebugCorrection(msg)
    if _debugCorrections then
        _Print("|cff6FA8DCDoiteAuras:|r (corr) " .. (msg or ""))
    end
end

_G["DoiteTrack_SetCorrectionDebug"] = function(on)
    _debugCorrections = (on and true or false)
    if _debugCorrections then
        _Print("|cff6FA8DCDoiteAuras:|r correction debug |cffffff00ON|r")
    else
        _Print("|cff6FA8DCDoiteAuras:|r correction debug |cffffff00OFF|r")
    end
end

local function _GetProfileSignature()
    local parts = {}

    -- Gear signature (slot itemIDs)
    local GetInventoryItemLink = _G.GetInventoryItemLink
    if GetInventoryItemLink then
        local slot
        for slot = 1, 19 do
            local link = GetInventoryItemLink("player", slot)
            local id = "0"
			if link and type(link) == "string" then
				local _, _, m = string.find(link, "item:(%d+)")
				if m and m ~= "" then id = m end
			end
            parts[table.getn(parts) + 1] = id
        end
    else
        parts[table.getn(parts) + 1] = "nogearapi"
    end

    parts[table.getn(parts) + 1] = "|"

    -- Talent signature (all ranks)
    local GetNumTalentTabs = _G.GetNumTalentTabs
    local GetNumTalents    = _G.GetNumTalents
    local GetTalentInfo    = _G.GetTalentInfo

    if GetNumTalentTabs and GetNumTalents and GetTalentInfo then
        local tabs = 0
        local okTabs, vTabs = pcall(GetNumTalentTabs)
        if okTabs and type(vTabs) == "number" then
            tabs = vTabs
        end

        local tab
        for tab = 1, tabs do
            local num = 0
            local okNum, vNum = pcall(GetNumTalents, tab)
            if okNum and type(vNum) == "number" then
                num = vNum
            end

            local t
            for t = 1, num do
                local okInfo, n, ico, tier, col, curRank = pcall(GetTalentInfo, tab, t)
                local r = 0
                if okInfo and type(curRank) == "number" then
                    r = curRank
                end
                parts[table.getn(parts) + 1] = tostring(r)
            end
            parts[table.getn(parts) + 1] = "|"
        end
    else
        parts[table.getn(parts) + 1] = "notalentsapi"
    end

    return table.concat(parts, ",")
end

local function _ResetCorrectionsForNewProfile(db, reason)
    -- Keep corrected overrides; they remain in effect until re-tested.
    db.correctedChecked     = {}
    db.correctedCheckedCP   = {}

    for k in pairs(_correctionSeenThisSession) do
        _correctionSeenThisSession[k] = nil
    end

    _DebugCorrection("profile changed ("..tostring(reason)..") -> kept corrected durations; cleared checked & session cache")
end

local function _ArmCorrections(reason)
    -- Once per entering world and again after gear/talent changes
    for k in pairs(_correctionSeenThisSession) do
        _correctionSeenThisSession[k] = nil
    end
    _lastProfileSig = tostring(reason or "unknown") .. "@" .. tostring(GetTime and GetTime() or 0)
    _DebugCorrection("armed correction checks ("..tostring(reason)..")")
end

function DoiteTrack:_OnProfileMaybeChanged(reason)
    local db = _GetDB()
    local sig = _GetProfileSignature()
    if not sig or sig == "" then
        _ArmCorrections(reason or "unknown")
        return
    end

    local prev = db.correctedProfileSig
    if prev ~= sig then
        db.correctedProfileSig = sig
        _ResetCorrectionsForNewProfile(db, reason or "unknown")
    else
        _DebugCorrection("profile unchanged ("..tostring(reason)..")")
    end

    _ArmCorrections(reason or "unknown")
end

local ProfileFrame = CreateFrame("Frame", "DoiteTrackProfileFrame")
local _profileRescanAt = nil
local _profileRescanReason = nil

local function _ScheduleProfileRescan(reason)
    local now = GetTime and GetTime() or 0
    _profileRescanReason = reason or "spellbook_change"
    _profileRescanAt = now + 0.35

    if ProfileFrame._active then
        return
    end

    ProfileFrame._active = true
    ProfileFrame:SetScript("OnUpdate", function()
        local t = GetTime and GetTime() or 0
        if _profileRescanAt and t >= _profileRescanAt then
            ProfileFrame._active = false
            ProfileFrame:SetScript("OnUpdate", nil)

            local r = _profileRescanReason
            _profileRescanAt = nil
            _profileRescanReason = nil

            DoiteTrack:_OnProfileMaybeChanged(r)
        end
    end)
end

---------------------------------------------------------------
-- SpellDuration.dbc: id -> duration (seconds)
---------------------------------------------------------------
local SpellDurationSec = {
    [1] = 10,
    [2] = 30,
    [3] = 60,
    [4] = 120,
    [5] = 300,
    [6] = 600,
    [7] = 5,
    [8] = 15,
    [9] = 30,
    [10] = 60,
    [11] = 10,
    [12] = 30,
    [13] = 60,
    [14] = 120,
    [15] = 300,
    [16] = 230,
    [17] = 5,
    [18] = 20,
    [19] = 30,
    [20] = 60,
    -- 21 has -1 -> infinite, intentionally ignored
    [22] = 45,
    [23] = 90,
    [24] = 160,
    [25] = 180,
    [26] = 240,
    [27] = 3,
    [28] = 5,
    [29] = 12,
    [30] = 1800,
    [31] = 8,
    [32] = 6,
    [35] = 4,
    [36] = 1,
    [37] = 0.001,
    [38] = 11,
    [39] = 2,
    [40] = 1200,
    [41] = 360,
    [42] = 3600,
    [62] = 75,
    [63] = 25,
    [64] = 40,
    [65] = 1.5,
    [66] = 2.5,
    [85] = 18,
    [86] = 21,
	-- 87 Rip / Druid / SpellDurationSecCP
    [105] = 9,
    [106] = 24,
    [125] = 35,
    [145] = 2700,
    [165] = 7,
    [185] = 6,
    [186] = 2,
    -- 187 has 0 duration, intentionally ignored
    [205] = 27,
    [225] = 604800,
    [245] = 50,
    [265] = 55,
    [285] = 1,
    [305] = 14,
    [325] = 36,
    [326] = 44,
    [327] = 0.5,
    [328] = 0.25,
    [347] = 900,
    [367] = 7200,
    [387] = 16,
    [407] = 0.1,
    -- 427 has negative duration / scaling, intentionally ignored
    [447] = 2,
    [467] = 22,
    [468] = 26,
    [487] = 1.7,
    [507] = 1.1,
    [508] = 1.1,
    [527] = 14400,
    [547] = 5400,
    [548] = 10800,
    [549] = 3.8,
    [552] = 210,
    [553] = 6,
}

-- CP-specific overrides keyed by durationIndex
local SpellDurationSecCP = {
    [87] = { -- Rip (Rank 6)/(9896)
        [1] = 10,
        [2] = 12,
        [3] = 14,
        [4] = 16,
        [5] = 18,
    },
}

---------------------------------------------------------------
-- DBC duration helper (durationIndex -> SpellDurationSec / SpellDurationSecCP)
---------------------------------------------------------------
local function _GetDBCBaseDuration(spellId, cp)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return nil
    end
    if not GetSpellRecField then
        return nil
    end

    -- durationIndex field confirmed working via /run probe
    local ok, idx = pcall(GetSpellRecField, spellId, "durationIndex")
    if not ok or type(idx) ~= "number" or idx <= 0 then
        return nil
    end

    -- 1) CP-specific override table, if present
    if cp and cp > 0 then
        local cpMap = SpellDurationSecCP[idx]
        if cpMap then
            local secCP = cpMap[cp]
            if type(secCP) == "number" and secCP > 0 then
                return secCP
            end
        end
    end

    -- 2) Flat numeric duration for this durationIndex
    local sec = SpellDurationSec[idx]
    if type(sec) == "number" and sec > 0 then
        return sec
    end

    return nil
end

---------------------------------------------------------------
-- Combo-point duration helper (using Nampower DBC)
---------------------------------------------------------------
local CPDurationCache = {}  -- [spellId] = true/false

local function _SpellUsesComboDuration(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return false
    end

    -- Cache hit?
    local cached = CPDurationCache[spellId]
    if cached ~= nil then
        return cached
    end

    local uses = false

    if GetSpellRecField then
        local ok, arr = pcall(GetSpellRecField, spellId, "effectPointsPerComboPoint", 1)
        if (not ok) or type(arr) ~= "table" then
            ok, arr = pcall(GetSpellRecField, spellId, "effectPointsPerComboPoint")
        end

        if ok and type(arr) == "table" then
            for i = 1, table.getn(arr) do
                local v = arr[i]
                if type(v) == "number" and v ~= 0 then
                    uses = true
                    break
                end
            end
        end
    end

    CPDurationCache[spellId] = uses and true or false
    return uses
end

---------------------------------------------------------------
-- Core DB access helpers
---------------------------------------------------------------
local function _GetTrackedFlatDuration(spellId)
    local db = _GetDB()
    return db.trackedDurations[spellId]
end

local function _GetTrackedCPDuration(spellId, cp)
    if not cp or cp <= 0 then return nil end
    local db = _GetDB()
    local t = db.trackedDurationsCP[spellId]
    if not t then return nil end
    return t[cp]
end

-- corrected-duration override (talents/gear)
local function _GetCorrectedFlatDuration(spellId)
    local db = _GetDB()
    return db.correctedDurations[spellId]
end

local function _GetCorrectedCPDuration(spellId, cp)
    if not cp or cp <= 0 then return nil end
    local db = _GetDB()
    local t = db.correctedDurationsCP[spellId]
    if not t then return nil end
    return t[cp]
end

-- Baseline duration lookup in priority order:
--  0) Corrected override (talents/gear) if present
--  1) DBC duration via SpellDuration.dbc (durationIndex -> SpellDurationSec)
--  2) CP-specific tracked duration (if cp > 0)
--  3) Flat tracked duration (no CP)
local function _GetBaselineDuration(spellId, cp)
    local d

    -- 0) Corrected override (if known)
    if cp and cp > 0 then
        d = _GetCorrectedCPDuration(spellId, cp)
        if d and d > 0 then
            return d
        end
    end
    d = _GetCorrectedFlatDuration(spellId)
    if d and d > 0 then
        return d
    end

    -- 1) Static DBC duration (optionally CP-specific), if available
    d = _GetDBCBaseDuration(spellId, cp)
    if d and d > 0 then
        return d
    end

    -- 2) CP-specific tracked duration
    if cp and cp > 0 then
        d = _GetTrackedCPDuration(spellId, cp)
        if d and d > 0 then
            return d
        end
    end

    -- 3) Flat tracked duration
    d = _GetTrackedFlatDuration(spellId)
    if d and d > 0 then
        return d
    end

    return nil
end

local function _ShouldRecord(spellId, cp)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return false
    end

    -- If SpellDurationSec / SpellDurationSecCP already knows this spell's duration, do NOT record again.
    local dbc = _GetDBCBaseDuration(spellId, cp)
    if dbc and dbc > 0 then
        return false
    end

    -- Otherwise fall back to the dynamic tracking rules:
    --  1) CP-specific measurement if cp > 0 and missing
    --  2) Flat measurement if no CP data and flat missing
    if cp and cp > 0 then
        local exist = _GetTrackedCPDuration(spellId, cp)
        if exist and exist > 0 then
            return false
        end
        return true
    end

    local flat = _GetTrackedFlatDuration(spellId)
    if flat and flat > 0 then
        return false
    end

    return true
end

local function _CommitDuration(spellId, spellName, spellRank, cp, measuredSec)
    if not spellId or spellId <= 0 then return end
    if not measuredSec or measuredSec <= 0 then return end

    local db  = _GetDB()
    local sec = math.floor(measuredSec + 0.5)

    if cp and cp > 0 then
        db.trackedDurationsCP[spellId] = db.trackedDurationsCP[spellId] or {}
        if not db.trackedDurationsCP[spellId][cp] then
            db.trackedDurationsCP[spellId][cp] = sec
        end
    else
        if not db.trackedDurations[spellId] then
            db.trackedDurations[spellId] = sec
        end
    end

    local meta = db.trackedDurationsMeta[spellId]
    if not meta then
        meta = { name = spellName, rank = spellRank, samples = 0 }
        db.trackedDurationsMeta[spellId] = meta
    end
    meta.samples = (meta.samples or 0) + 1

    if spellName and spellName ~= "" then
        meta.name = spellName
    end
    if spellRank and spellRank ~= "" then
        meta.rank = spellRank
    end
end

---------------------------------------------------------------
-- Normalise names so match by "Rend" across ranks
---------------------------------------------------------------
local function _NormSpellName(name)
    if not name or name == "" then return nil end

    -- trim
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    name = string.lower(name)

    -- strip " (Rank X)" and " Rank X"
    name = string.gsub(name, "%s*%(rank%s*%d+%)", "")
    name = string.gsub(name, "%s*rank%s*%d+", "")

    -- trim again (after gsubs)
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    return name
end

---------------------------------------------------------------
-- Scan DoiteAuras config for which buffs/debuffs should be tracked
---------------------------------------------------------------
local function _AddTrackedFromEntry(key, data)
    if not data or type(data) ~= "table" then return end

    -- Must be buff/debuff
    if data.type ~= "Buff" and data.type ~= "Debuff" then
        return
    end

    local c = data.conditions and data.conditions.aura
    if not c then
        return
    end

    -- Only track explicit "only mine" auras, and only if they target something
    -- Only track explicit ownership-based auras, and only if they target something
    local onlyMine   = (c.onlyMine == true)
    local onlyOthers = (c.onlyOthers == true)
    local hasTarget  = (c.targetSelf or c.targetHelp or c.targetHarm)

    if not hasTarget then
        return
    end


    if (not onlyMine) and (not onlyOthers) then
        return
    end

    -- Get spellId if present
    local sid = data.spellid and tonumber(data.spellid)
    if sid and sid <= 0 then
        sid = nil
    end

    local name = data.displayName or data.name or ""
    local norm = _NormSpellName(name)

    if not sid and not norm then
        return
    end

    -- Reuse existing entry if already have it by spellId or name
    local entry
    if sid then
        entry = TrackedBySpellId[sid]
    end
    if not entry and norm then
        entry = TrackedByNameNorm[norm]
    end

    if not entry then
        entry = {
            spellIds   = {},
            name       = name,
            normName   = norm,
            kind       = data.type, -- "Buff" / "Debuff"
            trackSelf  = false,
            trackHelp  = false,
            trackHarm  = false,
            onlyMine    = onlyMine,
            onlyOthers  = onlyOthers,
        }
    else
        -- Preserve ownership flags if any entry requested them
        if entry.onlyMine ~= true and onlyMine then
            entry.onlyMine = true
        end
        if entry.onlyOthers ~= true and onlyOthers then
            entry.onlyOthers = true
        end
    end

    if sid then
        entry.spellIds[sid] = true
        TrackedBySpellId[sid] = entry
    end
    if norm then
        TrackedByNameNorm[norm] = entry
    end

    if c.targetSelf then entry.trackSelf = true end
    if c.targetHelp then entry.trackHelp = true end
    if c.targetHarm then entry.trackHarm = true end
end

-- Does this table look like a spells table (entries with type + conditions.aura)?
local function _LooksLikeSpellConfigTable(tbl)
    if type(tbl) ~= "table" then return false end
    local seen = 0
    for _, v in pairs(tbl) do
        if type(v) == "table" then
            if v.type and v.conditions and v.conditions.aura then
                return true
            end
            seen = seen + 1
            if seen > 20 then break end
        end
    end
    return false
end

-- Walk DoiteAurasDB / DoiteDB to discover where spells actually live.
local function _DiscoverSpellTable()
    local visited = {}

    local function scan(tbl, path)
        if type(tbl) ~= "table" or visited[tbl] then return nil, nil end
        visited[tbl] = true

        if type(tbl.spells) == "table" and _LooksLikeSpellConfigTable(tbl.spells) then
            return tbl.spells, path..".spells"
        end

        for k, v in pairs(tbl) do
            if type(v) == "table" then
                local found, foundPath = scan(v, path.."."..tostring(k))
                if found then return found, foundPath end
            end
        end

        return nil, nil
    end

    local db = _G["DoiteAurasDB"]
    if db then
        local found, path = scan(db, "DoiteAurasDB")
        if found then return found, path end
    end

    if _G["DoiteDB"] then
        local found, path = scan(_G["DoiteDB"], "DoiteDB")
        if found then return found, path end
    end

    return nil, nil
end

function DoiteTrack:RebuildWatchList()
    -- Clear previous maps
    local k
    for k in pairs(TrackedBySpellId) do
        TrackedBySpellId[k] = nil
    end
    for k in pairs(TrackedByNameNorm) do
        TrackedByNameNorm[k] = nil
    end

    local spells = _DiscoverSpellTable()
    if not spells then
        return
    end

    for key, data in pairs(spells) do
        _AddTrackedFromEntry(key, data)
    end
end

_G["DoiteTrack_RebuildWatchList"] = function()
    DoiteTrack:RebuildWatchList()
end

local _lastWatchListRebuild = 0

local function _MaybeRebuildWatchListForSpell(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return nil
    end

    local now = GetTime and GetTime() or 0

    if (now - _lastWatchListRebuild) < 1.0 then
        return nil
    end
    _lastWatchListRebuild = now

    DoiteTrack:RebuildWatchList()
    return TrackedBySpellId[spellId]
end

---------------------------------------------------------------
-- Active aura tracking / sessions
---------------------------------------------------------------
local ActiveSessions  = {}
local SessionCounter  = 0
local AuraStateByGuid = {}

local function _GetAuraBucketForGuid(guid, create)
    if not guid or guid == "" then return nil end
    local t = AuraStateByGuid[guid]
    if not t and create then
        t = {}
        AuraStateByGuid[guid] = t
    end
    return t
end

local function _ClearAuraForSession(session)
    if not session or not session.targetGuid or not session.spellId then return end
    local bucket = AuraStateByGuid[session.targetGuid]
    if bucket then
        bucket[session.spellId] = nil
    end
end

local function _RecordAuraForSession(session)
    if not session or not session.targetGuid or not session.spellId then return end
    local bucket = _GetAuraBucketForGuid(session.targetGuid, true)
    if not bucket then return end

    local sid = session.spellId
    local a = bucket[sid]
    if not a then
        a = {}
        bucket[sid] = a
    end

    local applied = session.appliedAt or session.startedAt
    local seen    = session.lastSeen or session.appliedAt or session.startedAt

    a.appliedAt = applied
    a.lastSeen  = seen
    a.cp        = session.cp or 0
    a.isDebuff  = (session.isDebuff == true)

    -- Cache baseline duration - don't re-query DB/DBC every tick
    local dur = session.fullDur
    if not dur or dur <= 0 then
        dur = a.fullDur
    end
    if not dur or dur <= 0 then
        dur = _GetBaselineDuration(sid, a.cp)
        session.fullDur = dur
    end
    a.fullDur = dur
end

-- Find any active session for (spellId, targetGuid)
local function _FindSessionFor(spellId, targetGuid)
    if not spellId or not targetGuid then return nil end
    local id, s
    for id, s in pairs(ActiveSessions) do
        if s.spellId == spellId and s.targetGuid == targetGuid and not s.aborted and not s.complete then
            return id, s
        end
    end
    return nil, nil
end

local _NotifyCorrectionApplied
local _NotifyCorrectionCleared

local function _AbortSession(session, reason)
    if not session or session.aborted or session.complete then return end
    session.aborted      = true
    session.abortReason  = reason or "unknown"
    _ClearAuraForSession(session)

    -- do not keep dead sessions around
    if session.id then
        ActiveSessions[session.id] = nil
    end
end

local function _FinishSession(session, finalDuration)
    if not session or session.aborted or session.complete then return end
    if not finalDuration or finalDuration <= 0 then
        return
    end

    ----------------------------------------------------------------
    -- Special handling for damage-origin auras like Deep Wounds
    ----------------------------------------------------------------
    if session.source == "damage" and session.spellName then
        local norm = _NormSpellName(session.spellName)
        if norm == "deep wounds" then
            local rounded = math.floor(finalDuration + 0.5)
            if rounded > 7 then
                finalDuration = 6
            else
                finalDuration = rounded
            end
        end
    end

    session.complete      = true
    session.finalDuration = finalDuration

    ----------------------------------------------------------------
    -- correction-mode commit (overrides DBC if different)
    ----------------------------------------------------------------
    if session.correctMode then
        local db = _GetDB()
        local spellId = session.spellId
        local cp = session.cp or 0

        local measuredRounded = math.floor(finalDuration + 0.5)

        local baseKind = session.correctBaseKind
        local baseRounded = session.correctBaseRounded

        -- Fallback (in case older session structs exist)
        if not baseKind then baseKind = "dbc" end
        if not baseRounded or baseRounded <= 0 then
            if baseKind == "dbc" or baseKind == "corr" then
                local baseDBC = _GetDBCBaseDuration(spellId, cp)
                baseRounded = baseDBC and math.floor(baseDBC + 0.5) or nil
            else
                local t = nil
                if cp > 0 then t = _GetTrackedCPDuration(spellId, cp) end
                if not t then t = _GetTrackedFlatDuration(spellId) end
                baseRounded = t and math.floor(t + 0.5) or nil
            end
        end

        -- Track "seen" - don't spam within the same armed window (per baselineRounded)
        local key = _CorrectionKey(spellId, cp, baseRounded or 0)
        _correctionSeenThisSession[key] = true

        if baseRounded and baseRounded > 0 then

            -- If DBC exists for this spell, correction logic is "DBC correction" regardless of whether started from DBC or from an existing correction value.
            local baseDBC = _GetDBCBaseDuration(spellId, cp)
            local dbcRounded = (baseDBC and baseDBC > 0) and math.floor(baseDBC + 0.5) or nil

            if dbcRounded and dbcRounded > 0 then
                -- mark checked for this profile
                if cp > 0 then
                    db.correctedCheckedCP[spellId] = db.correctedCheckedCP[spellId] or {}
                    db.correctedCheckedCP[spellId][cp] = true
                else
                    db.correctedChecked[spellId] = true
                end

                -- Ensure this spell can be cleared by name later
                db.trackedDurationsMeta[spellId] = db.trackedDurationsMeta[spellId] or {}
                if session.correctDisplayName and session.correctDisplayName ~= "" then
                    db.trackedDurationsMeta[spellId].name = session.correctDisplayName
                elseif session.spellName and session.spellName ~= "" then
                    db.trackedDurationsMeta[spellId].name = session.spellName
                end
                if session.spellRank and session.spellRank ~= "" then
                    db.trackedDurationsMeta[spellId].rank = session.spellRank
                end

                -- Current saved correction (if any)
                local corrNow = nil
                if cp > 0 then
                    corrNow = db.correctedDurationsCP[spellId] and db.correctedDurationsCP[spellId][cp]
                else
                    corrNow = db.correctedDurations[spellId]
                end

                local function _ClearCorr()
                    if cp > 0 and db.correctedDurationsCP[spellId] then
                        db.correctedDurationsCP[spellId][cp] = nil
                        if not next(db.correctedDurationsCP[spellId]) then
                            db.correctedDurationsCP[spellId] = nil
                        end
                    else
                        db.correctedDurations[spellId] = nil
                    end
                end

                -- If a stale correction equals DBC, silently drop it (no player-facing change).
                if corrNow and corrNow == dbcRounded then
                    _ClearCorr()
                    corrNow = nil
                end

                -- 1) already had a correction and the measured matches it: do NOTHING (no writes, no chat).
                if corrNow and measuredRounded == corrNow then
                    -- silent

                else
                    -- 2) If measured matches DBC: remove correction if it existed (notify only on actual reset)
                    if measuredRounded == dbcRounded then
                        if corrNow then
                            _ClearCorr()
                            if session.correctDisplayName or session.spellName then
                                _NotifyCorrectionCleared(session.kind, session.correctDisplayName or session.spellName, measuredRounded, dbcRounded)
                            end
                        end

                    -- 3) Otherwise: save/overwrite correction (notify only when value actually changes)
                    else
                        if cp > 0 then
                            db.correctedDurationsCP[spellId] = db.correctedDurationsCP[spellId] or {}
                            db.correctedDurationsCP[spellId][cp] = measuredRounded
                        else
                            db.correctedDurations[spellId] = measuredRounded
                        end

                        if session.correctDisplayName or session.spellName then
                            _NotifyCorrectionApplied(session.kind, session.correctDisplayName or session.spellName, measuredRounded, dbcRounded)
                        end
                    end
                end

            else
                -- -------------------------
                -- Recheck learned (non-DBC) durations after profile changes
                -- -------------------------
                if measuredRounded ~= baseRounded then
                    if cp > 0 then
                        db.trackedDurationsCP[spellId] = db.trackedDurationsCP[spellId] or {}
                        db.trackedDurationsCP[spellId][cp] = measuredRounded
                    else
                        db.trackedDurations[spellId] = measuredRounded
                    end

                    _Print(string.format(
                        "|cff6FA8DCDoiteAuras:|r |cffffff00%s|r updated learned duration: |cffffff00%ds|r (was %ds).",
                        tostring(session.correctDisplayName or session.spellName or ("Spell "..tostring(spellId))),
                        measuredRounded,
                        baseRounded
                    ))
                else
                    _DebugCorrection(string.format(
                        "learned OK id=%d cp=%d stored=%d measured=%d",
                        spellId, cp, baseRounded, measuredRounded
                    ))
                end
            end

        else
            _DebugCorrection("skip correction: no base duration for id="..tostring(spellId).." cp="..tostring(cp))
        end

        _RecordAuraForSession(session)

        -- finished sessions shouldn't stay in ActiveSessions
        if session.id then
            ActiveSessions[session.id] = nil
        end
        return
    end

    ----------------------------------------------------------------
    -- Normal completion & commit (existing behavior)
    ----------------------------------------------------------------
    if session.willRecord then
        _CommitDuration(
            session.spellId,
            session.spellName,
            session.spellRank,
            session.cp,
            finalDuration
        )
    end

    _RecordAuraForSession(session)

    -- finished sessions shouldn't stay in ActiveSessions
    if session.id then
        ActiveSessions[session.id] = nil
    end
end

---------------------------------------------------------------
-- Clear helpers (global, per-spell, per-name)
---------------------------------------------------------------
local function _ClearAllTrackedDurations()
    local db = _GetDB()

    -- Wipe persisted measurements
    db.trackedDurations     = {}
    db.trackedDurationsCP   = {}
    db.trackedDurationsMeta = {}

    -- Wipe corrected overrides
    db.correctedDurations   = {}
    db.correctedDurationsCP = {}
    db.correctedChecked     = {}
    db.correctedCheckedCP   = {}

    -- Wipe runtime state so nothing uses old data
    local k
    for k in pairs(AuraStateByGuid) do
        AuraStateByGuid[k] = nil
    end
    for k in pairs(ActiveSessions) do
        ActiveSessions[k] = nil
    end
    SessionCounter = 0

    _Print("|cff6FA8DCDoiteAuras:|r cleared all learned aura durations.")
end

local function _ClearTimersForSpellId(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        _Print("|cff6FA8DCDoiteAuras:|r bad spellId "..tostring(spellId).." for clear.")
        return
    end

    local db = _GetDB()
    local removedIds = 0

    if db.trackedDurations[spellId] then
        db.trackedDurations[spellId] = nil
        removedIds = removedIds + 1
    end
    if db.trackedDurationsCP[spellId] then
        db.trackedDurationsCP[spellId] = nil
        removedIds = removedIds + 1
    end
    if db.trackedDurationsMeta[spellId] then
        db.trackedDurationsMeta[spellId] = nil
        removedIds = removedIds + 1
    end
	    if db.correctedDurations[spellId] then
        db.correctedDurations[spellId] = nil
        removedIds = removedIds + 1
    end
    if db.correctedDurationsCP[spellId] then
        db.correctedDurationsCP[spellId] = nil
        removedIds = removedIds + 1
    end
    if db.correctedChecked[spellId] then
        db.correctedChecked[spellId] = nil
    end
    if db.correctedCheckedCP[spellId] then
        db.correctedCheckedCP[spellId] = nil
    end

    -- Wipe runtime state only for this spellId
    local guid, bucket
    for guid, bucket in pairs(AuraStateByGuid) do
        if bucket[spellId] then
            bucket[spellId] = nil
        end
    end
    local id, s
    for id, s in pairs(ActiveSessions) do
        if s.spellId == spellId then
            ActiveSessions[id] = nil
        end
    end

    if removedIds > 0 then
        _Print("|cff6FA8DCDoiteAuras:|r cleared timers for spellId "..spellId..".")
    else
        _Print("|cff6FA8DCDoiteAuras:|r no timers found for spellId "..spellId..".")
    end
end

local function _ClearTimersForName(normName)
    if not normName or normName == "" then
        _Print("|cff6FA8DCDoiteAuras:|r empty name for clear.")
        return
    end

    local db = _GetDB()
    local clearedIds = {}
    local spellId, meta

    for spellId, meta in pairs(db.trackedDurationsMeta) do
        local mname = meta and meta.name
        local mNorm = _NormSpellName(mname)
        if mNorm and mNorm == normName then
            db.trackedDurations[spellId]      = nil
            db.trackedDurationsCP[spellId]    = nil
            db.trackedDurationsMeta[spellId]  = nil

            db.correctedDurations[spellId]    = nil
            db.correctedDurationsCP[spellId]  = nil
            db.correctedChecked[spellId]      = nil
            db.correctedCheckedCP[spellId]    = nil

            clearedIds[spellId] = true
        end
    end

    if not next(clearedIds) then
        _Print("|cff6FA8DCDoiteAuras:|r no timers matched '"..normName.."'.")
        return
    end

    -- Runtime state for all affected spellIds
    local guid, bucket
    for guid, bucket in pairs(AuraStateByGuid) do
        local sid
        for sid in pairs(clearedIds) do
            if bucket[sid] then
                bucket[sid] = nil
            end
        end
    end
    local id, s
    for id, s in pairs(ActiveSessions) do
        if clearedIds[s.spellId] then
            ActiveSessions[id] = nil
        end
    end

    local count = 0
    local sid
    for sid in pairs(clearedIds) do
        count = count + 1
    end

    _Print("|cff6FA8DCDoiteAuras:|r cleared timers for "..normName.." ("..count.." spellId"..(count ~= 1 and "s" or "")..").")
end

_G["DoiteTrack_ClearTimers"] = function(arg)
    -- No argument: nuke everything (old behaviour).
    if not arg or arg == "" then
        _ClearAllTrackedDurations()
        return
    end

    -- Trim spaces
    arg = string.gsub(arg, "^%s+", "")
    arg = string.gsub(arg, "%s+$", "")
    if arg == "" then
        _ClearAllTrackedDurations()
        return
    end

    -- Numeric -> spellId
    local sid = tonumber(arg)
    if sid and sid > 0 then
        _ClearTimersForSpellId(sid)
        return
    end

    -- String -> normalised name, clear all ranks/ids with that meta.name
    local norm = _NormSpellName(arg)
    if not norm then
        _Print("|cff6FA8DCDoiteAuras:|r could not parse name/spellId '"..tostring(arg).."'.")
        return
    end

    _ClearTimersForName(norm)
end

---------------------------------------------------------------
-- Aura presence queries (using SuperWoW's auraId table)
---------------------------------------------------------------
local function _GetUnitAuraTable(unit, isDebuff)
    if not GetUnitField then return nil end

    local function getFieldTable(fieldName)

        local cache = _G["DoiteTrack_AuraFieldCache"]
        if not cache then
            cache = {}
            _G["DoiteTrack_AuraFieldCache"] = cache
        end

        local gt = _G.GetTime
        local now = 0
        if gt then
            now = gt()
        end

        -- 0.1s tick id
        local tick = math.floor(now * 10)
        if cache._tick ~= tick then
            cache._tick = tick
            cache._gen = (cache._gen or 0) + 1
        end
        local gen = cache._gen or 0

        local u = cache[unit]
        if type(u) ~= "table" then
            u = {}
            cache[unit] = u
        end

        local f = u[fieldName]
        if type(f) ~= "table" then
            f = {}
            u[fieldName] = f
        end

        -- 1) Try copy=1 (cached)
        if f._g1 == gen then
            local v = f._v1
            if v == false then return nil end
            return v
        end

        local ok, t = pcall(GetUnitField, unit, fieldName, 1)
        if ok and type(t) == "table" then
            f._g1 = gen
            f._v1 = t
            return t
        end

        f._g1 = gen
        f._v1 = false

        -- 2) Fallback: no-copy (cached)
        if f._g0 == gen then
            local v2 = f._v0
            if v2 == false then return nil end
            return v2
        end

        ok, t = pcall(GetUnitField, unit, fieldName)
        if ok and type(t) == "table" then
            f._g0 = gen
            f._v0 = t
            return t
        end

        f._g0 = gen
        f._v0 = false
        return nil
    end

    local t

    if isDebuff then
        t = getFieldTable("debuff")
        if t then return t end
        t = getFieldTable("aura")
        if t then return t end
        -- last resort
        t = getFieldTable("buff")
        if t then return t end
    else
        t = getFieldTable("buff")
        if t then return t end
        t = getFieldTable("aura")
        if t then return t end
        -- last resort
        t = getFieldTable("debuff")
        if t then return t end
    end

    return nil
end

-- Discover and cache spellIds for an entry by scanning the unit’s aura spellIds, resolving spell name from spellId, and matching normalized name.
local function _CacheMatchingAuraIdsOnUnit(entry, unit)
    if not entry or not entry.normName or not unit then
        return nil
    end

    local auras = _GetUnitAuraTable(unit, entry.kind == "Debuff")
    if type(auras) ~= "table" then
        return nil
    end

    local foundSid = nil

    -- Global spellId->normalized-name cache
    local normCache = _G["DoiteTrack_SpellNormCache"]
    if not normCache then
        normCache = {}
        _G["DoiteTrack_SpellNormCache"] = normCache
    end

    local function considerSpellId(raw)
        local sid = tonumber(raw) or 0
        if sid <= 0 then return end

        -- If already known for this entry, just ensure first-found and exit.
        if entry.spellIds and entry.spellIds[sid] then
            TrackedBySpellId[sid] = entry
            if not foundSid then foundSid = sid end
            return
        end

        local norm = normCache[sid]

        -- Cache miss: resolve name -> normalize -> store (store false for "unknown")
        if norm == nil then
            local n = nil

            if GetSpellNameAndRankForId then
                local ok, nn = pcall(GetSpellNameAndRankForId, sid)
                if ok and nn and nn ~= "" then
                    n = nn
                end
            end

            if (not n or n == "") and SpellInfo then
                local nn = SpellInfo(sid)
                if type(nn) == "string" and nn ~= "" then
                    n = nn
                end
            end

            norm = _NormSpellName(n)
            if not norm or norm == "" then
                norm = false
            end

            normCache[sid] = norm
        end

        if norm and norm == entry.normName then
            entry.spellIds = entry.spellIds or {}
            entry.spellIds[sid] = true
            TrackedBySpellId[sid] = entry
            if not foundSid then
                foundSid = sid
            end
        end
    end

    -- Array-style
    local n = table.getn(auras)
    if n and n > 0 then
        local i
        for i = 1, n do
            considerSpellId(auras[i])
        end
    end

    -- Hash/other-style
    local k, v
    for k, v in pairs(auras) do
        considerSpellId(k)
        considerSpellId(v)
    end

    return foundSid
end

-- Based on probe D: GetUnitField("target","aura") returns a table of spellIds.
local function _AuraHasSpellId(unit, spellId, isDebuff)
    spellId = tonumber(spellId) or 0
    if not unit or spellId <= 0 then
        return false
    end

    local auras = _GetUnitAuraTable(unit, isDebuff)
    if type(auras) ~= "table" then
        return false
    end

    -- Fast hash hit
    if auras[spellId] then
        return true
    end

    local cache = _G["DoiteTrack_AuraHasCache"]
    if not cache then
        cache = {}
        _G["DoiteTrack_AuraHasCache"] = cache
    end

    -- Use the same tick/gen cadence as the aura-field cache if present, otherwise maintain our own tick/gen.
    local gen = nil
    local fieldCache = _G["DoiteTrack_AuraFieldCache"]
    if fieldCache and fieldCache._gen then
        gen = fieldCache._gen
    else
        local gt = _G.GetTime
        local now = 0
        if gt then now = gt() end

        local tick = math.floor(now * 10)
        if cache._tick ~= tick then
            cache._tick = tick
            cache._gen = (cache._gen or 0) + 1
        end
        gen = cache._gen or 0
    end

    local u = cache[unit]
    if type(u) ~= "table" then
        u = {}
        cache[unit] = u
    end

    local key = isDebuff and "D" or "B"

    local slot = u[key]
    if type(slot) ~= "table" then
        slot = {}
        u[key] = slot
    end

    local map = slot._map
    if type(map) ~= "table" then
        map = {}
        slot._map = map
    end

    -- Rebuild once per gen
    if slot._g ~= gen then
        slot._g = gen

        local n = table.getn(auras)
        if n and n > 0 then
            local i
            for i = 1, n do
                local v = tonumber(auras[i])
                if v and v > 0 then
                    map[v] = gen
                end
            end
        end

        local k2, v2
        for k2, v2 in pairs(auras) do
            local kk = tonumber(k2)
            if kk and kk > 0 then
                map[kk] = gen
            end
            local vv = tonumber(v2)
            if vv and vv > 0 then
                map[vv] = gen
            end
        end
    end

    return (map[spellId] == gen)
end

-- Pretty name / rank from spellId using Nampower / SuperWoW
local function _GetSpellNameRank(spellId)
    spellId = tonumber(spellId) or 0

    -- Global caches
    local nameCache = _G["DoiteTrack_SpellNameCache"]
    if not nameCache then
        nameCache = {}
        _G["DoiteTrack_SpellNameCache"] = nameCache
    end

    local rankCache = _G["DoiteTrack_SpellRankCache"]
    if not rankCache then
        rankCache = {}
        _G["DoiteTrack_SpellRankCache"] = rankCache
    end

    local cachedName = nameCache[spellId]
    if cachedName ~= nil then
        if cachedName == false then
            return ("Spell " .. tostring(spellId)), nil
        end

        local cachedRank = rankCache[spellId]
        if cachedRank == false then
            cachedRank = nil
        end

        return cachedName, cachedRank
    end

    local name, rank

    if GetSpellNameAndRankForId then
        local ok, n, r = pcall(GetSpellNameAndRankForId, spellId)
        if ok and n and n ~= "" then
            name = n
            rank = r
        end
    end

    if (not name or name == "") and SpellInfo then
        -- SpellInfo(spellId) -> name, rank, texture
        local n, r = SpellInfo(spellId)
        if type(n) == "string" and n ~= "" then
            name = n
        end
        if type(r) == "string" and r ~= "" then
            rank = r
        end
    end

    if not name or name == "" then
        nameCache[spellId] = false
        rankCache[spellId] = false
        return ("Spell " .. tostring(spellId)), nil
    end

    nameCache[spellId] = name
    if rank and rank ~= "" then
        rankCache[spellId] = rank
    else
        rankCache[spellId] = false
    end

    return name, rank
end

---------------------------------------------------------------
-- Chat notifications
---------------------------------------------------------------
local function _FormatCPSuffix(cp)
    if not cp or cp <= 0 then return "" end
    return " (" .. tostring(cp) .. " combo points)"
end

local function _NotifyTrackingStart(spellName, cp, isPlayerTarget)
    local label    = "|cff6FA8DCDoiteAuras:|r "
    local nameCol  = "|cffffff00" .. (spellName or "Unknown") .. "|r"
    local cpSuffix = _FormatCPSuffix(cp)
    local tail

    if isPlayerTarget then
        tail = " duration is being tracked on you to reliably show duration going forward."
    else
        tail = " duration is being tracked to reliably show duration going forward - stay on target until complete."
    end

    _Print(label .. nameCol .. cpSuffix .. tail)
end

local function _NotifyTrackingCancelled(spellName, reason)
    local label   = "|cff6FA8DCDoiteAuras:|r "
    local nameCol = "|cffffff00" .. (spellName or "Unknown") .. "|r"
    local msg     = " tracking cancelled (" .. (reason or "unknown") .. ")."
    _Print(label .. nameCol .. msg)
end

local function _NotifyTrackingFinished(spellId, spellName, spellRank, cp, duration)
    local label    = "|cff6FA8DCDoiteAuras:|r "
    local nameCol  = "|cffffff00" .. (spellName or "Unknown") .. "|r"
    local cpSuffix = _FormatCPSuffix(cp)
    local durStr   = string.format(" recorded duration: %.1f sec", duration or 0)
    _Print(label .. nameCol .. cpSuffix .. durStr)

    ----------------------------------------------------------------
    -- Extra helper line to copy into SpellDurationSec / SpellDurationSecCP
    ----------------------------------------------------------------
    local sec = math.floor((duration or 0) + 0.5)

    -- Get the raw durationIndex from SpellRec (not mapped through SpellDurationSec)
    local durationIndex = nil
    if GetSpellRecField then
        local ok, idx = pcall(GetSpellRecField, spellId, "durationIndex")
        if ok and type(idx) == "number" and idx > 0 then
            durationIndex = idx
        end
    end

    -- Rank part "(Rank 6)" if present
    local rankSuffix = ""
    if spellRank and spellRank ~= "" then
        rankSuffix = " (" .. spellRank .. ")"
    end

    local nameForComment = spellName or ("Spell " .. tostring(spellId or 0))

    -- Build the trailing comment: "Rip (Rank 6)/(9896)/(4CP)"
    local comment = nameForComment .. rankSuffix

    -- /(spellId)
    if spellId and spellId > 0 then
        comment = comment .. "/(" .. tostring(spellId) .. ")"
    end

    -- /(4CP) if combo-based
    if cp and cp > 0 then
        comment = comment .. "/(" .. tostring(cp) .. "CP)"
    end

    -- Red label for the copy line
    local redLabel = "|cffff0000Notify & Copy for Doite:|r "

    local copyLine

    if durationIndex and durationIndex > 0 then
        if cp and cp > 0 then
            -- CP-based: paste inside SpellDurationSecCP = { ... }
            -- Example:
            --   [87] = { [1] = 10, }, -- Rip (Rank 6)/(9896)/(1CP)
            copyLine = string.format(
                "%s[%s] = { [%d] = %d, }, -- %s",
                redLabel,
                tostring(durationIndex),
                cp,
                sec,
                comment
            )
        else
            -- Flat duration: paste inside SpellDurationSec = { ... }
            -- Example:
            --   [265] = 55, -- Some Spell (Rank 3)/(12345)
            copyLine = string.format(
                "%s[%s] = %d, -- %s",
                redLabel,
                tostring(durationIndex),
                sec,
                comment
            )
        end
    else
        -- Fallback if durationIndex is unknown
        copyLine = string.format(
            "%s-- durationIndex=?  sec=%d  %s",
            redLabel,
            sec,
            comment
        )
    end

    _Print(copyLine)
end

_NotifyCorrectionApplied = function(kind, displayName, measuredSec, dbcSec)
    local label   = "|cff6FA8DCDoiteAuras:|r "
    local tWhite  = "|cffffffff" .. (kind or "Aura") .. " - " .. "|r"
    local nYellow = "|cffffff00" .. (displayName or "Unknown") .. "|r"
    local mYellow = "|cffffff00" .. tostring(measuredSec or "?") .. "s|r"
    local dYellow = "|cffffff00" .. tostring(dbcSec or "?") .. "s|r"
    _Print(label .. tWhite .. nYellow .. " corrected duration saved: " .. mYellow .. " (DBC " .. dYellow .. ").")
end

_NotifyCorrectionCleared = function(kind, displayName, measuredSec, dbcSec)
    local label   = "|cff6FA8DCDoiteAuras:|r "
    local tWhite  = "|cffffffff" .. (kind or "Aura") .. " - " .. "|r"
    local nYellow = "|cffffff00" .. (displayName or "Unknown") .. "|r"
    local mYellow = "|cffffff00" .. tostring(measuredSec or "?") .. "s|r"
    local dYellow = "|cffffff00" .. tostring(dbcSec or "?") .. "s|r"
    _Print(label .. tWhite .. nYellow .. " matches DBC (" .. dYellow .. "); cleared override (measured " .. mYellow .. ").")
end

---------------------------------------------------------------
-- Spell debug helper
---------------------------------------------------------------
local _debugSpells = false

local function _DebugSpell(spellId, cp, stage)
    if not _debugSpells then return end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return end

    local name, rank = _GetSpellNameRank(spellId)

    -- raw DBC durationIndex (not mapped)
    local idx = nil
    if GetSpellRecField then
        local ok, v = pcall(GetSpellRecField, spellId, "durationIndex")
        if ok and type(v) == "number" and v > 0 then
            idx = v
        end
    end

    local dbc    = _GetDBCBaseDuration(spellId, cp)
    local flat   = _GetTrackedFlatDuration(spellId)
    local cpDur  = (cp and cp > 0) and _GetTrackedCPDuration(spellId, cp) or nil

    local corr = nil
    if cp and cp > 0 then
        corr = _GetCorrectedCPDuration(spellId, cp)
    else
        corr = _GetCorrectedFlatDuration(spellId)
    end

    local willRecord = _ShouldRecord(spellId, cp)

    local entry = TrackedBySpellId[spellId]
    local selfOnly = false
    if entry then
        selfOnly = (entry.trackSelf and (not entry.trackHelp) and (not entry.trackHarm))
    end

    -- Would correction test run again right now?
    local baseKind, baseR = nil, nil
    local corrTest = false
    local seen = nil

    if (not willRecord) and entry and entry.onlyMine and (entry.trackHelp or entry.trackHarm) and (not selfOnly) then
        if corr and corr > 0 then
            baseKind = "corr"
            baseR = math.floor(corr + 0.5)
        elseif dbc and dbc > 0 then
            baseKind = "dbc"
            baseR = math.floor(dbc + 0.5)
        else
            local stored = cpDur
            if not stored then stored = flat end
            if stored and stored > 0 then
                baseKind = "tracked"
                baseR = math.floor(stored + 0.5)
            end
        end

        if baseR and baseR > 0 and baseR < 600 then
            local key = _CorrectionKey(spellId, cp, baseR)
            seen = _correctionSeenThisSession[key] and true or false
            corrTest = (not seen)
        end
    end

    _Print(string.format(
        "DoiteTrackDBG[%s]: id=%d name=%s cp=%d idx=%s dbc=%s tracked(flat=%s cp=%s) corr=%s willRecord=%s corrTest=%s baseKind=%s base=%s seen=%s arm=%s",
        stage or "?", spellId, tostring(name),
        cp or 0,
        tostring(idx),
        tostring(dbc),
        tostring(flat),
        tostring(cpDur),
        tostring(corr),
        tostring(willRecord),
        tostring(corrTest),
        tostring(baseKind),
        tostring(baseR),
        tostring(seen),
        tostring(_lastProfileSig)
    ))
end

_G["DoiteTrack_SetSpellDebug"] = function(on)
    _debugSpells = (on and true or false)
    if _debugSpells then
        _Print("|cff6FA8DCDoiteAuras:|r spell debug |cffffff00ON|r")
    else
        _Print("|cff6FA8DCDoiteAuras:|r spell debug |cffffff00OFF|r")
    end
end

---------------------------------------------------------------
-- SPELL_CAST_EVENT handler (Nampower)
---------------------------------------------------------------
local TrackFrame = CreateFrame("Frame", "DoiteTrackFrame")
local _lastUpdate = 0

local function _EnsureOnUpdateEnabled()
    if not TrackFrame._onUpdateActive then
        TrackFrame._onUpdateActive = true
        TrackFrame:SetScript("OnUpdate", function()
            local now = GetTime()
            -- Only do heavy work every 0.1s
            if now - _lastUpdate < 0.1 then
                return
            end
            _lastUpdate = now

            local anyActive = false
            local id, s

            for id, s in pairs(ActiveSessions) do
                if not s.aborted and not s.complete then
                    anyActive = true

                    local unit = _FindUnitByGuid(s.targetGuid)
                    local now2 = now

                    if not unit then
                        local lastUnit = s.lastUnitSeenAt or s.startedAt or now2
                        if (now2 - lastUnit) > 15 then
                            _AbortSession(s, "target lost")
                            if s.willRecord then
                                _NotifyTrackingCancelled(s.spellName, "target lost")
                            elseif s.correctMode then
                                _DebugCorrection("cancel: target lost ("..tostring(s.spellId)..")")
                            end
                        end
                    else
                        s.lastUnitSeenAt = now2

                        if UnitIsDead and UnitIsDead(unit) == 1 then
                            _AbortSession(s, "target died")
                            if s.willRecord then
                                _NotifyTrackingCancelled(s.spellName, "target died")
                            elseif s.correctMode then
                                _DebugCorrection("cancel: target died ("..tostring(s.spellId)..")")
                            end
                        else
                            local hasAura = _AuraHasSpellId(unit, s.spellId, s.isDebuff)

                            if hasAura then
                                if s.correctMode and (not s.applyConfirmed) then
                                    -- Fallback: if AuraCast confirm events aren't delivered, treat first visible aura as confirmed.
                                    s.applyConfirmed = true
                                    if not s.appliedAt then
                                        s.appliedAt = now2
                                    end
                                    s.lastSeen = now2

                                    -- Keep runtime aura bucket in sync for remaining-time queries.
                                    _RecordAuraForSession(s)
                                else
                                    if not s.appliedAt then
                                        s.appliedAt = now2
                                    end
                                    s.lastSeen = now2

                                    -- Keep runtime aura bucket in sync for remaining-time queries.
                                    _RecordAuraForSession(s)
                                end
                            else
                                if s.appliedAt then

                                    -- If the player manually right-clicked off a buff on themselves, abort (do NOT treat as a natural fade / do NOT record duration).
                                    if unit == "player" and s.kind == "Buff" and _clickOffAt then
                                        local dt = now2 - _clickOffAt

                                        -- Expire marker quickly (keeps it tight + avoids false hits)
                                        if dt > 1.0 then
                                            _clickOffAt     = nil
                                            _clickOffTex    = nil
                                            _clickOffAuraId = nil
                                        elseif dt >= 0 and dt <= 0.75 then
                                            local matched = false

                                            -- Best match: SuperWoW auraId (typically spellId)
                                            if _clickOffAuraId and _clickOffAuraId == s.spellId then
                                                matched = true
                                            end

                                            -- Fallback: texture match (handles non-superwow / missing auraId)
                                            if (not matched) and _clickOffTex then
                                                local st = _GetSpellTextureNorm(s.spellId)
                                                if st and st == _clickOffTex then
                                                    matched = true
                                                end
                                            end

                                            if matched then
                                                _AbortSession(s, "player clicked off buff")
                                                if s.willRecord then
                                                    _NotifyTrackingCancelled(s.spellName, "buff clicked off")
                                                elseif s.correctMode then
                                                    _DebugCorrection("cancel: player clicked off buff ("..tostring(s.spellId)..")")
                                                end

                                                -- consume marker - don't cancel other sessions
                                                _clickOffAt     = nil
                                                _clickOffTex    = nil
                                                _clickOffAuraId = nil
                                            end
                                        end
                                    end

                                    if not s.aborted then
                                        local lastSeen = s.lastSeen or s.appliedAt or now2
                                        local gap      = now2 - lastSeen

                                        if gap > 1.5 then
                                            _AbortSession(s, "aura faded off-target")
                                            if s.willRecord then
                                                _NotifyTrackingCancelled(s.spellName, "aura faded while not targeted")
                                            elseif s.correctMode then
                                                _DebugCorrection("cancel: aura faded while not targeted ("..tostring(s.spellId)..")")
                                            end
                                        else
                                            local dur = lastSeen - s.appliedAt
                                            if dur > 0.5 and dur < 600 then
                                                _FinishSession(s, dur)
                                                if s.willRecord then
                                                    _NotifyTrackingFinished(s.spellId, s.spellName, s.spellRank, s.cp, dur)
                                                end
                                                -- correction-mode prints only if it actually applied an override (inside _FinishSession)
                                            else
                                                _AbortSession(s, "duration out of range")
                                                if s.willRecord then
                                                    _NotifyTrackingCancelled(s.spellName, "duration out of range")
                                                end
                                            end
                                        end
                                    end
                                else
                                    local age = now2 - (s.startedAt or now2)
                                    if age > 1.5 then
                                        if s.correctMode and (not s.applyConfirmed) then
                                            _AbortSession(s, "no player aura confirm")
                                            _DebugCorrection("cancel: no player aura confirm ("..tostring(s.spellId)..")")
                                        else
                                            _AbortSession(s, "aura never applied")
                                            if s.willRecord then
                                                _NotifyTrackingCancelled(s.spellName, "aura never applied")
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if not anyActive then
                TrackFrame._onUpdateActive = false
                TrackFrame:SetScript("OnUpdate", nil)
            end
        end)
    end
end

function DoiteTrack:_OnSpellCastEvent()
    local success    = arg1
    local spellId    = arg2
    local castType   = arg3
    local targetGuid = arg4
    local itemId     = arg5

    if success ~= 1 then
        return
    end

    if not spellId or spellId == 0 then
        return
    end

    local now = GetTime()
    RecentCastBySpellId[spellId] = now
    local entry = TrackedBySpellId[spellId]

    -- Fallback: resolve by normalised spell name so downranks still match
    if not entry then
        local castName

        if GetSpellNameAndRankForId then
            local ok, n = pcall(GetSpellNameAndRankForId, spellId)
            if ok and n and n ~= "" then
                castName = n
            end
        end

        if not castName and SpellInfo then
            local n = SpellInfo(spellId)
            if type(n) == "string" and n ~= "" then
                castName = n
            end
        end

        if castName then
            local norm = _NormSpellName(castName)
            if norm then
                local byNorm = TrackedByNameNorm[norm]
                if byNorm then
                    entry = byNorm
                    entry.spellIds[spellId] = true
                    TrackedBySpellId[spellId] = entry
                end
            end
        end
    end

    if not entry then
        entry = _MaybeRebuildWatchListForSpell(spellId)
    end

    if not entry then
        return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid then
        return
    end

    local selfOnly = (entry.trackSelf and (not entry.trackHelp) and (not entry.trackHarm))

    if selfOnly then
        targetGuid = pGuid
    else
        -- For target-based auras (help/harm), NEVER fall back to player.
        if (not targetGuid) or targetGuid == "" or targetGuid == "0x000000000" or targetGuid == "0x0000000000000000" then
            local tg = _GetUnitGuidSafe("target")
            if tg and tg ~= "" then
                targetGuid = tg
            else
                return
            end
        end
    end

    local cp = 0
    if _PlayerUsesComboPoints() and entry.kind == "Debuff" and _SpellUsesComboDuration(spellId) then
        cp = _GetComboPointsSafe()
    end

    local willRecord = _ShouldRecord(spellId, cp)

    -- correction-mode (recheck baseline once per armed window)
    local correctMode = false
    local correctBaseKind = nil
    local correctBaseRounded = nil

    if (not willRecord) then
        if entry.onlyMine and (entry.trackHelp or entry.trackHarm) and (not (entry.trackSelf and (not entry.trackHelp) and (not entry.trackHarm))) then
            -- Order:
            -- a) correction recording (stored override)
            -- b) DBC
            -- c) learned (tracked)
            local corr = nil
            if cp and cp > 0 then
                corr = _GetCorrectedCPDuration(spellId, cp)
            else
                corr = _GetCorrectedFlatDuration(spellId)
            end

            if corr and corr > 0 then
                correctBaseKind = "corr"
                correctBaseRounded = math.floor(corr + 0.5)
            else
                local baseDBC = _GetDBCBaseDuration(spellId, cp)
                if baseDBC and baseDBC > 0 then
                    correctBaseKind = "dbc"
                    correctBaseRounded = math.floor(baseDBC + 0.5)
                else
                    local stored = nil
                    if cp > 0 then stored = _GetTrackedCPDuration(spellId, cp) end
                    if not stored then stored = _GetTrackedFlatDuration(spellId) end
                    if stored and stored > 0 then
                        correctBaseKind = "tracked"
                        correctBaseRounded = math.floor(stored + 0.5)
                    end
                end
            end

            if correctBaseRounded and correctBaseRounded > 0 and correctBaseRounded < 600 then
                local key = _CorrectionKey(spellId, cp, correctBaseRounded)
                if not _correctionSeenThisSession[key] then
                    correctMode = true
                    if correctBaseKind == "corr" then
                        _DebugCorrection(string.format("start CORR check id=%d cp=%d corr=%d", spellId, cp, correctBaseRounded))
                    elseif correctBaseKind == "dbc" then
                        _DebugCorrection(string.format("start DBC check id=%d cp=%d base=%d", spellId, cp, correctBaseRounded))
                    else
                        _DebugCorrection(string.format("start learned recheck id=%d cp=%d stored=%d", spellId, cp, correctBaseRounded))
                    end
                end
            else
                correctBaseKind = nil
                correctBaseRounded = nil
            end
        end
    end

    _DebugSpell(spellId, cp, "CAST")

    local sid, existing = _FindSessionFor(spellId, targetGuid)
    if existing then
        _AbortSession(existing, "refreshed before fade")
        if existing.willRecord then
            _NotifyTrackingCancelled(existing.spellName, "refreshed before fade; starting new recording")
        end
    end

    SessionCounter = SessionCounter + 1

    local name, rank     = _GetSpellNameRank(spellId)
    local isPlayerTarget = (targetGuid == pGuid)

    local s = {
        id         = SessionCounter,
        spellId    = spellId,
        spellName  = name,
        spellRank  = rank,
        kind       = entry.kind,
        isDebuff   = (entry.kind == "Debuff"),
        targetGuid = targetGuid,
        ownerGuid  = pGuid,
        cp         = cp,
        startedAt  = now,
        appliedAt  = nil,
        lastSeen   = nil,
        aborted    = false,
        complete   = false,
        source     = "cast",
        willRecord = willRecord,
        correctMode        = correctMode,
        correctBaseKind    = correctBaseKind,
        correctBaseRounded = correctBaseRounded,
        correctDisplayName = entry.name,
        applyConfirmed     = (not correctMode),
    }

    ActiveSessions[s.id] = s

    if willRecord then
        _NotifyTrackingStart(name, cp, isPlayerTarget)
    end
    _EnsureOnUpdateEnabled()
end

function DoiteTrack:_OnUnitCastEvent()
    local casterGuid = arg1
    local targetGuid = arg2
    local evType     = arg3
    local spellId    = arg4
    local castDur    = arg5

    if evType ~= "CAST" and evType ~= "CHANNEL" and evType ~= "START" then
        return
    end

    if not spellId or spellId == 0 then
        return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid or not casterGuid or casterGuid == "" or casterGuid ~= pGuid then
        return
    end

    local now = GetTime()

    local last = RecentCastBySpellId[spellId]
    if last and (now - last) < 1.0 then
        return
    end
    RecentCastBySpellId[spellId] = now

    local entry = TrackedBySpellId[spellId]

    if not entry then
        local castName

        if GetSpellNameAndRankForId then
            local ok, n = pcall(GetSpellNameAndRankForId, spellId)
            if ok and n and n ~= "" then
                castName = n
            end
        end

        if not castName and SpellInfo then
            local n = SpellInfo(spellId)
            if type(n) == "string" and n ~= "" then
                castName = n
            end
        end

        if castName then
            local norm = _NormSpellName(castName)
            if norm then
                local byNorm = TrackedByNameNorm[norm]
                if byNorm then
                    entry = byNorm
                    entry.spellIds[spellId] = true
                    TrackedBySpellId[spellId] = entry
                end
            end
        end
    end

    if not entry then
        entry = _MaybeRebuildWatchListForSpell(spellId)
    end

    if not entry then
        return
    end

    local selfOnly = (entry.trackSelf and (not entry.trackHelp) and (not entry.trackHarm))

    if selfOnly then
        targetGuid = pGuid
    else
        if (not targetGuid) or targetGuid == "" or targetGuid == "0x000000000" or targetGuid == "0x0000000000000000" then
            local tg = _GetUnitGuidSafe("target")
            if tg and tg ~= "" then
                targetGuid = tg
            else
                return
            end
        end
    end

    local cp = 0
    if _PlayerUsesComboPoints() and entry.kind == "Debuff" and _SpellUsesComboDuration(spellId) then
        cp = _GetComboPointsSafe()
    end

   local willRecord = _ShouldRecord(spellId, cp)

    -- correction-mode (recheck baseline once per armed window)
    local correctMode = false
    local correctBaseKind = nil
    local correctBaseRounded = nil

    if (not willRecord) then
        if entry.onlyMine and (entry.trackHelp or entry.trackHarm) and (not (entry.trackSelf and (not entry.trackHelp) and (not entry.trackHarm))) then
            -- Order:
            -- a) correction recording (stored override)
            -- b) DBC
            -- c) learned (tracked)
            local corr = nil
            if cp and cp > 0 then
                corr = _GetCorrectedCPDuration(spellId, cp)
            else
                corr = _GetCorrectedFlatDuration(spellId)
            end

            if corr and corr > 0 then
                correctBaseKind = "corr"
                correctBaseRounded = math.floor(corr + 0.5)
            else
                local baseDBC = _GetDBCBaseDuration(spellId, cp)
                if baseDBC and baseDBC > 0 then
                    correctBaseKind = "dbc"
                    correctBaseRounded = math.floor(baseDBC + 0.5)
                else
                    local stored = nil
                    if cp > 0 then stored = _GetTrackedCPDuration(spellId, cp) end
                    if not stored then stored = _GetTrackedFlatDuration(spellId) end
                    if stored and stored > 0 then
                        correctBaseKind = "tracked"
                        correctBaseRounded = math.floor(stored + 0.5)
                    end
                end
            end

            if correctBaseRounded and correctBaseRounded > 0 and correctBaseRounded < 600 then
                local key = _CorrectionKey(spellId, cp, correctBaseRounded)
                if not _correctionSeenThisSession[key] then
                    correctMode = true
                    if correctBaseKind == "corr" then
                        _DebugCorrection(string.format("start CORR check id=%d cp=%d corr=%d", spellId, cp, correctBaseRounded))
                    elseif correctBaseKind == "dbc" then
                        _DebugCorrection(string.format("start DBC check id=%d cp=%d base=%d", spellId, cp, correctBaseRounded))
                    else
                        _DebugCorrection(string.format("start learned recheck id=%d cp=%d stored=%d", spellId, cp, correctBaseRounded))
                    end
                end
            else
                correctBaseKind = nil
                correctBaseRounded = nil
            end
        end
    end

    _DebugSpell(spellId, cp, "UNIT_CAST")

    local sid, existing = _FindSessionFor(spellId, targetGuid)
    if existing then
        _AbortSession(existing, "refreshed before fade")
        if existing.willRecord then
            _NotifyTrackingCancelled(existing.spellName, "refreshed before fade; starting new recording")
        end
    end

    SessionCounter = SessionCounter + 1

    local name, rank     = _GetSpellNameRank(spellId)
    local isPlayerTarget = (targetGuid == pGuid)

    local s = {
        id         = SessionCounter,
        spellId    = spellId,
        spellName  = name,
        spellRank  = rank,
        kind       = entry.kind,
        isDebuff   = (entry.kind == "Debuff"),
        targetGuid = targetGuid,
        ownerGuid  = pGuid,
        cp         = cp,
        startedAt  = now,
        appliedAt  = nil,
        lastSeen   = nil,
        aborted    = false,
        complete   = false,
        source     = "cast",
        willRecord = willRecord,
        correctMode        = correctMode,
        correctBaseKind    = correctBaseKind,
        correctBaseRounded = correctBaseRounded,
        correctDisplayName = entry.name,
        applyConfirmed     = (not correctMode),
    }

    ActiveSessions[s.id] = s

    if willRecord then
        _NotifyTrackingStart(name, cp, isPlayerTarget)
    end
    _EnsureOnUpdateEnabled()
end

function DoiteTrack:_OnSpellDamageSelf()
    local targetGuid = arg1  -- targetGuid
    local casterGuid = arg2  -- casterGuid
    local spellId    = arg3  -- spellId

    if not spellId or spellId == 0 then
        return
    end

    local now      = GetTime()
    local lastCast = RecentCastBySpellId[spellId]
    if lastCast and (now - lastCast) < 1.0 then
        return
    end

    local entry = TrackedBySpellId[spellId]
    if not entry then
        return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid or casterGuid ~= pGuid then
        return
    end

    local cp = 0
    local willRecord = _ShouldRecord(spellId, cp)

    if _DebugSpell then
        _DebugSpell(spellId, cp, "DAMAGE")
    end

    now = GetTime()

    local sid, existing = _FindSessionFor(spellId, targetGuid)
    if existing then
        return
    end

    SessionCounter = SessionCounter + 1

    local name, rank     = _GetSpellNameRank(spellId)
    local isPlayerTarget = (targetGuid == pGuid)

    local s = {
        id         = SessionCounter,
        spellId    = spellId,
        spellName  = name,
        spellRank  = rank,
        kind       = entry.kind,
        isDebuff   = (entry.kind == "Debuff"),
        targetGuid = targetGuid,
        ownerGuid  = pGuid,
        cp         = cp,
        startedAt  = now,
        appliedAt  = now,
        lastSeen   = now,
        aborted    = false,
        complete   = false,
        source     = "damage",
        willRecord = willRecord,
    }

    ActiveSessions[s.id] = s

    if willRecord then
        _NotifyTrackingStart(name, cp, isPlayerTarget)
    end
    _EnsureOnUpdateEnabled()
end

function DoiteTrack:_OnAuraCastOnEvent()
    local spellId    = arg1
    local casterGuid = arg2
    local targetGuid = arg3

    if not spellId or spellId == 0 then
        return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid or not casterGuid or casterGuid == "" or casterGuid ~= pGuid then
        return
    end

    if not targetGuid or targetGuid == "" or targetGuid == "0x000000000" or targetGuid == "0x0000000000000000" then
        targetGuid = pGuid
    end

    local _, s = _FindSessionFor(spellId, targetGuid)
    if not s or s.aborted or s.complete then
        return
    end

    -- Only correction sessions require "player-applied" confirmation to start timing.
    if not s.correctMode then
        return
    end

    local now = GetTime()
    s.applyConfirmed = true
    s.appliedAt = now
    s.lastSeen  = now

    _RecordAuraForSession(s)
end

---------------------------------------------------------------
-- PLAYER_LOGIN / PLAYER_ENTERING_WORLD / PLAYER_TARGET_CHANGED
---------------------------------------------------------------

function DoiteTrack:_OnTargetChanged()
    -- reserved for future safeguards
end

function DoiteTrack:_OnUnitInventoryChanged()
    -- only care about player
    if arg1 and arg1 ~= "player" then return end
    self:_OnProfileMaybeChanged("gear_change")
end

TrackFrame:RegisterEvent("PLAYER_LOGIN")
TrackFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
TrackFrame:RegisterEvent("SPELL_CAST_EVENT")
TrackFrame:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
TrackFrame:RegisterEvent("AURA_CAST_ON_SELF")
TrackFrame:RegisterEvent("AURA_CAST_ON_OTHER")
TrackFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
TrackFrame:RegisterEvent("UNIT_CASTEVENT")
TrackFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
TrackFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")

TrackFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        DoiteTrack:_OnPlayerLogin()
    elseif event == "SPELL_CAST_EVENT" then
        DoiteTrack:_OnSpellCastEvent()
    elseif event == "SPELL_DAMAGE_EVENT_SELF" then
        DoiteTrack:_OnSpellDamageSelf()
    elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
        DoiteTrack:_OnAuraCastOnEvent()
    elseif event == "PLAYER_TARGET_CHANGED" then
        DoiteTrack:_OnTargetChanged()
	elseif event == "UNIT_INVENTORY_CHANGED" then
        DoiteTrack:_OnUnitInventoryChanged()
    elseif event == "LEARNED_SPELL_IN_TAB" then
        _ScheduleProfileRescan(event)
    elseif event == "UNIT_CASTEVENT" then
        DoiteTrack:_OnUnitCastEvent()
    end
end)

---------------------------------------------------------------
-- Runtime API
---------------------------------------------------------------
function DoiteTrack:IsMyAuraActive(spellId, unit)
    if not spellId or not unit then
        return false
    end

    -- "Active" == currently have a positive remaining time.
    local rem = self:GetAuraRemainingSeconds(spellId, unit)
    return (rem ~= nil and rem > 0)
end

function DoiteTrack:GetAuraRemainingSeconds(spellId, unit)
    if not spellId or not unit then return nil end
    local guid = _GetUnitGuidSafe(unit)
    if not guid then return nil end

    local bucket = AuraStateByGuid[guid]
    if not bucket then return nil end

    local a = bucket[spellId]
    if not a then return nil end

    local base = a.fullDur
    if not base or base <= 0 then
        base = _GetBaselineDuration(spellId, a.cp or 0)
        if not base or base <= 0 then
            return nil
        end
        a.fullDur = base
    end

    local appliedAt = a.appliedAt or a.lastSeen
    if not appliedAt then
        return nil
    end

    local now     = GetTime()
    local elapsed = now - appliedAt
    local rem     = base - elapsed

    if rem <= 0 then
        -- past players own duration, forget this entry for ownership purposes
        bucket[spellId] = nil
        return nil
    end

    return rem
end

function DoiteTrack:RemainingPasses(spellId, unit, comp, threshold)
    if not spellId or not unit or not comp or threshold == nil then
        return nil
    end
    local rem = self:GetAuraRemainingSeconds(spellId, unit)
    if not rem or rem <= 0 then
        return nil
    end

    if comp == ">=" then
        return rem >= threshold
    elseif comp == "<=" then
        return rem <= threshold
    elseif comp == "==" then
        return rem == threshold
    end
    return nil
end

---------------------------------------------------------------
-- Name-based + recording helpers for DoiteConditions
---------------------------------------------------------------

-- Find tracking entry for a display name ("Rend", all ranks)
local function _GetEntryForName(spellName)
    if not spellName or spellName == "" then
        return nil
    end
    local norm = _NormSpellName(spellName)
    if not norm then
        return nil
    end
    return TrackedByNameNorm[norm]
end

-- Find active recording session for (spellId, unit)
local function _GetActiveSessionForUnit(spellId, unit)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 or not unit then
        return nil
    end

    local guid = _GetUnitGuidSafe(unit)
    if not guid or guid == "" then
        return nil
    end

    local id, s = _FindSessionFor(spellId, guid)
    if not id or not s or s.aborted or s.complete then
        return nil
    end
    return s
end

-- Public: is there a dynamic recording session for this aura on this unit?
function DoiteTrack:IsAuraRecording(spellId, unit)
    return _GetActiveSessionForUnit(spellId, unit) ~= nil
end

-- Public: remaining seconds by *name* (all ranks) on a unit.
-- Returns: remainingSeconds or nil if unknown/not active.
-- Second return value is the spellId that matched (or nil).
function DoiteTrack:GetAuraRemainingSecondsByName(spellName, unit)
    if not spellName or not unit then
        return nil
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return nil
    end

    local bestRem, bestSpellId = nil, nil

    for sid in pairs(entry.spellIds) do
        local rem = self:GetAuraRemainingSeconds(sid, unit)
        if rem and rem > 0 then
            if not bestRem or rem > bestRem then
                bestRem    = rem
                bestSpellId = sid
            end
        end
    end

    if not bestRem or bestRem <= 0 then
        return nil
    end

    return bestRem, bestSpellId
end

-- Public: comparison helper by *name* (same semantics as RemainingPasses)
-- Returns boolean or nil if no active / no duration.
function DoiteTrack:RemainingPassesByName(spellName, unit, comp, threshold)
    if not spellName or not unit or not comp or threshold == nil then
        return nil
    end

    local rem = self:GetAuraRemainingSecondsByName(spellName, unit)
    if not rem or rem <= 0 then
        return nil
    end

    if comp == ">=" then
        return rem >= threshold
    elseif comp == "<=" then
        return rem <= threshold
    elseif comp == "==" then
        return rem == threshold
    end
    return nil
end

-- Public: "is aura mine?" by *name* (true/false), using DoiteTrack’s state
function DoiteTrack:IsAuraMineByName(spellName, unit)
    if not spellName or not unit then
        return false
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return false
    end

    for sid in pairs(entry.spellIds) do
        if self:IsAuraMine(sid, unit) then
            return true
        end
    end

    return false
end

-- Public: remaining or "recording" flag by *name*
-- Returns:
--   remSeconds or nil,
--   isRecording:boolean,
--   spellId or nil
function DoiteTrack:GetAuraRemainingOrRecordingByName(spellName, unit)
    if not spellName or not unit then
        return nil, false, nil
    end

    local rem, sid = self:GetAuraRemainingSecondsByName(spellName, unit)
    if rem and rem > 0 then
        return rem, false, sid
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return nil, false, nil
    end

    for spellId in pairs(entry.spellIds) do
        if self:IsAuraRecording(spellId, unit) then
            return nil, true, spellId
        end
    end

    return nil, false, nil
end

----------------------------------
-- API Public
----------------------------------

-- Public: does this unit have this aura (by name, any rank), regardless of owner?
function DoiteTrack:HasAnyAuraByName(spellName, unit)
    if not spellName or not unit then
        return false, nil
    end

    local entry = _GetEntryForName(spellName)
    if not entry then
        return false, nil
    end
    entry.spellIds = entry.spellIds or {}

    if not _UnitExistsFlag(unit) then
        return false, nil
    end

    -- 1) Fast path: known spellIds
    local sid
    for sid in pairs(entry.spellIds) do
        if _AuraHasSpellId(unit, sid, entry.kind == "Debuff") then
            return true, sid
        end
    end

    -- 2) Slow path: discover spellId by scanning unit aura ids -> spell name -> normalize
    local discovered = _CacheMatchingAuraIdsOnUnit(entry, unit)
    if discovered and discovered > 0 then
        return true, discovered
    end

    return false, nil
end

-- Public - consolidated ownership helper for DoiteConditions:
-- Returns:
--   remSeconds or nil,
--   isRecording:boolean,
--   spellId or nil (best "mine" spell if any),
--   isMine:boolean,      -- true if at least one *mine* aura exists
--   isOther:boolean,     -- true if at least one *non-mine* aura exists
--   ownerKnown:boolean   -- true if at least something about ownership
function DoiteTrack:GetAuraOwnershipByName(spellName, unit)
    if not spellName or not unit then
        return nil, false, nil, false, false, false
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return nil, false, nil, false, false, false
    end

    -- Cheap existence guard
    if not _UnitExistsFlag(unit) then
        return nil, false, nil, false, false, false
    end

    -- Ensure spellIds for whatever rank is actually on the unit right now. Only do the slow spellId discovery if none of our known ids are present.
    entry.spellIds = entry.spellIds or {}

    local isDebuff = (entry.kind == "Debuff")
    local anyPresent = false

    local sid
    for sid in pairs(entry.spellIds) do
        if _AuraHasSpellId(unit, sid, isDebuff) then
            anyPresent = true
            break
        end
    end

    if not anyPresent then
        local discovered = _CacheMatchingAuraIdsOnUnit(entry, unit)
        if not discovered or discovered <= 0 then
            return nil, false, nil, false, false, false
        end
    end

    local bestRem, bestSpellId = nil, nil
    local recording            = false
    local hasMine              = false
    local hasOther             = false

    -- Walk ALL spellIds for this name and inspect ownership per-id
    for sid in pairs(entry.spellIds) do
        -- Is this aura (this spellId) actually present on the unit?
        if _AuraHasSpellId(unit, sid, isDebuff) then
            local mineSid = self:IsAuraMine(sid, unit, true, isDebuff)

            if mineSid then
                hasMine = true

                -- Only ever report remaining time for *our* auras
                local remSid = self:GetAuraRemainingSeconds(sid, unit)
                if remSid and remSid > 0 then
                    if not bestRem or remSid > bestRem then
                        bestRem    = remSid
                        bestSpellId = sid
                    end
                end

                -- Recording is also "ours only"
                if self:IsAuraRecording(sid, unit) then
                    recording = true
                end
            else
                -- Aura with this spellId is present but not ours
                hasOther = true
            end
        end
    end

    local ownerKnown = (hasMine or hasOther)

    if bestRem ~= nil and bestRem <= 0 then
        bestRem = nil
    end

    return bestRem, recording, bestSpellId, hasMine, hasOther, ownerKnown
end


-- Return the baseline duration (DBC or learned) for this spellId/cp, or nil if unknown.
function DoiteTrack:GetBaselineDuration(spellId, cp)
    if not spellId then return nil end
    return _GetBaselineDuration(spellId, cp or 0)
end

-- Convenience boolean: know any duration (DBC or learned) for this spellId/cp?
function DoiteTrack:HasKnownDuration(spellId, cp)
    if not spellId then return false end
    return _GetBaselineDuration(spellId, cp or 0) ~= nil
end

-- Will a cast of this spell (with this cp) start a dynamic recording?w (i.e. no DBC entry and no stored duration yet)
function DoiteTrack:WillRecord(spellId, cp)
    if not spellId then return false end
    return _ShouldRecord(spellId, cp or 0)
end

-- Is the tracked aura on this unit ours (player-cast)? "Mine" == either:
--   * have an active recording session for this spell/unit, OR
--   * have a positive remaining time from our recorded/DBC duration.
function DoiteTrack:IsAuraMine(spellId, unit, presentOverride, isDebuffOverride)
    if not spellId or not unit then
        return false
    end

    -- If there is an active session for this spell/unit, it is *probably* ours, but only for roughly its expected duration.
    local s = _GetActiveSessionForUnit(spellId, unit)
    if s then
        local base = _GetBaselineDuration(spellId, s.cp or 0)
        if base and s.appliedAt then
            local now     = GetTime()
            local elapsed = now - s.appliedAt

            if elapsed > (base * 1.3) then
                _AbortSession(s, "elapsed beyond baseline; assume other owner")
            else
                return true
            end
        else
            return true
        end
    end

    local present = false

    if presentOverride == true then
        present = true
    else
        local entry = TrackedBySpellId[spellId]
        if isDebuffOverride ~= nil then
            present = _AuraHasSpellId(unit, spellId, isDebuffOverride)
        elseif entry then
            present = _AuraHasSpellId(unit, spellId, entry.kind == "Debuff")
        else
            present = _AuraHasSpellId(unit, spellId, true) or _AuraHasSpellId(unit, spellId, false)
        end

        if not present then
            local guid = _GetUnitGuidSafe(unit)
            if guid and AuraStateByGuid[guid] then
                AuraStateByGuid[guid][spellId] = nil
            end
            return false
        end
    end

    local rem = self:GetAuraRemainingSeconds(spellId, unit)
    return (rem ~= nil and rem > 0)
end

--------------------
-- Ingame selftest
--------------------
-- /run DoiteTrack_SetCorrectionDebug(true)
-- /run DoiteTrack_SetSpellDebug(true)

-- Owner: /run d=DoiteTrack;n="Rend";u="target";rem,rec,sid,hm,ho,ok=d:GetAuraOwnershipByName(n,u);print("has",ok,"sid",sid,"mine",hm,"other",ho,"rem",rem,"rec",rec)
-- DurationIndex: /run id=123;idx=GetSpellRecField(id,"durationIndex");d=DoiteTrack:GetBaselineDuration(id,0);print("id",id,"idx",idx,"sec",d)
-- /run local id=11574 local d=DoiteTrack local r=d:GetAuraRemainingSeconds(id,"target") local c=d:IsAuraRecording(id,"target") local m=d:IsAuraMine(id,"target") local b=d:GetBaselineDuration(id,0) print("r",r,"c",c,"m",m,"b",b)