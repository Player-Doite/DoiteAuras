---------------------------------------------------------------
-- DoiteTargetAuras.lua
-- Target aura cache + lookup helpers (buffs/debuffs, slot + stack counts)
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------
local MAX_BUFF_SLOTS = 32
local MAX_DEBUFF_SLOTS = 16
local CACHE_TTL_SECONDS = 15 * 60

local function CreateGuidCache(guid)
  return {
    guid = guid,
    buffs = {},
    debuffs = {},
    activeBuffs = {},
    activeDebuffs = {},
    cappedBuffsExpirationTime = {},
    cappedBuffsStacks = {},
    overflowDebuffSpellIdByBuffSlot = {}, -- buff-slot index (1-32) -> spellId for overflow debuffs living in auraSlots 0-31
    numActiveBuffs = 0,
    numActiveDebuffs = 0,
    lastSeenTime = GetTime(),
  }
end

local DoiteTargetAuras = {
  guidCaches = {}, -- guid -> cache

  buffs = {}, -- current target cache only: slot -> { spellId, stacks }
  debuffs = {}, -- current target cache only: slot -> { spellId, stacks }

  spellIdToNameCache = {}, -- spellId -> spell name
  spellNameToIdCache = {}, -- spell name -> spellId
  spellNameToMaxStacks = {}, -- spell name -> max stacks

  activeBuffs = {}, -- current target cache: spell name -> slot
  activeDebuffs = {}, -- current target cache: spell name -> slot

  cappedBuffsExpirationTime = {}, -- current target cache: spell name -> expiration time in seconds
  cappedBuffsStacks = {}, -- current target cache: spell name -> stacks
  overflowDebuffSpellIdByBuffSlot = {}, -- current target cache: buff-slot index (1-32) -> spellId

  numActiveBuffs = 0,
  numActiveDebuffs = 0,

  targetGuid = "",

  buffCapEventsEnabled = true,

  debugBuffCap = false, -- when true: disable normal aura delta events; force aura-cast processing for testing
}

_G["DoiteTargetAuras"] = DoiteTargetAuras

local function NotifyConditionsChanged()
  local req = _G["DoiteConditions_RequestImmediateEval"]
  if req then
    req()
  end
end

local function SetActiveCache(cache)
  DoiteTargetAuras.buffs = cache.buffs
  DoiteTargetAuras.debuffs = cache.debuffs
  DoiteTargetAuras.activeBuffs = cache.activeBuffs
  DoiteTargetAuras.activeDebuffs = cache.activeDebuffs
  DoiteTargetAuras.cappedBuffsExpirationTime = cache.cappedBuffsExpirationTime
  DoiteTargetAuras.cappedBuffsStacks = cache.cappedBuffsStacks
  DoiteTargetAuras.overflowDebuffSpellIdByBuffSlot = cache.overflowDebuffSpellIdByBuffSlot
  DoiteTargetAuras.numActiveBuffs = cache.numActiveBuffs
  DoiteTargetAuras.numActiveDebuffs = cache.numActiveDebuffs
end

local function CopyCacheCountsFromActive(cache)
  cache.numActiveBuffs = DoiteTargetAuras.numActiveBuffs
  cache.numActiveDebuffs = DoiteTargetAuras.numActiveDebuffs
end

SetActiveCache(CreateGuidCache(""))

local function GetGuidCache(guid)
  if not guid or guid == "" then
    return nil
  end
  return DoiteTargetAuras.guidCaches[guid]
end

local function GetOrCreateGuidCache(guid)
  if not guid or guid == "" then
    return nil
  end

  local cache = DoiteTargetAuras.guidCaches[guid]
  if not cache then
    cache = CreateGuidCache(guid)
    DoiteTargetAuras.guidCaches[guid] = cache
  end
  cache.lastSeenTime = GetTime()
  return cache
end

local function MarkActive(spellId, activeTable, slot)
  if not DoiteTargetAuras.spellIdToNameCache[spellId] then
    local spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoiteTargetAuras.spellIdToNameCache[spellId] = spellName
      DoiteTargetAuras.spellNameToIdCache[spellName] = spellId
      activeTable[spellName] = slot
    end
  else
    local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
    if spellName then
      activeTable[spellName] = slot
    end
  end
end

local function MarkInactive(spellId, activeTable, slotTable, maxSlots, removedSlot)
  local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
  if not spellName then
    return
  end

  -- If we were not pointing at this slot, do nothing (stale/out-of-order removal).
  if removedSlot and activeTable[spellName] ~= removedSlot then
    return
  end

  -- Try to find another active instance of the same spellId and re-point to it.
  local i
  for i = 1, maxSlots do
    local aura = slotTable[i]
    if aura and aura.spellId == spellId then
      activeTable[spellName] = i
      return
    end
  end

  -- No remaining instance found -> clear mapping.
  activeTable[spellName] = nil
end

local function RemoveCappedBuff(spellName)
  DoiteTargetAuras.cappedBuffsExpirationTime[spellName] = 0
  DoiteTargetAuras.cappedBuffsStacks[spellName] = 0
end

local function IsOverflowDebuffBuffSlot(slot, aura)
  if not slot or not aura or not aura.spellId then
    return false
  end

  return DoiteTargetAuras.overflowDebuffSpellIdByBuffSlot[slot] == aura.spellId
end

local function HasAnyActiveCappedBuffs()
  local now = GetTime()
  local _, cache
  for _, cache in pairs(DoiteTargetAuras.guidCaches) do
    local _, expiration
    for _, expiration in pairs(cache.cappedBuffsExpirationTime) do
      if expiration > now then
        return true
      end
    end
  end

  return false
end

local function CleanupGuidCaches()
  local now = GetTime()
  local guid, cache
  for guid, cache in pairs(DoiteTargetAuras.guidCaches) do
    if (now - cache.lastSeenTime) > CACHE_TTL_SECONDS then
      DoiteTargetAuras.guidCaches[guid] = nil
    end
  end
end

local function SetTargetGuid(guid)
  if not guid or guid == "" then
    DoiteTargetAuras.targetGuid = ""
    SetActiveCache(CreateGuidCache(""))
    return nil
  end

  DoiteTargetAuras.targetGuid = guid
  local cache = GetOrCreateGuidCache(guid)
  SetActiveCache(cache)
  return cache
end

local function UpdateTargetGuid()
  local _, guid = UnitExists("target")
  return SetTargetGuid(guid)
end

local function IsCurrentTargetPlayer()
  if not DoiteTargetAuras.targetGuid or DoiteTargetAuras.targetGuid == "" then
    return false
  end

  -- We need this for any player target (self or other players), because
  -- *_OTHER aura delta events are unreliable for player units.
  return UnitIsPlayer("target") and true or false
end

local function UpdateAuras()
  CleanupGuidCaches()

  local cache = UpdateTargetGuid()
  if not cache then
    if not HasAnyActiveCappedBuffs() then
      DoiteTargetAuras.UnregisterBuffCapEvents()
    end
    return
  end

  local auraSpellIds = GetUnitField("target", "aura")
  local auraStacks = GetUnitField("target", "auraApplications")

  if not auraSpellIds or not auraStacks then
    if not HasAnyActiveCappedBuffs() then
      DoiteTargetAuras.UnregisterBuffCapEvents()
    end
    return
  end

  cache.activeBuffs = {}
  cache.activeDebuffs = {}
  cache.numActiveBuffs = 0
  cache.numActiveDebuffs = 0

  SetActiveCache(cache)

  local i
  for i = 1, MAX_BUFF_SLOTS do
    local spellId = auraSpellIds[i]
    if spellId and spellId ~= 0 then
      DoiteTargetAuras.buffs[i] = { spellId = spellId, stacks = auraStacks[i] + 1 }

      -- Keep overflow classification stable only while slot+spellId are unchanged.
      -- If spellId changed in this buff slot, clear stale "overflow debuff" marker.
      if DoiteTargetAuras.overflowDebuffSpellIdByBuffSlot[i] and DoiteTargetAuras.overflowDebuffSpellIdByBuffSlot[i] ~= spellId then
        DoiteTargetAuras.overflowDebuffSpellIdByBuffSlot[i] = nil
      end

      MarkActive(spellId, DoiteTargetAuras.activeBuffs, i)
      DoiteTargetAuras.numActiveBuffs = DoiteTargetAuras.numActiveBuffs + 1
    else
      DoiteTargetAuras.buffs[i] = nil
      DoiteTargetAuras.overflowDebuffSpellIdByBuffSlot[i] = nil
    end
  end

  for i = 1, MAX_DEBUFF_SLOTS do
    local auraIndex = MAX_BUFF_SLOTS + i
    local spellId = auraSpellIds[auraIndex]
    if spellId and spellId ~= 0 then
      DoiteTargetAuras.debuffs[i] = { spellId = spellId, stacks = auraStacks[auraIndex] + 1 }
      MarkActive(spellId, DoiteTargetAuras.activeDebuffs, i)
      DoiteTargetAuras.numActiveDebuffs = DoiteTargetAuras.numActiveDebuffs + 1
    else
      DoiteTargetAuras.debuffs[i] = nil
    end
  end

  CopyCacheCountsFromActive(cache)

  if DoiteTargetAuras.numActiveBuffs >= MAX_BUFF_SLOTS then
    DoiteTargetAuras.RegisterBuffCapEvents()
  elseif not HasAnyActiveCappedBuffs() then
    DoiteTargetAuras.UnregisterBuffCapEvents()
  end
end

function DoiteTargetAuras.Refresh()
  UpdateAuras()
  NotifyConditionsChanged()
end

function DoiteTargetAuras.IsHiddenByBuffCap(spellName)
  local expirationTime = DoiteTargetAuras.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 then
    if expirationTime > GetTime() then
      return true
    end
    RemoveCappedBuff(spellName)
  end
  return false
end

function DoiteTargetAuras.IsActive(spellName)
  return DoiteTargetAuras.activeBuffs[spellName] or
      DoiteTargetAuras.activeDebuffs[spellName] or
      DoiteTargetAuras.IsHiddenByBuffCap(spellName)
end

function DoiteTargetAuras.HasBuff(spellName)
  if DoiteTargetAuras.IsHiddenByBuffCap(spellName) then
    return true
  end

  local spellId = DoiteTargetAuras.spellNameToIdCache[spellName]
  if not spellId then
    return false
  end

  local i, aura
  for i = 1, MAX_BUFF_SLOTS do
    aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId == spellId and not IsOverflowDebuffBuffSlot(i, aura) then
      return true
    end
  end

  return false
end

function DoiteTargetAuras.HasDebuff(spellName)
  local spellId = DoiteTargetAuras.spellNameToIdCache[spellName]
  if not spellId then
    return false
  end

  local i, aura

  -- True debuff slots (auraSlots 32-47)
  for i = 1, MAX_DEBUFF_SLOTS do
    aura = DoiteTargetAuras.debuffs[i]
    if aura and aura.spellId == spellId then
      return true
    end
  end

  -- Overflow debuffs may live in buff auraSlots 0-31
  for i = 1, MAX_BUFF_SLOTS do
    aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId == spellId and IsOverflowDebuffBuffSlot(i, aura) then
      return true
    end
  end

  return false
end

function DoiteTargetAuras.GetBuffStacks(spellName)
  local cachedSlot = DoiteTargetAuras.activeBuffs[spellName]
  if not cachedSlot then
    if DoiteTargetAuras.IsHiddenByBuffCap(spellName) then
      return DoiteTargetAuras.cappedBuffsStacks[spellName]
    end
    return nil
  end

  local spellId = DoiteTargetAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  if DoiteTargetAuras.buffs[cachedSlot] and DoiteTargetAuras.buffs[cachedSlot].spellId == spellId then
    if not IsOverflowDebuffBuffSlot(cachedSlot, DoiteTargetAuras.buffs[cachedSlot]) then
      return DoiteTargetAuras.buffs[cachedSlot].stacks
    end
  end

  local i
  for i = 1, MAX_BUFF_SLOTS do
    local aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId == spellId and not IsOverflowDebuffBuffSlot(i, aura) then
      return aura.stacks
    end
  end

  return nil
end

function DoiteTargetAuras.GetActiveAuraSlot(spellName)
  local buffSlot = DoiteTargetAuras.activeBuffs[spellName]
  if buffSlot then
    return buffSlot - 1
  end

  local debuffSlot = DoiteTargetAuras.activeDebuffs[spellName]
  if debuffSlot then
    return MAX_BUFF_SLOTS + debuffSlot - 1
  end

  return nil
end

function DoiteTargetAuras.GetDebuffStacks(spellName)
  local spellId = DoiteTargetAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  -- 1) Prefer true debuff slots (auraSlots 32-47)
  local cachedDebuffSlot = DoiteTargetAuras.activeDebuffs[spellName]
  if cachedDebuffSlot then
    if DoiteTargetAuras.debuffs[cachedDebuffSlot] and DoiteTargetAuras.debuffs[cachedDebuffSlot].spellId == spellId then
      return DoiteTargetAuras.debuffs[cachedDebuffSlot].stacks
    end

    local i
    for i = 1, MAX_DEBUFF_SLOTS do
      local aura = DoiteTargetAuras.debuffs[i]
      if aura and aura.spellId == spellId then
        return aura.stacks
      end
    end
  end

  -- 2) Overflow case: debuff stored in buff auraSlots (0-31) => present in buff cache
  local cachedBuffSlot = DoiteTargetAuras.activeBuffs[spellName]
  if cachedBuffSlot then
    if DoiteTargetAuras.buffs[cachedBuffSlot] and DoiteTargetAuras.buffs[cachedBuffSlot].spellId == spellId then
      if IsOverflowDebuffBuffSlot(cachedBuffSlot, DoiteTargetAuras.buffs[cachedBuffSlot]) then
        return DoiteTargetAuras.buffs[cachedBuffSlot].stacks
      end
    end

    local i
    for i = 1, MAX_BUFF_SLOTS do
      local aura = DoiteTargetAuras.buffs[i]
      if aura and aura.spellId == spellId and IsOverflowDebuffBuffSlot(i, aura) then
        return aura.stacks
      end
    end
  end

  return nil
end

function DoiteTargetAuras.HasBuffSpellId(spellId)
  local i
  for i = 1, MAX_BUFF_SLOTS do
    local aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId == spellId and not IsOverflowDebuffBuffSlot(i, aura) then
      return true
    end
  end

  -- IMPORTANT: this API must stay spellId-exact.
  -- Falling back to HasBuff(name) turns rank/name aliases into false positives, which can classify a single aura as both "mine" and "other".
  return false
end

function DoiteTargetAuras.HasDebuffSpellId(spellId)
  local i
  for i = 1, MAX_DEBUFF_SLOTS do
    local aura = DoiteTargetAuras.debuffs[i]
    if aura and aura.spellId == spellId then
      return true
    end
  end

  -- Overflow: debuffs can occupy buff auraSlots (0-31), so they may only be present in the buff cache.
  for i = 1, MAX_BUFF_SLOTS do
    local aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId == spellId and IsOverflowDebuffBuffSlot(i, aura) then
      return true
    end
  end

  return false
end

function DoiteTargetAuras.GetHiddenBuffRemaining(spellName)
  local expirationTime = DoiteTargetAuras.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 then
    local remaining = expirationTime - GetTime()
    if remaining > 0 then
      return remaining
    end
    RemoveCappedBuff(spellName)
  end
  return nil
end

local TargetChangedFrame = CreateFrame("Frame", "DoiteTargetAuras_TargetChanged")
TargetChangedFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
TargetChangedFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
TargetChangedFrame:SetScript("OnEvent", function()
  UpdateAuras()
  NotifyConditionsChanged()
end)

-- Self aura NP events are required when player is the current target.
-- In that case, *_OTHER events do not fire, so refresh target cache directly.
local SelfAuraFrame = CreateFrame("Frame", "DoiteTargetAuras_SelfAura")
SelfAuraFrame:RegisterEvent("BUFF_ADDED_SELF")
SelfAuraFrame:RegisterEvent("BUFF_REMOVED_SELF")
SelfAuraFrame:RegisterEvent("DEBUFF_ADDED_SELF")
SelfAuraFrame:RegisterEvent("DEBUFF_REMOVED_SELF")
SelfAuraFrame:SetScript("OnEvent", function()
  if not IsCurrentTargetPlayer() then
    return
  end

  UpdateAuras()
  NotifyConditionsChanged()
end)

-- Fallback: if NP delta events are missed/suppressed, UNIT_AURA still fires. This keeps the authoritative snapshot correct for the current target.
local UnitAuraFrame = CreateFrame("Frame", "DoiteTargetAuras_UnitAura")
UnitAuraFrame:RegisterEvent("UNIT_AURA")
UnitAuraFrame:SetScript("OnEvent", function()
  -- UNIT_AURA arg1 is the unit id (e.g. "target", "player")
  if arg1 == "target" then
    UpdateAuras()
    NotifyConditionsChanged()
    return
  end

  -- If player is the current target, and player's auras change, treat it like target aura change too.
  if arg1 == "player" and IsCurrentTargetPlayer() then
    UpdateAuras()
    NotifyConditionsChanged()
    return
  end
end)

local UnitDiedFrame = CreateFrame("Frame", "DoiteTargetAuras_UnitDied")
UnitDiedFrame:RegisterEvent("UNIT_DIED")
UnitDiedFrame:SetScript("OnEvent", function()
  local guid = arg1
  if not guid or guid == "" then
    return
  end

  DoiteTargetAuras.guidCaches[guid] = nil
  if guid == DoiteTargetAuras.targetGuid then
    SetTargetGuid(nil)
    NotifyConditionsChanged()
  end

  if not HasAnyActiveCappedBuffs() then
    DoiteTargetAuras.UnregisterBuffCapEvents()
  end
end)

local BuffAddedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_BuffAddedOther")
BuffAddedOtherFrame:RegisterEvent("BUFF_ADDED_OTHER")
BuffAddedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if not guid or guid == "" then
    return
  end

  if auraSlot < 0 or auraSlot >= MAX_BUFF_SLOTS then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  local slot = auraSlot + 1
  cache.overflowDebuffSpellIdByBuffSlot[slot] = nil
  cache.buffs[slot] = { spellId = spellId, stacks = stacks }
  MarkActive(spellId, cache.activeBuffs, slot)

  if state == 0 then
    cache.numActiveBuffs = cache.numActiveBuffs + 1
    if cache.numActiveBuffs >= MAX_BUFF_SLOTS then
      DoiteTargetAuras.RegisterBuffCapEvents()
    end
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    -- Ownership swaps/refreshes can arrive as compact event sequences where
    -- slot-level deltas are ambiguous (especially for same-name debuffs).
    -- Rebuild from the authoritative target aura array to avoid stale
    -- activeDebuffs/activeBuffs state that can hide icons until a later reset.
    UpdateAuras()
    NotifyConditionsChanged()
  end
end)

local BuffRemovedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_BuffRemovedOther")
BuffRemovedOtherFrame:RegisterEvent("BUFF_REMOVED_OTHER")
BuffRemovedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if not guid or guid == "" then
    return
  end

  if auraSlot < 0 or auraSlot >= MAX_BUFF_SLOTS then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  local slot = auraSlot + 1
  cache.overflowDebuffSpellIdByBuffSlot[slot] = nil
  if state == 1 then
    cache.buffs[slot] = nil
    MarkInactive(spellId, cache.activeBuffs, cache.buffs, MAX_BUFF_SLOTS, slot)
    cache.numActiveBuffs = cache.numActiveBuffs - 1
  else
    if cache.buffs[slot] then
      cache.buffs[slot].stacks = stacks
    else
      cache.buffs[slot] = { spellId = spellId, stacks = stacks }
    end
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    -- Keep cache state authoritative during overwrite/replacement sequences.
    UpdateAuras()
    NotifyConditionsChanged()
  end

  if not HasAnyActiveCappedBuffs() then
    DoiteTargetAuras.UnregisterBuffCapEvents()
  end
end)

local DebuffAddedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_DebuffAddedOther")
DebuffAddedOtherFrame:RegisterEvent("DEBUFF_ADDED_OTHER")
DebuffAddedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if not guid or guid == "" then
    return
  end

  if auraSlot == nil then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  -- Normal debuffs: auraSlots 32-47
  if auraSlot >= MAX_BUFF_SLOTS and auraSlot < (MAX_BUFF_SLOTS + MAX_DEBUFF_SLOTS) then
    local slot = auraSlot - MAX_BUFF_SLOTS + 1
    cache.debuffs[slot] = { spellId = spellId, stacks = stacks }
    MarkActive(spellId, cache.activeDebuffs, slot)

    if state == 0 then
      cache.numActiveDebuffs = cache.numActiveDebuffs + 1
    end

  -- Overflow debuffs can live in buff auraSlots 0-31.
  -- Some event paths may still report them via DEBUFF_* events with auraSlot in 0-31. Store them in the buff cache (because that's where the auraSlot actually is).
  elseif auraSlot >= 0 and auraSlot < MAX_BUFF_SLOTS then
    local slot = auraSlot + 1
    cache.overflowDebuffSpellIdByBuffSlot[slot] = spellId
    cache.buffs[slot] = { spellId = spellId, stacks = stacks }
    MarkActive(spellId, cache.activeBuffs, slot)

    if state == 0 then
      cache.numActiveBuffs = cache.numActiveBuffs + 1
      if cache.numActiveBuffs >= MAX_BUFF_SLOTS then
        DoiteTargetAuras.RegisterBuffCapEvents()
      end
    end
  else
    return
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    -- Keep cache state authoritative during overwrite/replacement sequences.
    UpdateAuras()
    NotifyConditionsChanged()
  end
end)

local DebuffRemovedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_DebuffRemovedOther")
DebuffRemovedOtherFrame:RegisterEvent("DEBUFF_REMOVED_OTHER")
DebuffRemovedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if not guid or guid == "" then
    return
  end

  if auraSlot == nil then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  -- Normal debuffs: auraSlots 32-47
  if auraSlot >= MAX_BUFF_SLOTS and auraSlot < (MAX_BUFF_SLOTS + MAX_DEBUFF_SLOTS) then
    local slot = auraSlot - MAX_BUFF_SLOTS + 1
	if state == 1 then
	  cache.debuffs[slot] = nil
	  MarkInactive(spellId, cache.activeDebuffs, cache.debuffs, MAX_DEBUFF_SLOTS, slot)
	  cache.numActiveDebuffs = cache.numActiveDebuffs - 1
	else
      if cache.debuffs[slot] then
        cache.debuffs[slot].stacks = stacks
      else
        cache.debuffs[slot] = { spellId = spellId, stacks = stacks }
      end
    end

  -- Overflow debuffs reported via DEBUFF_* but living in buff auraSlots 0-31
  elseif auraSlot >= 0 and auraSlot < MAX_BUFF_SLOTS then
    local slot = auraSlot + 1
	if state == 1 then
	  cache.overflowDebuffSpellIdByBuffSlot[slot] = nil
	  cache.buffs[slot] = nil
	  MarkInactive(spellId, cache.activeBuffs, cache.buffs, MAX_BUFF_SLOTS, slot)
	  cache.numActiveBuffs = cache.numActiveBuffs - 1
	else
      cache.overflowDebuffSpellIdByBuffSlot[slot] = spellId
      if cache.buffs[slot] then
        cache.buffs[slot].stacks = stacks
      else
        cache.buffs[slot] = { spellId = spellId, stacks = stacks }
      end
    end
  else
    return
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    UpdateAuras()
    NotifyConditionsChanged()
  end

  if not HasAnyActiveCappedBuffs() then
    DoiteTargetAuras.UnregisterBuffCapEvents()
  end
end)

local AuraCastOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_AuraCastOther")
AuraCastOtherFrame:RegisterEvent("AURA_CAST_ON_OTHER")
AuraCastOtherFrame:SetScript("OnEvent", function()
  local spellId = arg1
  local targetGuid = arg3
  local durationMs = arg8
  local auraCapStatus = arg9

  if not targetGuid or targetGuid == "" then
    return
  end

  if not DoiteTargetAuras.debugBuffCap then
    if not (auraCapStatus == 1 or auraCapStatus == 3) then
      return
    end
  end

  local cache = GetGuidCache(targetGuid)
  if not cache and targetGuid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(targetGuid)

  local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
  if not spellName then
    spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoiteTargetAuras.spellIdToNameCache[spellId] = spellName
      DoiteTargetAuras.spellNameToIdCache[spellName] = spellId
    else
      return
    end
  end

  if not DoiteTargetAuras.spellNameToMaxStacks[spellName] then
    local maxStacks = GetSpellRecField(spellId, "stackAmount")
    if maxStacks == 0 then
      maxStacks = 1
    end
    DoiteTargetAuras.spellNameToMaxStacks[spellName] = maxStacks
  end

  local expirationTime = cache.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 and expirationTime <= GetTime() then
    cache.cappedBuffsStacks[spellName] = 0
  end

  cache.cappedBuffsExpirationTime[spellName] = GetTime() + durationMs / 1000.0

  local currentStacks = cache.cappedBuffsStacks[spellName] or 0
  local maxStacks = DoiteTargetAuras.spellNameToMaxStacks[spellName] or 1
  cache.cappedBuffsStacks[spellName] = math.min(currentStacks + 1, maxStacks)
  cache.lastSeenTime = GetTime()

  if targetGuid == DoiteTargetAuras.targetGuid then
    SetActiveCache(cache)
    NotifyConditionsChanged()
  end
end)

function DoiteTargetAuras.RegisterBuffCapEvents()
  DoiteTargetAuras.buffCapEventsEnabled = true
end

function DoiteTargetAuras.UnregisterBuffCapEvents()
  DoiteTargetAuras.buffCapEventsEnabled = false
end

function DoiteTargetAuras.ToggleDebugBuffCap()
  DoiteTargetAuras.debugBuffCap = not DoiteTargetAuras.debugBuffCap

  if DoiteTargetAuras.debugBuffCap then
    -- Enabling debug mode: stop consuming normal delta events so you can observe
    -- "buff cap style" behavior driven by AURA_CAST_ON_OTHER handling.
    BuffAddedOtherFrame:UnregisterEvent("BUFF_ADDED_OTHER")
    BuffRemovedOtherFrame:UnregisterEvent("BUFF_REMOVED_OTHER")
    DebuffAddedOtherFrame:UnregisterEvent("DEBUFF_ADDED_OTHER")
    DebuffRemovedOtherFrame:UnregisterEvent("DEBUFF_REMOVED_OTHER")

    -- If target is the player, *_OTHER doesn't fire; this frame refreshes from *_SELF events.
    -- Disable it too for a cleaner test surface.
    SelfAuraFrame:UnregisterEvent("BUFF_ADDED_SELF")
    SelfAuraFrame:UnregisterEvent("BUFF_REMOVED_SELF")
    SelfAuraFrame:UnregisterEvent("DEBUFF_ADDED_SELF")
    SelfAuraFrame:UnregisterEvent("DEBUFF_REMOVED_SELF")

    print("DoiteTargetAuras: Debug buff cap enabled - forcing AURA_CAST_ON_OTHER processing")
  else
    -- Disabling debug mode: restore normal events
    BuffAddedOtherFrame:RegisterEvent("BUFF_ADDED_OTHER")
    BuffRemovedOtherFrame:RegisterEvent("BUFF_REMOVED_OTHER")
    DebuffAddedOtherFrame:RegisterEvent("DEBUFF_ADDED_OTHER")
    DebuffRemovedOtherFrame:RegisterEvent("DEBUFF_REMOVED_OTHER")

    SelfAuraFrame:RegisterEvent("BUFF_ADDED_SELF")
    SelfAuraFrame:RegisterEvent("BUFF_REMOVED_SELF")
    SelfAuraFrame:RegisterEvent("DEBUFF_ADDED_SELF")
    SelfAuraFrame:RegisterEvent("DEBUFF_REMOVED_SELF")

    -- Refresh authoritative aura snapshot
    UpdateAuras()
    NotifyConditionsChanged()

    print("DoiteTargetAuras: Debug buff cap disabled")
  end
end

-- Debug helpers: counts for UI display. These counts are "client visible + tracked hidden-by-cap buffs".
function DoiteTargetAuras.GetVisibleAuraCounts()
  local buffCount = 0
  local debuffCount = 0
  local i, aura

  for i = 1, MAX_BUFF_SLOTS do
    aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId and aura.spellId ~= 0 then
      buffCount = buffCount + 1
    end
  end

  for i = 1, MAX_DEBUFF_SLOTS do
    aura = DoiteTargetAuras.debuffs[i]
    if aura and aura.spellId and aura.spellId ~= 0 then
      debuffCount = debuffCount + 1
    end
  end

  return buffCount, debuffCount
end

function DoiteTargetAuras.GetTrackedHiddenBuffCount()
  local now = GetTime()
  local count = 0
  local _, expiration
  for _, expiration in pairs(DoiteTargetAuras.cappedBuffsExpirationTime) do
    if expiration and expiration > now then
      count = count + 1
    end
  end
  return count
end

function DoiteTargetAuras.GetAuraCountSummary()
  local buffs, debuffs = DoiteTargetAuras.GetVisibleAuraCounts()
  local hidden = DoiteTargetAuras.GetTrackedHiddenBuffCount()
  return buffs, debuffs, hidden, (buffs + debuffs + hidden)
end
