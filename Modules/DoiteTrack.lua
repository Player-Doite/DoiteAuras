---------------------------------------------------------------
-- DoiteTrack.lua
-- Aura duration + runtime remaining-time API
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

local DoiteTrack = {}
_G["DoiteTrack"] = DoiteTrack

---------------------------------------------------------------
-- Globals / config overrides
---------------------------------------------------------------

-- Manual durations by spellId ONLY.
-- Value can be:
--  - number (flat seconds)
--  - table  (CP-based: [1..5] = seconds)
--  - Used ONLY when NP returns durationMs == 0.
local ManualDurationBySpellId = {
  ----------------------------------------------------------------
  -- Rip (6 ranks) - CP based
  ----------------------------------------------------------------
  [1079] = { [1]=10,[2]=12,[3]=14,[4]=16,[5]=18 }, -- Rip Rank 1
  [9492] = { [1]=10,[2]=12,[3]=14,[4]=16,[5]=18 }, -- Rip Rank 2
  [9493] = { [1]=10,[2]=12,[3]=14,[4]=16,[5]=18 }, -- Rip Rank 3
  [9752] = { [1]=10,[2]=12,[3]=14,[4]=16,[5]=18 }, -- Rip Rank 4
  [9894] = { [1]=10,[2]=12,[3]=14,[4]=16,[5]=18 }, -- Rip Rank 5
  [9896] = { [1]=10,[2]=12,[3]=14,[4]=16,[5]=18 }, -- Rip Rank 6

  ----------------------------------------------------------------
  -- Rupture (6 ranks) - CP based
  ----------------------------------------------------------------
  [1943] = { [1]=8,[2]=10,[3]=12,[4]=14,[5]=16 }, -- Rupture Rank 1
  [8639] = { [1]=8,[2]=10,[3]=12,[4]=14,[5]=16 }, -- Rupture Rank 2
  [8640] = { [1]=8,[2]=10,[3]=12,[4]=14,[5]=16 }, -- Rupture Rank 3
  [11273] = { [1]=8,[2]=10,[3]=12,[4]=14,[5]=16 }, -- Rupture Rank 4
  [11274] = { [1]=8,[2]=10,[3]=12,[4]=14,[5]=16 }, -- Rupture Rank 5
  [11275] = { [1]=8,[2]=10,[3]=12,[4]=14,[5]=16 }, -- Rupture Rank 6
  
  ----------------------------------------------------------------
  -- Taste for Blood (3 ranks) - CP based
  ----------------------------------------------------------------
  [52528] = { [1]=10,[2]=12,[3]=14,[4]=16,[5]=18 }, -- Taste for Blood Rank 1
  [52529] = { [1]=12,[2]=14,[3]=16,[4]=18,[5]=20 }, -- Taste for Blood Rank 2
  [52530] = { [1]=14,[2]=16,[3]=18,[4]=20,[5]=22 }, -- Taste for Blood Rank 3

  ----------------------------------------------------------------
  -- Kidney Shot (2 ranks) - CP based
  ----------------------------------------------------------------
  [408] = { [1]=1,[2]=2,[3]=3,[4]=4,[5]=5 }, -- Kidney Shot Rank 1
  [8643] = { [1]=2,[2]=3,[3]=4,[4]=5,[5]=6 }, -- Kidney Shot Rank 2
  
  ----------------------------------------------------------------
  -- Slice and Dice (2 ranks) - CP based
  ----------------------------------------------------------------
  [5171] = { [1]=9,[2]=12,[3]=15,[4]=18,[5]=21 }, -- Slice and Dice Rank 1
  [6774] = { [1]=9,[2]=12,[3]=15,[4]=18,[5]=21 }, -- Slice and Dice Rank 2
  
  ----------------------------------------------------------------
  -- Envenom (1 ranks) - CP based
  ----------------------------------------------------------------
  [52531] = { [1]=12,[2]=16,[3]=20,[4]=24,[5]=28 }, -- Envenom Rank 1

  ----------------------------------------------------------------
  -- Placeholder (# ranks) - None CP based
  ----------------------------------------------------------------  
  --[SpellID] = #,
}

---------------------------------------------------------------
-- Local API shortcuts (assigned on login)
---------------------------------------------------------------
local GetTime = GetTime
local UnitClass = UnitClass
local UnitExists = UnitExists
local GetComboPoints = GetComboPoints
local GetSpellNameAndRankForId = GetSpellNameAndRankForId
local GetUnitField = GetUnitField
local GetTalentInfo = GetTalentInfo
local GetNumTalentTabs = GetNumTalentTabs
local GetNumTalents = GetNumTalents

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
  -- UnitExists(unit) returns existsFlag, guid
  local exists, guid = UnitExists(unit)
  if exists and guid and guid ~= "" then
    return guid
  end
  return nil
end

-- player guid cache
local _playerGUID_cached = nil
local function _GetPlayerGUID()
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

local function _UnitExistsFlag(unit)
  if not UnitExists then
    return false
  end
  local e = UnitExists(unit)
  return (e == 1 or e == true)
end

local _IsPlayerDruid = false
local _IsPlayerRogue = false

local function _PlayerUsesComboPoints()
  -- Uses cached flags (updated on LOGIN/ENTERING_WORLD/LEARNED_SPELL_IN_TAB)
  return (_IsPlayerRogue == true) or (_IsPlayerDruid == true)
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

---------------------------------------------------------------
-- DB wiring (NP durations only)
---------------------------------------------------------------
local function _GetDB()
  local db = _G["DoiteAurasDB"]
  if not db then
    db = {}
    _G["DoiteAurasDB"] = db
  end

  -- NP (preferred) baseline durations
  db.npDurations = db.npDurations or {}         -- [spellId] = seconds (rounded)
  db.npDurationsCP = db.npDurationsCP or {}     -- [spellId] = { [cp] = seconds (rounded) }
  db.npDurationsMeta = db.npDurationsMeta or {} -- [spellId] = { samples=?, lastMs=?, lastAt=?, name=?, rank=? }

  return db
end

---------------------------------------------------------------
-- Tracking maps (from DoiteAuras config)
---------------------------------------------------------------
local TrackedBySpellId = {}   -- [spellId] = entry
local TrackedByNameNorm = {}  -- [normName] = entry

---------------------------------------------------------------
-- Normalize names so match across ranks ("Rip", "Rip (Rank 4)")
---------------------------------------------------------------
local function _NormSpellName(name)
  if not name or name == "" then
    return nil
  end

  name = string.gsub(name, "^%s+", "")
  name = string.gsub(name, "%s+$", "")
  name = string.lower(name)

  name = string.gsub(name, "%s*%(rank%s*%d+%)", "")
  name = string.gsub(name, "%s*rank%s*%d+", "")

  name = string.gsub(name, "^%s+", "")
  name = string.gsub(name, "%s+$", "")

  return name
end

---------------------------------------------------------------
-- Scan DoiteAuras config for which buffs/debuffs should be tracked
-- player ONLY care about entries where onlyMine == true.
---------------------------------------------------------------
local function _LooksLikeSpellConfigTable(tbl)
  if type(tbl) ~= "table" then
    return false
  end
  local seen = 0
  for _, v in pairs(tbl) do
    if type(v) == "table" then
      if v.type and v.conditions and v.conditions.aura then
        return true
      end
      seen = seen + 1
      if seen > 20 then
        break
      end
    end
  end
  return false
end

local function _DiscoverSpellTable()
  local visited = {}

  local function scan(tbl)
    if type(tbl) ~= "table" or visited[tbl] then
      return nil
    end
    visited[tbl] = true

    if type(tbl.spells) == "table" and _LooksLikeSpellConfigTable(tbl.spells) then
      return tbl.spells
    end

    for _, v in pairs(tbl) do
      if type(v) == "table" then
        local found = scan(v)
        if found then
          return found
        end
      end
    end

    return nil
  end

  local db = _G["DoiteAurasDB"]
  if db then
    local found = scan(db)
    if found then
      return found
    end
  end

  if _G["DoiteDB"] then
    local found = scan(_G["DoiteDB"])
    if found then
      return found
    end
  end

  return nil
end

local function _AddTrackedFromEntry(_, data)
  if not data or type(data) ~= "table" then
    return
  end

  if data.type ~= "Buff" and data.type ~= "Debuff" then
    return
  end

  local c = data.conditions and data.conditions.aura
  if not c then
    return
  end

  local isOnlyMine = (c.onlyMine == true)
  local isOnlyOthers = (c.onlyOthers == true)

  -- Track onlyMine OR onlyOthers (config-driven)
  if (not isOnlyMine) and (not isOnlyOthers) then
    return
  end


  local hasTarget = (c.targetSelf or c.targetHelp or c.targetHarm)
  if not hasTarget then
    return
  end

  local sid = data.spellid and tonumber(data.spellid)
  if sid and sid <= 0 then
    sid = nil
  end

  local name = data.displayName or data.name or ""
  local norm = _NormSpellName(name)

  if not sid and not norm then
    return
  end

  local entry = nil
  if sid then
    entry = TrackedBySpellId[sid]
  end
  if (not entry) and norm then
    entry = TrackedByNameNorm[norm]
  end

  if not entry then
    entry = {
      spellIds = {},
      name = name,
      normName = norm,
      kind = data.type,
      trackSelf = false,
      trackHelp = false,
      trackHarm = false,
      onlyMine = false,
      onlyOthers = false,
    }
  end

  if sid then
    entry.spellIds[sid] = true
    TrackedBySpellId[sid] = entry
  end
  if norm then
    TrackedByNameNorm[norm] = entry
  end

  if c.targetSelf then
    entry.trackSelf = true
  end
  if c.targetHelp then
    entry.trackHelp = true
  end
  if c.targetHarm then
    entry.trackHarm = true
  end
  if isOnlyMine then
    entry.onlyMine = true
  end
  if isOnlyOthers then
    entry.onlyOthers = true
  end

end

function DoiteTrack:RebuildWatchList()
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

---------------------------------------------------------------
-- Aura presence queries (auraId tables via GetUnitField)
---------------------------------------------------------------
local function _GetUnitAuraTable(unit, isDebuff)
  if not GetUnitField then
    return nil
  end

  local function getFieldTable(fieldName)
    local cache = _G["DoiteTrack_AuraFieldCache"]
    if not cache then
      cache = {}
      _G["DoiteTrack_AuraFieldCache"] = cache
    end

    local now = 0
    if GetTime then
      now = GetTime()
    end

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

    if f._g1 == gen then
      local v = f._v1
      if v == false then
        return nil
      end
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

    if f._g0 == gen then
      local v2 = f._v0
      if v2 == false then
        return nil
      end
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

  if isDebuff then
    return getFieldTable("debuff") or getFieldTable("aura") or getFieldTable("buff")
  else
    return getFieldTable("buff") or getFieldTable("aura") or getFieldTable("debuff")
  end
end

local function _AuraHasSpellId(unit, spellId, isDebuff)
  spellId = tonumber(spellId) or 0
  if not unit or spellId <= 0 then
    return false
  end

  local auras = _GetUnitAuraTable(unit, isDebuff)
  if type(auras) ~= "table" then
    return false
  end

  if auras[spellId] then
    return true
  end

  local n = table.getn(auras)
  if n and n > 0 then
    local i
    for i = 1, n do
      if tonumber(auras[i]) == spellId then
        return true
      end
    end
  end

  if isDebuff and n and n >= 16 then
    local buffs = _GetUnitAuraTable(unit, false)
    if type(buffs) == "table" then
      if buffs[spellId] then
        return true
      end

      local n2 = table.getn(buffs)
      if n2 and n2 > 0 then
        local j
        for j = 1, n2 do
          if tonumber(buffs[j]) == spellId then
            return true
          end
        end
      end
    end
  end

  return false
end

---------------------------------------------------------------
-- Spell name/rank helper (kept compatible)
---------------------------------------------------------------
local function _GetSpellNameRank(spellId)
  spellId = tonumber(spellId) or 0

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
-- Runtime aura state (OURS ONLY, confirmed via pending+ADDED)
---------------------------------------------------------------
local AuraStateByGuid = {} -- [guid] = { [spellId] = { appliedAt, fullDur, cp, isDebuff } }

local function _GetAuraBucketForGuid(guid, create)
  if not guid or guid == "" then
    return nil
  end
  local t = AuraStateByGuid[guid]
  if not t and create then
    t = {}
    AuraStateByGuid[guid] = t
  end
  return t
end

---------------------------------------------------------------
-- Special-cases:
---------------------------------------------------------------

local _IsPlayerShaman = false
local _MoltenBlastSpellIdCache = {} -- [spellId] = true/false

-- Druid/Rogue talent caches (set on login / entering world / learned spell in tab)
_IsPlayerDruid = false
_IsPlayerRogue = false
local _CarnageRank = 0             -- druid: >0 enables Carnage proc logic
local _TasteForBloodRank = 0       -- rogue: 0..3, adds +2s per point to manual Rupture
local _ImprovedBladeTacticsRank = 0 -- rogue: 0..3, +15/30/45% to Slice and Dice manual duration

-- Druid Carnage proc detection
local _FerociousBiteSpellIdCache = {} -- [spellId] = true/false
local _CarnageWatch = nil            -- { expiresAt, targetGuid, sawZero, lastCP }

-- Cache Flame Shock tracked ids as a numeric array to avoid pairs/tonumber work on every Molten Blast
local _FlameShockSpellIdsList = nil -- array of spellIds, or nil if not tracked

-- Cache Rip/Rake tracked ids (used by Carnage refresh)
local _RipSpellIdsList = nil  -- array
local _RakeSpellIdsList = nil -- array

local function _IsBadGuid(g)
  return (not g) or g == "" or g == "0x000000000" or g == "0x0000000000000000"
end

local function _TryRefreshFlameShockOnTargetGuid(targetGuid, now)
  if _IsBadGuid(targetGuid) then
    return
  end

  -- Require that this guid is actually the players current target so player can verify aura presence cheaply.
  local curTargetGuid = _GetUnitGuidSafe("target")
  if _IsBadGuid(curTargetGuid) or curTargetGuid ~= targetGuid then
    return
  end

  if type(_FlameShockSpellIdsList) ~= "table" then
    return
  end

  local bucket = AuraStateByGuid[targetGuid]
  if type(bucket) ~= "table" then
    return
  end

  local i = 1
  while _FlameShockSpellIdsList[i] do
    local sid = _FlameShockSpellIdsList[i]
    -- Flame Shock must be present right now
    if _AuraHasSpellId("target", sid, true) then
      local a = bucket[sid]
      if a and a.appliedAt and a.fullDur and a.fullDur > 0 then
        local age = now - (a.appliedAt or now)
        if age >= 0 and age <= (a.fullDur + 0.25) then
          a.appliedAt = now
          a.lastSeen = now
        end
      end
    else
      bucket[sid] = nil
    end
    i = i + 1
  end
end

---------------------------------------------------------------
-- Druid/Rogue talents + Druid Carnage refresh helpers
---------------------------------------------------------------
local function _UpdateTalentCaches()
  _CarnageRank = 0
  _TasteForBloodRank = 0
  _ImprovedBladeTacticsRank = 0

  if not UnitClass then
    _IsPlayerDruid = false
    _IsPlayerRogue = false
    return
  end

  local _, cls = UnitClass("player")
  cls = cls and string.upper(cls) or ""
  _IsPlayerDruid = (cls == "DRUID")
  _IsPlayerRogue = (cls == "ROGUE")

  if (not _IsPlayerDruid) and (not _IsPlayerRogue) then
    return
  end

  if (not GetTalentInfo) or (not GetNumTalentTabs) or (not GetNumTalents) then
    return
  end

  local needCarnage = _IsPlayerDruid
  local needTaste = _IsPlayerRogue
  local needBlade = _IsPlayerRogue

  local numTabs = tonumber(GetNumTalentTabs()) or 0
  local tab
  for tab = 1, numTabs do
    local numTal = tonumber(GetNumTalents(tab)) or 0
    local i
    for i = 1, numTal do
      local name, _, _, _, rank = GetTalentInfo(tab, i)
      if name and name ~= "" then
        local norm = _NormSpellName(name)
        if needCarnage and norm == "carnage" then
          _CarnageRank = tonumber(rank) or 0
          needCarnage = false
        end
        if needTaste and norm == "taste for blood" then
          _TasteForBloodRank = tonumber(rank) or 0
          needTaste = false
        end
        if needBlade and norm == "improved blade tactics" then
          _ImprovedBladeTacticsRank = tonumber(rank) or 0
          needBlade = false
        end
        if (not needCarnage) and (not needTaste) and (not needBlade) then
          return
        end
      end
    end
  end
end

local function _TryRefreshRipRakeOnTargetGuid(targetGuid, now)
  if _IsBadGuid(targetGuid) then
    return
  end

  -- Require current target match so player can verify aura presence cheaply.
  local curTargetGuid = _GetUnitGuidSafe("target")
  if _IsBadGuid(curTargetGuid) or curTargetGuid ~= targetGuid then
    return
  end

  if (type(_RipSpellIdsList) ~= "table") and (type(_RakeSpellIdsList) ~= "table") then
    return
  end

  local bucket = AuraStateByGuid[targetGuid]
  if type(bucket) ~= "table" then
    return
  end

  local function refreshList(list)
    if type(list) ~= "table" then
      return
    end
    local i = 1
    while list[i] do
      local sid = list[i]
      -- Rip/Rake must be present right now
      if _AuraHasSpellId("target", sid, true) then
        local a = bucket[sid]
        if a and a.appliedAt and a.fullDur and a.fullDur > 0 then
          local age = now - (a.appliedAt or now)
          if age >= 0 and age <= (a.fullDur + 0.25) then
            a.appliedAt = now
            a.lastSeen = now
          end
        end
      else
        bucket[sid] = nil
      end
      i = i + 1
    end
  end

  refreshList(_RipSpellIdsList)
  refreshList(_RakeSpellIdsList)
end

function DoiteTrack:_OnUnitComboPoints()
  if arg1 and arg1 ~= "player" then
    return
  end
  if not _CarnageWatch then
    return
  end

  local now = GetTime and GetTime() or 0
  if now > (_CarnageWatch.expiresAt or 0) then
    _CarnageWatch = nil
    return
  end

  local cpNow = _GetComboPointsSafe()

  -- player only accept a gain that happens after player observed CP at 0.
  if not _CarnageWatch.sawZero then
    if cpNow == 0 then
      _CarnageWatch.sawZero = true
      _CarnageWatch.lastCP = 0
    else
      _CarnageWatch.lastCP = cpNow
    end
    return
  end

  if (_CarnageWatch.lastCP or 0) == 0 and cpNow > 0 then
    _TryRefreshRipRakeOnTargetGuid(_CarnageWatch.targetGuid, now)
    _CarnageWatch = nil
    return
  end

  _CarnageWatch.lastCP = cpNow
end

function DoiteTrack:_OnLearnedSpellInTab()
  -- Talents may have changed; re-scan and update event needs.
  _UpdateTalentCaches()
  self:_RecomputeEventNeeds()
  self:_ApplyEventRegistration()
end

---------------------------------------------------------------
-- Pending apply cache (global, to avoid upvalue blowups elsewhere)
-- Structure (avoids string key churn):
--   pend[spellId][targetGuid] = { t=now, dur=secRounded or nil, cp=cp or 0, kind="Buff"/"Debuff", nameNorm="rip" }
---------------------------------------------------------------

local function _GetPendingTable()
  local p = _G["DoiteTrack_NPPending"]
  if not p then
    p = {}
    _G["DoiteTrack_NPPending"] = p
  end
  return p
end

---------------------------------------------------------------
-- NP debug + dedupe printing
---------------------------------------------------------------
_G["DoiteTrack_SetNPDebug"] = function(on)
  _G["DoiteTrack_NPDebug"] = (on and true or false)
  if _G["DoiteTrack_NPDebug"] then
    _Print("|cff6FA8DCDoiteAuras:|r Debug |cffffff00ON|r")
  else
    _Print("|cff6FA8DCDoiteAuras:|r Debug |cffffff00OFF|r")
  end
end

local function _NP_DedupAllow(spellId, targetGuid, durationMs, cpVal, manualSec)
  local d = _G["DoiteTrack_NPDedup"]
  if not d then
    d = {}
    _G["DoiteTrack_NPDedup"] = d
  end

  local now = GetTime and GetTime() or 0
  local k =
    tostring(event or "AURA_CAST") .. ":" ..
    tostring(tonumber(spellId) or 0) .. ":" ..
    tostring(targetGuid or "") .. ":" ..
    tostring(tonumber(durationMs) or 0) .. ":" ..
    tostring(tonumber(cpVal) or 0) .. ":" ..
    tostring(tonumber(manualSec) or 0)

  local last = d[k]
  if last and (now - last) < 0.15 then
    return false
  end
  d[k] = now
  return true
end

local function _NP_PrintLine(spellId, spellName, spellNorm, targetGuid, durationMs, tracked, cpVal, manualSec)
  if not _G["DoiteTrack_NPDebug"] then
    return
  end
  if not _NP_DedupAllow(spellId, targetGuid, durationMs, cpVal, manualSec) then
    return
  end

  local tag = tracked and "tracked" or "untracked"
  local en = tostring(event or "AURA_CAST")

  local cpStr = "no"
  if type(cpVal) == "number" and cpVal > 0 then
    cpStr = "cp=" .. tostring(cpVal)
  end

  local manualStr = "no"
  if type(manualSec) == "number" and manualSec > 0 then
    manualStr = "manual=" .. tostring(manualSec)
  end

  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
      "%s [%s] sid=%d name=%s norm=%s tgt=%s durMs=%d %s %s",
      en,
      tag,
      tonumber(spellId) or 0,
      tostring(spellName or ""),
      tostring(spellNorm or ""),
      tostring(targetGuid or ""),
      tonumber(durationMs) or 0,
      cpStr,
      manualStr
    ))
  end
end

---------------------------------------------------------------
-- Baseline duration getters (NP DB + manual overrides)
---------------------------------------------------------------
local function _WarnMissingManualDuration(spellName, spellRank, spellId)
  if not DEFAULT_CHAT_FRAME or not DEFAULT_CHAT_FRAME.AddMessage then
    return
  end

  local blue = "|cff6FA8DC" -- #6FA8DC = DoiteAuras color - personal note
  local yellow = "|cffffff00"
  local white = "|cffffffff"
  local reset = "|r"

  local n = tostring(spellName or "")
  local r = tostring(spellRank or "")
  local label = n
  if r ~= "" then
    label = label .. " " .. r
  end

  DEFAULT_CHAT_FRAME:AddMessage(
    blue .. "[DoiteAuras]:" .. reset .. " " ..
    yellow .. label .. reset .. " " ..
    white .. "SpellID " .. reset .. " " ..
    yellow .. tostring(tonumber(spellId) or 0) .. reset .. " " .. reset ..
    white .. "does not have a duration recorded, and does not exist in the manual table. Please report to Doite." .. reset
  )
end

local function _GetManualDurationBySpellId(spellId, cp)
  local v = ManualDurationBySpellId[spellId]
  if type(v) == "number" then
    if v > 0 then
      return v
    end
    return nil
  end

  if type(v) == "table" then
    if cp and cp > 0 then
      local sec = v[cp]
      if type(sec) == "number" and sec > 0 then
        return sec
      end
    end
    return nil
  end

  return nil
end

local function _CommitNPDuration(spellId, cp, secRounded, name, rank, durationMs)
  if not spellId or spellId <= 0 then
    return
  end
  if not secRounded or secRounded <= 0 then
    return
  end

  local db = _GetDB()

  if cp and cp > 0 then
    db.npDurationsCP[spellId] = db.npDurationsCP[spellId] or {}
    db.npDurationsCP[spellId][cp] = secRounded
  else
    db.npDurations[spellId] = secRounded
  end

  local meta = db.npDurationsMeta[spellId]
  if not meta then
    meta = { samples = 0 }
    db.npDurationsMeta[spellId] = meta
  end

  meta.samples = (meta.samples or 0) + 1
  meta.lastMs = tonumber(durationMs) or nil
  meta.lastAt = (GetTime and GetTime() or 0)
  if name and name ~= "" then
    meta.name = name
  end
  if rank and rank ~= "" then
    meta.rank = rank
  end
end

function DoiteTrack:_RecomputeEventNeeds()
  -- NP events: only needed if any entry is onlyMine (timers are ours-only)
  local hasMine = false
  local _, e

  for _, e in pairs(TrackedBySpellId) do
    if e and e.onlyMine == true then
      hasMine = true
      break
    end
  end

  if not hasMine then
    for _, e in pairs(TrackedByNameNorm) do
      if e and e.onlyMine == true then
        hasMine = true
        break
      end
    end
  end

  self._hasTracked = hasMine

  -- Need SPELL_CAST_EVENT if:
  --  a) Any CP-based manual duration exists (for CP snapshot)
  --  b) Shaman Molten Blast refresh is relevant
  --  c) Druid Carnage proc detection is active (Ferocious Bite -> CP gain window)
  local needCP = false
  if _IsPlayerDruid or _IsPlayerRogue then
    local _, v
    for _, v in pairs(ManualDurationBySpellId) do
      if type(v) == "table" then
        needCP = true
        break
      end
    end
  end

  local needMB = false
  if _IsPlayerShaman then
    local fs = TrackedByNameNorm["flame shock"]
    if fs and fs.onlyMine == true and fs.kind == "Debuff" then
      needMB = true
    end
  end

  local needCarnage = false
  if _IsPlayerDruid and _CarnageRank and _CarnageRank > 0 then
    if type(_RipSpellIdsList) == "table" or type(_RakeSpellIdsList) == "table" then
      needCarnage = true
    end
  end

  ----------------------------------------------------------------
  -- Paladin SC: Judgement tracking (Seal -> Judgement debuff)
  -- Only engage if player is Paladin AND is tracking any Judgement debuff (onlyMine).
  -- Runtime "mode" (seal seen / judgement pending/active) lives in _G["DoiteTrack_PalJ"].
  ----------------------------------------------------------------
  local palTracked = false
  if _G["DoiteTrack_IsPaladin"] == true then
    local e

    e = TrackedByNameNorm["judgement of the crusader"]
    if e and e.onlyMine == true and e.kind == "Debuff" then
      palTracked = true
    end

    if not palTracked then
      e = TrackedByNameNorm["judgement of light"]
      if e and e.onlyMine == true and e.kind == "Debuff" then
        palTracked = true
      end
    end

    if not palTracked then
      e = TrackedByNameNorm["judgement of wisdom"]
      if e and e.onlyMine == true and e.kind == "Debuff" then
        palTracked = true
      end
    end

    if not palTracked then
      e = TrackedByNameNorm["judgement of justice"]
      if e and e.onlyMine == true and e.kind == "Debuff" then
        palTracked = true
      end
    end
  end

  _G["DoiteTrack_PalJ_Tracked"] = (palTracked and true or false)

  local pj = nil
  local palMode = false
  local palActive = false

  if palTracked then
    pj = _G["DoiteTrack_PalJ"]
    if type(pj) ~= "table" then
      pj = {}
      _G["DoiteTrack_PalJ"] = pj
    end

    -- mode means: a relevant seal seen OR a judgement pending/active
    palMode = (pj.mode == true) and true or false

    -- active means: a confirmed judgement on a target to refresh on hits
    if pj.activeTargetGuid and pj.activeTargetGuid ~= "" and pj.activeSpellId and (tonumber(pj.activeSpellId) or 0) > 0 and pj.activeDur and pj.activeDur > 0 then
      palActive = true
    end
  end

  -- SPELL_CAST_EVENT is needed for:
  --  a) CP snapshot for manual CP tables
  --  b) Druid Carnage proc detection (Ferocious Bite watch)
  --  c) Paladin Judgement cast correlation (only while palMode)
  self._needSpellCastEvent = (needCP or needCarnage or palMode)

  -- SPELL_DAMAGE_EVENT_SELF is needed for:
  --  Shaman Molten Blast -> Flame Shock refresh (on hit/land, not cast start)
  --  Paladin Judgement refresh on specific damaging spells (only while palActive)
  self._needSpellDamageEventSelf = ((needMB or palActive) and true or false)

  -- AUTO_ATTACK_SELF is only needed for Paladin judgement refresh (only while palActive)
  self._needAutoAttackSelf = (palActive and true or false)

  -- Removed-aura events only needed for Paladin judgement stop logic / seal cancellation (only while palMode)
  self._needAuraRemoved = (palMode and true or false)

  self._needUnitComboPoints = needCarnage

  -- Only register talent-change event if the API exists and class cares.
  self._needTalentEvent = (_IsPlayerDruid or _IsPlayerRogue) and true or false
end

---------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------
function DoiteTrack:_TryHookDoiteAurasRefreshIcons()
  if _G["DoiteTrack_Orig_DoiteAuras_RefreshIcons"] then
    return
  end

  local f = _G["DoiteAuras_RefreshIcons"]
  if type(f) ~= "function" then
    return
  end

  _G["DoiteTrack_Orig_DoiteAuras_RefreshIcons"] = f
  _G["DoiteAuras_RefreshIcons"] = _G["DoiteTrack_DoiteAuras_RefreshIcons_Hook"]
end

function DoiteTrack:_OnDoiteAurasConfigChanged()
  -- Full rescan of DoiteAuras config -> rebuild tracked maps + cached lists + event needs
  self:RebuildWatchList()

  -- Rebuild Flame Shock spellId list cache (used by Molten Blast special case)
  _FlameShockSpellIdsList = nil
  do
    local fs = TrackedByNameNorm["flame shock"]
    if fs and fs.onlyMine == true and fs.kind == "Debuff" and type(fs.spellIds) == "table" then
      local list = {}
      local n = 0
      local sid
      for sid in pairs(fs.spellIds) do
        sid = tonumber(sid) or 0
        if sid > 0 then
          n = n + 1
          list[n] = sid
        end
      end
      if n > 0 then
        _FlameShockSpellIdsList = list
      end
    end
  end

  -- Rebuild Rip/Rake spellId lists (used by Carnage refresh)
  _RipSpellIdsList = nil
  do
    local e = TrackedByNameNorm["rip"]
    if e and e.onlyMine == true and e.kind == "Debuff" and type(e.spellIds) == "table" then
      local list = {}
      local n = 0
      local sid
      for sid in pairs(e.spellIds) do
        sid = tonumber(sid) or 0
        if sid > 0 then
          n = n + 1
          list[n] = sid
        end
      end
      if n > 0 then
        _RipSpellIdsList = list
      end
    end
  end

  _RakeSpellIdsList = nil
  do
    local e = TrackedByNameNorm["rake"]
    if e and e.onlyMine == true and e.kind == "Debuff" and type(e.spellIds) == "table" then
      local list = {}
      local n = 0
      local sid
      for sid in pairs(e.spellIds) do
        sid = tonumber(sid) or 0
        if sid > 0 then
          n = n + 1
          list[n] = sid
        end
      end
      if n > 0 then
        _RakeSpellIdsList = list
      end
    end
  end

  self:_RecomputeEventNeeds()
  self:_ApplyEventRegistration()
end

function DoiteTrack:_OnPlayerLogin()
  -- Init once, but allow re-scan on PLAYER_ENTERING_WORLD (talents / flags).
  local firstInit = (not self._didInit)

  if firstInit then
    self._didInit = true

    UnitExists = _G.UnitExists
    GetUnitField = _G.GetUnitField
    GetSpellNameAndRankForId = _G.GetSpellNameAndRankForId
    UnitClass = _G.UnitClass
    GetComboPoints = _G.GetComboPoints

    -- talents
    GetTalentInfo = _G.GetTalentInfo
    GetNumTalentTabs = _G.GetNumTalentTabs
    GetNumTalents = _G.GetNumTalents

    -- Nampower: enable AuraCast events
    local SetCVar = _G.SetCVar
    if SetCVar then
      pcall(SetCVar, "NP_EnableAuraCastEvents", "1")
    end

    _playerGUID_cached = nil
    _GetPlayerGUID()

    -- Cache shaman flag for Molten Blast -> Flame Shock refresh
    _IsPlayerShaman = false

    -- Paladin flag for Judgement special-case
    _G["DoiteTrack_IsPaladin"] = false

    if UnitClass then
      local _, cls = UnitClass("player")
      cls = cls and string.upper(cls) or ""
      if cls == "SHAMAN" then
        _IsPlayerShaman = true
      end
      if cls == "PALADIN" then
        _G["DoiteTrack_IsPaladin"] = true
      end
    end

    self:RebuildWatchList()

    -- Rebuild Flame Shock spellId list cache (used by Molten Blast special case)
    _FlameShockSpellIdsList = nil
    do
      local fs = TrackedByNameNorm["flame shock"]
      if fs and fs.onlyMine == true and fs.kind == "Debuff" and type(fs.spellIds) == "table" then
        local list = {}
        local n = 0
        local sid
        for sid in pairs(fs.spellIds) do
          sid = tonumber(sid) or 0
          if sid > 0 then
            n = n + 1
            list[n] = sid
          end
        end
        if n > 0 then
          _FlameShockSpellIdsList = list
        end
      end
    end

    -- Rebuild Rip/Rake spellId lists (used by Carnage refresh)
    _RipSpellIdsList = nil
    do
      local e = TrackedByNameNorm["rip"]
      if e and e.onlyMine == true and e.kind == "Debuff" and type(e.spellIds) == "table" then
        local list = {}
        local n = 0
        local sid
        for sid in pairs(e.spellIds) do
          sid = tonumber(sid) or 0
          if sid > 0 then
            n = n + 1
            list[n] = sid
          end
        end
        if n > 0 then
          _RipSpellIdsList = list
        end
      end
    end

    _RakeSpellIdsList = nil
    do
      local e = TrackedByNameNorm["rake"]
      if e and e.onlyMine == true and e.kind == "Debuff" and type(e.spellIds) == "table" then
        local list = {}
        local n = 0
        local sid
        for sid in pairs(e.spellIds) do
          sid = tonumber(sid) or 0
          if sid > 0 then
            n = n + 1
            list[n] = sid
          end
        end
        if n > 0 then
          _RakeSpellIdsList = list
        end
      end
    end
  end

  -- Always refresh talent caches on LOGIN + ENTERING_WORLD (cheap; no polling).
  _UpdateTalentCaches()

  -- Recompute event needs after watchlist/talent refresh
  self:_RecomputeEventNeeds()
  self:_ApplyEventRegistration()
  self:_TryHookDoiteAurasRefreshIcons()
end

-- SPELL_DAMAGE_EVENT_SELF
-- args (per Nampower guide):
--  arg1=targetGuid, arg2=casterGuid, arg3=spellId, arg4=amount,
--  arg5=mitigationStr "absorb,block,resist", arg6=hitInfo, arg7=spellSchool, arg8=effectAuraStr
function DoiteTrack:_OnSpellDamageEventSelf()
  ----------------------------------------------------------------
  -- Shaman SC: Molten Blast -> refresh Flame Shock (existing logic)
  ----------------------------------------------------------------
  if _IsPlayerShaman then
    -- Guard: only run if Flame Shock is tracked (onlyMine debuff)
    if type(_FlameShockSpellIdsList) ~= "table" then
      return
    end

    local targetGuid = arg1
    local casterGuid = arg2
    local spellId = tonumber(arg3) or 0

    if spellId <= 0 then
      return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid or not casterGuid or casterGuid == "" or casterGuid ~= pGuid then
      return
    end

    -- Identify Molten Blast by normalized spell name (rank-agnostic)
    local isMB = _MoltenBlastSpellIdCache[spellId]
    if isMB == nil then
      local n = _GetSpellNameRank(spellId)
      local norm = _NormSpellName(n)
      isMB = (norm == "molten blast") and true or false
      _MoltenBlastSpellIdCache[spellId] = isMB
    end

    if not isMB then
      return
    end

    -- Target GUID sanity
    if _IsBadGuid(targetGuid) then
      targetGuid = _GetUnitGuidSafe("target")
    end
    if _IsBadGuid(targetGuid) then
      return
    end

    -- Guard: only run during Flame Shock that is the players
    local bucket = AuraStateByGuid[targetGuid]
    if type(bucket) ~= "table" then
      return
    end

    -- Now refresh (this function also requires current target guid match + aura presence)
    local now = GetTime and GetTime() or 0
    _TryRefreshFlameShockOnTargetGuid(targetGuid, now)
    return
  end

  ----------------------------------------------------------------
  -- Paladin SC: refresh active Judgement on (Crusader Strike / Holy Strike)
  ----------------------------------------------------------------
  local pj = _G["DoiteTrack_PalJ"]
  if type(pj) ~= "table" then
    return
  end

  local tGuid = pj.activeTargetGuid
  local jSid = tonumber(pj.activeSpellId) or 0
  local dur = pj.activeDur

  if not tGuid or tGuid == "" or jSid <= 0 or not dur or dur <= 0 then
    return
  end

  local targetGuid = arg1
  local casterGuid = arg2
  local spellId = tonumber(arg3) or 0
  local amount = tonumber(arg4) or 0

  if amount <= 0 or spellId <= 0 then
    return
  end

  local pGuid = _GetPlayerGUID()
  if not pGuid or not casterGuid or casterGuid == "" or casterGuid ~= pGuid then
    return
  end

  if not targetGuid or targetGuid == "" or targetGuid ~= tGuid then
    return
  end

  -- Identify allowed refresh spells by normalized name
  local cache = _G["DoiteTrack_PalJ_HitSpellCache"]
  if type(cache) ~= "table" then
    cache = {}
    _G["DoiteTrack_PalJ_HitSpellCache"] = cache
  end

  local ok = cache[spellId]
  if ok == nil then
    local n = _GetSpellNameRank(spellId)
    local norm = _NormSpellName(n)
    ok = ((norm == "crusader strike") or (norm == "holy strike")) and true or false
    cache[spellId] = ok
  end

  if not ok then
    return
  end

  local now = GetTime and GetTime() or 0
  local bucket = _GetAuraBucketForGuid(tGuid, true)
  if not bucket then
    return
  end

  local a = bucket[jSid]
  if not a then
    a = {}
    bucket[jSid] = a
  end

  a.appliedAt = now
  a.lastSeen = now
  a.fullDur = dur
  a.cp = 0
  a.isDebuff = true
end

function DoiteTrack:_OnAutoAttackSelf()
  local pj = _G["DoiteTrack_PalJ"]
  if type(pj) ~= "table" then
    return
  end

  local tGuid = pj.activeTargetGuid
  local sid = tonumber(pj.activeSpellId) or 0
  local dur = pj.activeDur

  if not tGuid or tGuid == "" or sid <= 0 or not dur or dur <= 0 then
    return
  end

  local attackerGuid = arg1
  local targetGuid = arg2
  local totalDamage = tonumber(arg3) or 0

  if totalDamage <= 0 then
    return
  end

  local pGuid = _GetPlayerGUID()
  if not pGuid or not attackerGuid or attackerGuid == "" or attackerGuid ~= pGuid then
    return
  end

  if not targetGuid or targetGuid == "" or targetGuid ~= tGuid then
    return
  end

  local now = GetTime and GetTime() or 0
  local bucket = _GetAuraBucketForGuid(tGuid, true)
  if not bucket then
    return
  end

  local a = bucket[sid]
  if not a then
    a = {}
    bucket[sid] = a
  end

  a.appliedAt = now
  a.lastSeen = now
  a.fullDur = dur
  a.cp = 0
  a.isDebuff = true
end

-- SPELL_CAST_EVENT
function DoiteTrack:_OnSpellCastEvent()
  local success = arg1
  local spellId = tonumber(arg2) or 0
  local targetGuid = arg4

  if success ~= 1 or spellId <= 0 then
    return
  end

  local pGuid = _GetPlayerGUID()
  if not pGuid then
    return
  end

  -- Druid SC: Carnage proc detection (Ferocious Bite -> CP gain within 0.5s refreshes Rip/Rake on that target)
  if _IsPlayerDruid and _CarnageRank and _CarnageRank > 0 then
    if type(_RipSpellIdsList) == "table" or type(_RakeSpellIdsList) == "table" then
      local isFB = _FerociousBiteSpellIdCache[spellId]
      if isFB == nil then
        local n = _GetSpellNameRank(spellId)
        local norm = _NormSpellName(n)
        isFB = (norm == "ferocious bite") and true or false
        _FerociousBiteSpellIdCache[spellId] = isFB
      end

      if isFB then
        local now = GetTime and GetTime() or 0

        -- Ferocious Bite is harmful; prefer actual target guid
        if _IsBadGuid(targetGuid) then
          targetGuid = _GetUnitGuidSafe("target")
        end

        if not _IsBadGuid(targetGuid) then
          local cpNow = _GetComboPointsSafe()
          _CarnageWatch = {
            expiresAt = now + 0.5,
            targetGuid = targetGuid,
            sawZero = (cpNow == 0) and true or false,
            lastCP = cpNow,
          }
        end
      end
    end
  end

  ----------------------------------------------------------------
  -- Paladin SC: correlate Judgement cast while a tracked Seal is active
  -- do NOT rely on AURA_CAST_ON_OTHER for the resulting debuff.
  -- only arm "pending" here; confirmation happens on BUFF/DEBUFF_ADDED_OTHER.
  ----------------------------------------------------------------
  if _G["DoiteTrack_IsPaladin"] == true and _G["DoiteTrack_PalJ_Tracked"] == true then
    local pj = _G["DoiteTrack_PalJ"]
    if type(pj) == "table" and pj.mode == true and pj.sealToken and pj.sealToken ~= "" then
      local isJ = nil
      do
        local n = _GetSpellNameRank(spellId)
        local norm = _NormSpellName(n)
        if norm == "judgement" or norm == "judgment" then
          isJ = true
        else
          isJ = false
        end
      end

      if isJ then
        local now = GetTime and GetTime() or 0

        if _IsBadGuid(targetGuid) then
          targetGuid = _GetUnitGuidSafe("target")
        end
        if not _IsBadGuid(targetGuid) then
          pj.pendingTargetGuid = targetGuid
          pj.pendingToken = pj.sealToken
          pj.pendingExpiresAt = now + 1.75
        end
      end
    end
  end

  -- Only care about spells tracked (onlyMine) for CP snapshot behavior
  local entry = TrackedBySpellId[spellId]
  if (not entry) then
    local n = _GetSpellNameRank(spellId)
    local nn = _NormSpellName(n)
    if nn then
      entry = TrackedByNameNorm[nn]
    end
  end

  if not entry or entry.onlyMine ~= true then
    return
  end

  -- Resolve target: self-only -> player, else must be real target
  local selfOnly = (entry.trackSelf and (not entry.trackHelp) and (not entry.trackHarm))
  if selfOnly then
    targetGuid = pGuid
  else
    if (not targetGuid) or targetGuid == "" or targetGuid == "0x000000000" or targetGuid == "0x0000000000000000" then
      local tg = _GetUnitGuidSafe("target")
      if not tg or tg == "" then
        return
      end
      targetGuid = tg
    end
  end

  -- Only snapshot CP if this spellId has a CP-table manual entry
  if type(ManualDurationBySpellId[spellId]) ~= "table" then
    return
  end

  local name, rank = _GetSpellNameRank(spellId)
  local norm = _NormSpellName(name)
  if not norm then
    return
  end


  local cp = 0
  if _PlayerUsesComboPoints() then
    cp = _GetComboPointsSafe()
  end

  local pend = _GetPendingTable()
  pend[spellId] = pend[spellId] or {}
  local t = pend[spellId]

  t[targetGuid] = t[targetGuid] or {}
  local p = t[targetGuid]

  p.confirmAt = nil
  p.dur = nil

  p.t = (GetTime and GetTime() or 0)
  p.cp = cp or 0
  p.kind = entry.kind
  p.nameNorm = norm
end

-- Combined handler:
--  AURA_CAST_ON_SELF/OTHER: capture durationMs + set pending.dur
--  BUFF/DEBUFF_ADDED_SELF/OTHER: confirm apply -> start timer if pending exists
function DoiteTrack:_OnAuraNPEvent()
  ----------------------------------------------------------------
  -- 0) Paladin SC: stop logic on REMOVED events (only registered while palMode)
  -- Handles both debuff-slot and buff-slot (16 cap spill) removals.
  ----------------------------------------------------------------
  if event == "BUFF_REMOVED_SELF" or event == "BUFF_REMOVED_OTHER" or event == "DEBUFF_REMOVED_OTHER" then
    if _G["DoiteTrack_IsPaladin"] == true and _G["DoiteTrack_PalJ_Tracked"] == true then
      local pj = _G["DoiteTrack_PalJ"]
      if type(pj) == "table" then
        local guid = arg1
        local spellId = tonumber(arg3) or 0
        if spellId <= 0 or not guid or guid == "" then
          return
        end

        local now = GetTime and GetTime() or 0

        -- Seal removed from player: clear seal token/spellId; drop mode if nothing pending/active.
        if event == "BUFF_REMOVED_SELF" then
          local pGuid = _GetPlayerGUID()
          if pGuid and guid == pGuid then
            local sealSid = tonumber(pj.sealSpellId) or 0
            if sealSid > 0 and spellId == sealSid then
              pj.sealSpellId = nil
              pj.sealToken = nil

              -- If no active judgement and no valid pending, disable mode.
              local hasActive = false
              if pj.activeTargetGuid and pj.activeTargetGuid ~= "" and pj.activeSpellId and (tonumber(pj.activeSpellId) or 0) > 0 and pj.activeDur and pj.activeDur > 0 then
                hasActive = true
              end

              local hasPending = false
              if pj.pendingTargetGuid and pj.pendingTargetGuid ~= "" and pj.pendingToken and pj.pendingToken ~= "" then
                if (pj.pendingExpiresAt or 0) >= now then
                  hasPending = true
                else
                  pj.pendingTargetGuid = nil
                  pj.pendingToken = nil
                  pj.pendingExpiresAt = nil
                end
              end

              if (not hasActive) and (not hasPending) then
                pj.mode = false
              else
                pj.mode = true
              end

              self:_RecomputeEventNeeds()
              self:_ApplyEventRegistration()
            end
          end
          return
        end

        -- Judgement removed from target: stop active tracking (buff-slot or debuff-slot).
        do
          local aGuid = pj.activeTargetGuid
          local aSid = tonumber(pj.activeSpellId) or 0
          if aGuid and aGuid ~= "" and aSid > 0 and guid == aGuid and spellId == aSid then
            local bucket0 = AuraStateByGuid[aGuid]
            if bucket0 then
              bucket0[aSid] = nil
            end

            pj.activeTargetGuid = nil
            pj.activeSpellId = nil
            pj.activeDur = nil

            -- If no seal and no pending, fully disable mode.
            local hasPending = false
            if pj.pendingTargetGuid and pj.pendingTargetGuid ~= "" and pj.pendingToken and pj.pendingToken ~= "" then
              if (pj.pendingExpiresAt or 0) >= now then
                hasPending = true
              else
                pj.pendingTargetGuid = nil
                pj.pendingToken = nil
                pj.pendingExpiresAt = nil
              end
            end

            if (not pj.sealToken or pj.sealToken == "") and (not hasPending) then
              pj.mode = false
            else
              pj.mode = true
            end

            self:_RecomputeEventNeeds()
            self:_ApplyEventRegistration()
          end
        end
      end
    end
    return
  end

  ----------------------------------------------------------------
  -- 1) Apply confirm via BUFF/DEBUFF_ADDED_* (start timer)
  ----------------------------------------------------------------
  if event == "BUFF_ADDED_SELF" or event == "BUFF_ADDED_OTHER" or event == "DEBUFF_ADDED_SELF" or event == "DEBUFF_ADDED_OTHER" then
    local guid = arg1
    local spellId = tonumber(arg3) or 0

    if spellId <= 0 or not guid or guid == "" then
      return
    end

    local now = GetTime and GetTime() or 0

    ----------------------------------------------------------------
    -- Paladin SC: confirm Judgement apply (do NOT rely on AURA_CAST_ON_OTHER)
    -- Duration is hardcoded to 10 seconds for all tracked Judgements.
    -- Also supports buff-slot spillover (BUFF_ADDED_OTHER).
    ----------------------------------------------------------------
    if (event == "BUFF_ADDED_OTHER" or event == "DEBUFF_ADDED_OTHER") and _G["DoiteTrack_IsPaladin"] == true and _G["DoiteTrack_PalJ_Tracked"] == true then
      local pj = _G["DoiteTrack_PalJ"]
      if type(pj) == "table" and pj.pendingTargetGuid and pj.pendingTargetGuid ~= "" and pj.pendingToken and pj.pendingToken ~= "" then
        if pj.pendingTargetGuid == guid then
          if (pj.pendingExpiresAt or 0) < now then
            pj.pendingTargetGuid = nil
            pj.pendingToken = nil
            pj.pendingExpiresAt = nil
          else
            local n = _GetSpellNameRank(spellId)
            local norm = _NormSpellName(n)

            local match = false
            if norm then
              if pj.pendingToken == "crusader" then
                match = (norm == "judgement of the crusader")
              elseif pj.pendingToken == "light" then
                match = (norm == "judgement of light")
              elseif pj.pendingToken == "wisdom" then
                match = (norm == "judgement of wisdom")
              elseif pj.pendingToken == "justice" then
                match = (norm == "judgement of justice")
              end
            end

            if match then
              -- Ensure this spellId is wired into tracked maps if user tracked by name only.
              if not TrackedBySpellId[spellId] and norm then
                local byN = TrackedByNameNorm[norm]
                if byN and byN.onlyMine == true and byN.kind == "Debuff" then
                  byN.spellIds = byN.spellIds or {}
                  if not byN.spellIds[spellId] then
                    byN.spellIds[spellId] = true
                  end
                  TrackedBySpellId[spellId] = byN
                end
              end

              -- Clear any previously active judgement state
              do
                local oldT = pj.activeTargetGuid
                local oldS = tonumber(pj.activeSpellId) or 0
                if oldT and oldT ~= "" and oldS > 0 then
                  if oldT ~= guid or oldS ~= spellId then
                    local b0 = AuraStateByGuid[oldT]
                    if b0 then
                      b0[oldS] = nil
                    end
                  end
                end
              end

              pj.activeTargetGuid = guid
              pj.activeSpellId = spellId
              pj.activeDur = 10
              pj.mode = true

              pj.pendingTargetGuid = nil
              pj.pendingToken = nil
              pj.pendingExpiresAt = nil

              local bucket = _GetAuraBucketForGuid(guid, true)
              if bucket then
                local a = bucket[spellId]
                if not a then
                  a = {}
                  bucket[spellId] = a
                end
                a.appliedAt = now
                a.lastSeen = now
                a.fullDur = 10
                a.cp = 0
                a.isDebuff = true
              end

              self:_RecomputeEventNeeds()
              self:_ApplyEventRegistration()
              return
            end
          end
        end
      end
    end

    ----------------------------------------------------------------
    -- Normal (existing) confirm path for tracked onlyMine auras
    ----------------------------------------------------------------
    local entry = TrackedBySpellId[spellId]
    if not entry or entry.onlyMine ~= true then
      return
    end

    -- Allow confirm-first (refresh/order differences)
    local pend = _GetPendingTable()
    local t = pend[spellId]
    if not t then
      return
    end

    local p = t[guid]
    if not p then
      return
    end

    p.confirmAt = now
    p.kind = entry.kind
    p.nameNorm = p.nameNorm or entry.normName

    -- If player already have a duration from AURA_CAST, (re)arm timer now
    if p.dur and p.dur > 0 then
      local bucket = _GetAuraBucketForGuid(guid, true)
      if not bucket then
        t[guid] = nil
        return
      end

      local a = bucket[spellId]
      if not a then
        a = {}
        bucket[spellId] = a
      end

      a.appliedAt = now
      a.fullDur = p.dur
      a.cp = p.cp or 0
      a.isDebuff = (entry.kind == "Debuff")

      -- consume pending after successful arm
      t[guid] = nil
    end
    return
  end

  ----------------------------------------------------------------
  -- 2) AURA_CAST_ON_SELF/OTHER: capture durationMs + store baseline
  ----------------------------------------------------------------
  local spellId = tonumber(arg1) or 0
  local casterGuid = arg2
  local targetGuid = arg3
  local durationMs = tonumber(arg8) or 0

  if spellId <= 0 then
    return
  end

  local pGuid = _GetPlayerGUID()
  if not pGuid or not casterGuid or casterGuid == "" or casterGuid ~= pGuid then
    return
  end

  -- Derive name from spellId
  local spellName, spellRank = _GetSpellNameRank(spellId)
  local spellNameNorm = _NormSpellName(spellName)

  ----------------------------------------------------------------
  -- Paladin SC: detect relevant Seal application on SELF via AURA_CAST_ON_SELF
  -- This enables the Judgement correlation mode (SPELL_CAST_EVENT + removed events).
  ----------------------------------------------------------------
  if event == "AURA_CAST_ON_SELF" and _G["DoiteTrack_IsPaladin"] == true and _G["DoiteTrack_PalJ_Tracked"] == true then
    local token = nil
    if spellNameNorm == "seal of the crusader" then
      token = "crusader"
    elseif spellNameNorm == "seal of light" then
      token = "light"
    elseif spellNameNorm == "seal of wisdom" then
      token = "wisdom"
    elseif spellNameNorm == "seal of justice" then
      token = "justice"
    end

    if token then
      local pj = _G["DoiteTrack_PalJ"]
      if type(pj) ~= "table" then
        pj = {}
        _G["DoiteTrack_PalJ"] = pj
      end

      pj.mode = true
      pj.sealToken = token
      pj.sealSpellId = spellId

      self:_RecomputeEventNeeds()
      self:_ApplyEventRegistration()
    end
  end

  -- Resolve tracked entry (spellId first, then name)
  local entry = TrackedBySpellId[spellId]
  if (not entry) and spellNameNorm then
    local byN = TrackedByNameNorm[spellNameNorm]
    if byN and byN.onlyMine == true then
      entry = byN
      entry.spellIds = entry.spellIds or {}
      if not entry.spellIds[spellId] then
        entry.spellIds[spellId] = true
      end
      TrackedBySpellId[spellId] = entry

      -- Keep Flame Shock rank list cache in sync when player discover a new rank by name.
      if _IsPlayerShaman and spellNameNorm == "flame shock" and entry.kind == "Debuff" then
        if type(_FlameShockSpellIdsList) ~= "table" then
          _FlameShockSpellIdsList = {}
        end
        local i = 1
        while _FlameShockSpellIdsList[i] do
          if _FlameShockSpellIdsList[i] == spellId then
            i = nil
            break
          end
          i = i + 1
        end
        if i then
          _FlameShockSpellIdsList[i] = spellId
        end
      end
    end
  end

  -- Fix invalid/zero targetGuid *after* entry exists.
  if not targetGuid or targetGuid == "" or targetGuid == "0x000000000" or targetGuid == "0x0000000000000000" then
    local selfOnly = false

    if event == "AURA_CAST_ON_SELF" then
      selfOnly = true
    elseif entry then
      selfOnly = (entry.trackSelf and (not entry.trackHelp) and (not entry.trackHarm))
    end

    if selfOnly then
      targetGuid = pGuid
    else
      local tg = _GetUnitGuidSafe("target")
      if tg and tg ~= "" then
        targetGuid = tg
      else
        -- last resort fallback
        targetGuid = pGuid
      end
    end
  end

  -- Prepare pending early so debug can show cp/manual decisions
  if not entry or entry.onlyMine ~= true then
    -- still allow debug print, but do NOT create pending entries
    _NP_PrintLine(spellId, spellName, spellNameNorm, targetGuid, durationMs, false, 0, nil)
    return
  end

  local pend = _GetPendingTable()
  pend[spellId] = pend[spellId] or {}
  local t = pend[spellId]

  t[targetGuid] = t[targetGuid] or {}
  local p = t[targetGuid]

  p.t = (GetTime and GetTime() or 0)
  p.kind = entry.kind
  p.nameNorm = spellNameNorm or p.nameNorm

  local cp = p.cp or 0
  if (not cp) or cp < 0 then
    cp = 0
  end

  -- Manual duration:
  --  - Flat manual: only used when NP returns 0.
  --  - CP-table manual: override NP (NP is often wrong for CP-based durations)
  local manualSec = nil
  local mv = ManualDurationBySpellId[spellId]
  local isCPTbl = (type(mv) == "table")

  if isCPTbl then
    -- Prefer CP snapshotted earlier (p.cp). If missing, try current CP as last resort.
    if (not cp) or cp <= 0 then
      if _PlayerUsesComboPoints() then
        cp = _GetComboPointsSafe()
      else
        cp = 0
      end
      p.cp = cp
    end

    if cp and cp > 0 then
      manualSec = _GetManualDurationBySpellId(spellId, cp)

      -- Rogue SC: Taste for Blood increases Rupture duration by +2s per talent point.
      if manualSec and manualSec > 0 and _IsPlayerRogue and _TasteForBloodRank and _TasteForBloodRank > 0 then
        if spellNameNorm == "rupture" then
          manualSec = manualSec + (_TasteForBloodRank * 2)
        end
      end

      -- Rogue SC: Improved Blade Tactics increases Slice and Dice duration by +15%/+30%/+45%. Apply to the *manual* CP-table duration (same place as Rupture edge case).
      if manualSec and manualSec > 0 and _IsPlayerRogue and _ImprovedBladeTacticsRank and _ImprovedBladeTacticsRank > 0 then
        if spellNameNorm == "slice and dice" then
          local pct = _ImprovedBladeTacticsRank * 15
          manualSec = math.floor((manualSec * (100 + pct)) / 100 + 0.5)
        end
      end
    end
  elseif durationMs == 0 then
    -- Flat manual durations only when NP returns 0
    manualSec = _GetManualDurationBySpellId(spellId, 0)
  end

  -- Debug print ALWAYS (includes durMs 0 / -1), but mark tracked/untracked
  _NP_PrintLine(spellId, spellName, spellNameNorm, targetGuid, durationMs, (entry and entry.onlyMine == true), cp, manualSec)

  -- If NP reports durationMs == 0 and player have no manual duration, warn and stop.
  if durationMs == 0 and (not manualSec or manualSec <= 0) then
    _WarnMissingManualDuration(spellName, spellRank, spellId)
    return
  end

  -- onlyMine guard: only process tracked onlyMine auras beyond debug
  if not entry or entry.onlyMine ~= true then
    return
  end

  -- Determine duration in seconds:
  --  a) durationMs > 0 -> use it
  --  b) durationMs == 0 -> use manual CP-by-name or manual flat spellId
  --  c) durationMs < 0 -> infinite/none -> ignore
  local secRounded = nil

  -- pend/pk/cp already prepared above for debug
  p.kind = entry.kind
  p.nameNorm = spellNameNorm or p.nameNorm

  if durationMs > 0 then
    local sec = durationMs / 1000
    local r = math.floor(sec + 0.5)
    if r and r > 0 then
      secRounded = r
    end

    -- CP-table spells: override NP duration if a valid manualSec exist
    if isCPTbl and manualSec and manualSec > 0 then
      secRounded = manualSec
    end
  elseif durationMs == 0 then
    secRounded = manualSec
  else
    -- durationMs < 0 => infinite/no duration -> ignore
    secRounded = nil
  end

  if secRounded and secRounded > 0 then
    p.dur = secRounded
    _CommitNPDuration(spellId, (cp and cp > 0) and cp or 0, secRounded, spellName, spellRank, durationMs)

    local now = GetTime and GetTime() or 0

    ----------------------------------------------------------------
    -- Refresh fix:
    -- If player already have an active confirmed timer for this guid+spellId, treat AURA_CAST as a refresh and re-arm immediately.
    -- This covers cases where NP does NOT fire *_ADDED_* on re-apply.
    ----------------------------------------------------------------
    do
      local bucket0 = AuraStateByGuid[targetGuid]
      if bucket0 then
        local a0 = bucket0[spellId]
        if a0 and a0.appliedAt and a0.fullDur then
          local age = now - (a0.appliedAt or now)
          local full = a0.fullDur or 0

          -- Only refresh if the previous timer is still plausibly active.
          -- (prevents false refresh after silent drops / stale state)
          if full > 0 and age >= 0 and age <= (full + 0.25) then
            a0.appliedAt = now
            a0.lastSeen = now
            a0.fullDur = secRounded
            a0.cp = cp or 0
            a0.isDebuff = (entry.kind == "Debuff")

            t[targetGuid] = nil
            return
          end
        end
      end
    end

    -- If apply-confirm already happened (refresh/order differences), arm timer immediately
    if p.confirmAt then
      if (now - (p.confirmAt or now)) <= 2.5 then
        local bucket = _GetAuraBucketForGuid(targetGuid, true)
        if bucket then
          local a = bucket[spellId]
          if not a then
            a = {}
            bucket[spellId] = a
          end

          a.appliedAt = now
          a.fullDur = secRounded
          a.cp = cp or 0
          a.isDebuff = (entry.kind == "Debuff")

          t[targetGuid] = nil
        end
      end
    end
  end
end

---------------------------------------------------------------
-- Event frame wiring (minimal; no recording sessions)
---------------------------------------------------------------
function DoiteTrack_DoiteAuras_RefreshIcons_Hook()
  local dt = _G["DoiteTrack"]
  if dt and dt._OnDoiteAurasConfigChanged then
    dt:_OnDoiteAurasConfigChanged()
  end

  local orig = _G["DoiteTrack_Orig_DoiteAuras_RefreshIcons"]
  if orig then
    return orig()
  end
end

local TrackFrame = CreateFrame("Frame", "DoiteTrackFrame")
DoiteTrack._frame = TrackFrame

TrackFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

---------------------------------------------------------------
-- Delayed init helper (1s after PLAYER_ENTERING_WORLD)
---------------------------------------------------------------
function DoiteTrack:_ScheduleDelayedInit()
  local f = self._frame
  if not f then
    return
  end

  local now = GetTime and GetTime() or 0

  -- Always delay 1s on every ENTERING_WORLD (login/reload/zoning/instance)
  self._initDelayUntil = now + 1.0

  -- If already scheduled, just push the deadline out; don't stack OnUpdate handlers.
  if self._initDelayActive then
    return
  end

  self._initDelayActive = true

  local oldOnUpdate = f:GetScript("OnUpdate")

  f:SetScript("OnUpdate", function()
    local dt = _G["DoiteTrack"]
    if not dt or dt._initDelayActive ~= true then
      f:SetScript("OnUpdate", oldOnUpdate)
      return
    end

    local t = GetTime and GetTime() or 0
    if t < (dt._initDelayUntil or 0) then
      return
    end

    -- Fire once, then restore previous OnUpdate
    dt._initDelayActive = false
    dt._initDelayUntil = nil

    f:SetScript("OnUpdate", oldOnUpdate)

    -- Run the existing init logic (includes hook attempt + recompute + registration)
    dt:_OnPlayerLogin()
  end)
end

-- Other events will be registered conditionally after login based on watchlist + needs.
function DoiteTrack:_ApplyEventRegistration()
  local f = self._frame
  if not f then
    return
  end

  -- SPELL_CAST_EVENT: needed for:
  --  a) CP snapshot for manual CP tables
  --  b) Druid Carnage (Ferocious Bite watch)
  if self._needSpellCastEvent then
    f:RegisterEvent("SPELL_CAST_EVENT")
  else
    f:UnregisterEvent("SPELL_CAST_EVENT")
  end

  -- SPELL_DAMAGE_EVENT_SELF: needed for:
  --  Shaman Molten Blast -> Flame Shock refresh (on hit)
  if self._needSpellDamageEventSelf then
    f:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
  else
    f:UnregisterEvent("SPELL_DAMAGE_EVENT_SELF")
  end

  -- Druid Carnage: only listen to CP changes when Carnage is active/needed
  if self._needUnitComboPoints then
    f:RegisterEvent("PLAYER_COMBO_POINTS")
  else
    f:UnregisterEvent("PLAYER_COMBO_POINTS")
  end

  -- Druid/Rogue: re-scan talents when new spells/talents are learned
  if self._needTalentEvent then
    f:RegisterEvent("LEARNED_SPELL_IN_TAB")
  else
    f:UnregisterEvent("LEARNED_SPELL_IN_TAB")
  end

  -- AUTO_ATTACK_SELF: only needed for Paladin Judgement refresh
  if self._needAutoAttackSelf then
    f:RegisterEvent("AUTO_ATTACK_SELF")
    -- enable NP auto attack events (cheap global toggle; still guarded by registration)
    local SetCVar = _G.SetCVar
    if SetCVar then
      pcall(SetCVar, "NP_EnableAutoAttackEvents", "1")
    end
  else
    f:UnregisterEvent("AUTO_ATTACK_SELF")
  end

  -- Aura REMOVED events: only needed for Paladin Judgement stop logic / seal cancellation
  if self._needAuraRemoved then
    f:RegisterEvent("BUFF_REMOVED_SELF")
    f:RegisterEvent("BUFF_REMOVED_OTHER")
    f:RegisterEvent("DEBUFF_REMOVED_OTHER")
  else
    f:UnregisterEvent("BUFF_REMOVED_SELF")
    f:UnregisterEvent("BUFF_REMOVED_OTHER")
    f:UnregisterEvent("DEBUFF_REMOVED_OTHER")
  end

  -- NP events: only if player have any tracked auras
  if self._hasTracked then
    f:RegisterEvent("AURA_CAST_ON_SELF")
    f:RegisterEvent("AURA_CAST_ON_OTHER")

    f:RegisterEvent("BUFF_ADDED_SELF")
    f:RegisterEvent("BUFF_ADDED_OTHER")
    f:RegisterEvent("DEBUFF_ADDED_SELF")
    f:RegisterEvent("DEBUFF_ADDED_OTHER")
  else
    f:UnregisterEvent("AURA_CAST_ON_SELF")
    f:UnregisterEvent("AURA_CAST_ON_OTHER")

    f:UnregisterEvent("BUFF_ADDED_SELF")
    f:UnregisterEvent("BUFF_ADDED_OTHER")
    f:UnregisterEvent("DEBUFF_ADDED_SELF")
    f:UnregisterEvent("DEBUFF_ADDED_OTHER")

    -- also ensure paladin-only removals/autoattack are off when no tracked auras
    f:UnregisterEvent("AUTO_ATTACK_SELF")
    f:UnregisterEvent("BUFF_REMOVED_SELF")
    f:UnregisterEvent("BUFF_REMOVED_OTHER")
    f:UnregisterEvent("DEBUFF_REMOVED_OTHER")
  end
end

TrackFrame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    DoiteTrack:_ScheduleDelayedInit()
    return
  end
  if event == "LEARNED_SPELL_IN_TAB" then
    DoiteTrack:_OnLearnedSpellInTab()
    return
  end
  if event == "PLAYER_COMBO_POINTS" then
    DoiteTrack:_OnUnitComboPoints()
    return
  end
  if event == "SPELL_DAMAGE_EVENT_SELF" then
    DoiteTrack:_OnSpellDamageEventSelf()
    return
  end
  if event == "SPELL_CAST_EVENT" then
    DoiteTrack:_OnSpellCastEvent()
    return
  end
  if event == "AUTO_ATTACK_SELF" then
    DoiteTrack:_OnAutoAttackSelf()
    return
  end
  -- Any other event this frame receives (when registered) is NP aura-related
  DoiteTrack:_OnAuraNPEvent()
end)

---------------------------------------------------------------
-- Runtime API (compatible shape)
---------------------------------------------------------------
-- Internal helpers
local function _ClearAuraStateForGuidSpell(guid, spellId)
  if not guid or guid == "" then
    return
  end
  local b = AuraStateByGuid[guid]
  if b then
    b[spellId] = nil
  end
end

-- Assumes aura presence has already been verified by _AuraHasSpellId(). Uses ONLY player confirmed timer state; returns nil if unknown/not-mine/expired.
local function _GetRemainingFromState(guid, spellId, now)
  if not guid or guid == "" then
    return nil
  end

  local bucket = AuraStateByGuid[guid]
  if not bucket then
    return nil
  end

  local a = bucket[spellId]
  if not a or not a.appliedAt or not a.fullDur then
    return nil
  end

  local rem = (a.fullDur or 0) - (now - (a.appliedAt or now))
  if rem <= 0 then
    -- still present but expired => stop claiming ownership/timer
    bucket[spellId] = nil
    return nil
  end

  return rem
end

-- Name-based helpers (kept compatible)
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

function DoiteTrack:GetAuraRemainingSecondsByName(spellName, unit)
  if not spellName or not unit then
    return nil
  end

  local entry = _GetEntryForName(spellName)
  if not entry or not entry.spellIds then
    return nil
  end

  if not _UnitExistsFlag(unit) then
    return nil
  end

  local guid = _GetUnitGuidSafe(unit)
  if not guid then
    return nil
  end

  local now = GetTime and GetTime() or 0
  local isDebuff = (entry.kind == "Debuff")

  local bestRem, bestSpellId = nil, nil

  local sid
  for sid in pairs(entry.spellIds) do
    if _AuraHasSpellId(unit, sid, isDebuff) then
      local rem = _GetRemainingFromState(guid, sid, now)
      if rem and rem > 0 then
        if (not bestRem) or rem > bestRem then
          bestRem = rem
          bestSpellId = sid
        end
      end
    else
      -- if aura isn't present anymore, clear any stale timer state
      _ClearAuraStateForGuidSpell(guid, sid)
    end
  end

  if not bestRem then
    return nil
  end
  return bestRem, bestSpellId
end

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

function DoiteTrack:GetAuraOwnershipByName(spellName, unit)
  if not spellName or not unit then
    return nil, false, nil, false, false, false
  end

  local entry = _GetEntryForName(spellName)
  if not entry or not entry.spellIds then
    return nil, false, nil, false, false, false
  end

  if not _UnitExistsFlag(unit) then
    return nil, false, nil, false, false, false
  end

  local guid = _GetUnitGuidSafe(unit)
  if not guid then
    return nil, false, nil, false, false, false
  end

  local now = GetTime and GetTime() or 0
  local isDebuff = (entry.kind == "Debuff")

  local hasMine = false
  local hasOther = false
  local bestRem, bestSpellId = nil, nil

  local sid
  for sid in pairs(entry.spellIds) do
    if _AuraHasSpellId(unit, sid, isDebuff) then
      local rem = _GetRemainingFromState(guid, sid, now)
      if rem and rem > 0 then
        hasMine = true
        if (not bestRem) or rem > bestRem then
          bestRem = rem
          bestSpellId = sid
        end
      else
        -- aura present but player have no confirmed timer => treat as "other"
        hasOther = true
      end
    else
      _ClearAuraStateForGuidSpell(guid, sid)
    end
  end

  local ownerKnown = (hasMine or hasOther)
  return bestRem, false, bestSpellId, hasMine, hasOther, ownerKnown
end

---------------------------------------------------------------
-- Ingame usage
---------------------------------------------------------------
-- /run DoiteTrack_SetNPDebug(true)
-- /run local r,sid=DoiteTrack:GetAuraRemainingSecondsByName("[ADD SPELL NAME]","target");DEFAULT_CHAT_FRAME:AddMessage("rem="..tostring(r).." sid="..tostring(sid))