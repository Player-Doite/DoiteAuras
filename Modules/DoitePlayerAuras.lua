---------------------------------------------------------------
-- DoitePlayerAuras.lua
-- Player aura cache + lookup helpers (buffs/debuffs, slot + stack counts)
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------
local MAX_BUFF_SLOTS = 32
local MAX_DEBUFF_SLOTS = 16

local DoitePlayerAuras = {
  buffs = {}, -- slot -> { spellId, stacks }
  debuffs = {}, -- slot -> { spellId, stacks }

  spellIdToNameCache = {}, -- spellId -> spell name
  spellNameToIdCache = {}, -- spell name -> spellId
  spellNameToMaxStacks = {}, -- spell name -> max stacks

  activeBuffs = {}, -- spell name -> slot
  activeDebuffs = {}, -- spell name -> slot
  activeBuffSpellIds = {}, -- spellId -> slot
  activeDebuffSpellIds = {}, -- spellId -> slot

  cappedBuffsExpirationTime = {}, -- spell name -> expiration time in seconds
  cappedBuffsStacks = {}, -- spell name -> stacks

  playerBuffIndexCache = {}, -- spell name -> player buff index (for GetPlayerBuffX functions)

  numActiveBuffs = 0,
  numActiveDebuffs = 0,

  playerGuid = "",

  buffCapEventsEnabled = false,
  debugBuffCap = false -- set to true to disable regular events and force buff cap events for testing
}
-- initialize all buff/debuff indexes
for i = 1, MAX_BUFF_SLOTS do
  table.insert(DoitePlayerAuras.buffs, {
    spellId = nil,
    stacks = nil
  })
end
for i = 1, MAX_DEBUFF_SLOTS do
  table.insert(DoitePlayerAuras.debuffs, {
    spellId = nil,
    stacks = nil
  })
end

_G["DoitePlayerAuras"] = DoitePlayerAuras

local function MarkActive(spellId, activeTable, slot)
  if activeTable == DoitePlayerAuras.activeBuffs then
    DoitePlayerAuras.activeBuffSpellIds[spellId] = slot
  elseif activeTable == DoitePlayerAuras.activeDebuffs then
    DoitePlayerAuras.activeDebuffSpellIds[spellId] = slot
  end

  -- cache spell name if not already cached
  if not DoitePlayerAuras.spellIdToNameCache[spellId] then
    local spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoitePlayerAuras.spellIdToNameCache[spellId] = spellName
      DoitePlayerAuras.spellNameToIdCache[spellName] = spellId
      activeTable[spellName] = slot
    end
  else
    -- mark as active with slot
    local spellName = DoitePlayerAuras.spellIdToNameCache[spellId]
    if spellName then
      activeTable[spellName] = slot
    end
  end
end

local function MarkInactive(spellId, activeTable)
  if activeTable == DoitePlayerAuras.activeBuffs then
    DoitePlayerAuras.activeBuffSpellIds[spellId] = false
  elseif activeTable == DoitePlayerAuras.activeDebuffs then
    DoitePlayerAuras.activeDebuffSpellIds[spellId] = false
  end

  local spellName = DoitePlayerAuras.spellIdToNameCache[spellId]
  if spellName then
    activeTable[spellName] = false
  end
end

local function RemoveCappedBuff(spellName)
  -- set expiration to 0
  DoitePlayerAuras.cappedBuffsExpirationTime[spellName] = 0
  -- wipe stacks
  DoitePlayerAuras.cappedBuffsStacks[spellName] = 0
end

local function UpdateAuras()
  local auraSpellIds = GetUnitField("player", "aura")
  local auraStacks = GetUnitField("player", "auraApplications")

  -- clear active buffs/debuffs
  DoitePlayerAuras.activeBuffs = {}
  DoitePlayerAuras.activeDebuffs = {}
  DoitePlayerAuras.activeBuffSpellIds = {}
  DoitePlayerAuras.activeDebuffSpellIds = {}

  -- aura array becomes 1-indexed in Lua: 1-32 are buffs, 33-48 are debuffs
  DoitePlayerAuras.numActiveBuffs = 0
  for i = 1, MAX_BUFF_SLOTS do
    local spellId = auraSpellIds[i]
    if spellId and spellId ~= 0 then
      DoitePlayerAuras.buffs[i].spellId = spellId
      DoitePlayerAuras.buffs[i].stacks = auraStacks[i] + 1 -- raw buff stacks are 0-indexed, add 1
      MarkActive(spellId, DoitePlayerAuras.activeBuffs, i)
      DoitePlayerAuras.numActiveBuffs = i
    else
      DoitePlayerAuras.buffs[i].spellId = nil
      DoitePlayerAuras.buffs[i].stacks = nil
    end
  end

  -- debuffs: aura indices 33-48
  DoitePlayerAuras.numActiveDebuffs = 0
  for i = 1, MAX_DEBUFF_SLOTS do
    local spellId = auraSpellIds[MAX_BUFF_SLOTS + i]
    if spellId and spellId ~= 0 then
      DoitePlayerAuras.debuffs[i].spellId = spellId
      DoitePlayerAuras.debuffs[i].stacks = auraStacks[MAX_BUFF_SLOTS + i] + 1 -- raw debuff stacks are 0-indexed, add 1
      MarkActive(spellId, DoitePlayerAuras.activeDebuffs, i)
      DoitePlayerAuras.numActiveDebuffs = i
    else
      DoitePlayerAuras.debuffs[i].spellId = nil
      DoitePlayerAuras.debuffs[i].stacks = nil
    end
  end
end

function DoitePlayerAuras.IsHiddenByBuffCap(spellName)
  local expirationTime = DoitePlayerAuras.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 then
    if expirationTime > GetTime() then
      return true
    else
      -- expired, remove the capped buff
      RemoveCappedBuff(spellName)
    end
  end
  return false
end

function DoitePlayerAuras.IsActive(spellName)
  return DoitePlayerAuras.activeBuffs[spellName] or
      DoitePlayerAuras.activeDebuffs[spellName] or
      DoitePlayerAuras.IsHiddenByBuffCap(spellName)
end

function DoitePlayerAuras.HasBuff(spellName)
  return DoitePlayerAuras.activeBuffs[spellName] or
      DoitePlayerAuras.IsHiddenByBuffCap(spellName)
end

function DoitePlayerAuras.HasBuffSpellId(spellId)
  spellId = tonumber(spellId) or 0
  if spellId <= 0 then
    return false
  end
  return DoitePlayerAuras.activeBuffSpellIds[spellId] or false
end

function DoitePlayerAuras.HasDebuff(spellName)
  -- don't think it's possible to hit debuff cap as a player currently, not gonna worry about it
  return DoitePlayerAuras.activeDebuffs[spellName] or false
end

function DoitePlayerAuras.HasDebuffSpellId(spellId)
  spellId = tonumber(spellId) or 0
  if spellId <= 0 then
    return false
  end
  return DoitePlayerAuras.activeDebuffSpellIds[spellId] or false
end

function DoitePlayerAuras.GetActiveAuraSlot(spellName)
  local buffSlot = DoitePlayerAuras.activeBuffs[spellName]
  if buffSlot then
    return buffSlot - 1 -- 0-31
  end

  local debuffSlot = DoitePlayerAuras.activeDebuffs[spellName]
  if debuffSlot then
    return MAX_BUFF_SLOTS + debuffSlot - 1 -- 32-47
  end

  return nil
end

function DoitePlayerAuras.GetActiveAuraSlotBySpellId(spellId)
  spellId = tonumber(spellId) or 0
  if spellId <= 0 then
    return nil
  end

  local buffSlot = DoitePlayerAuras.activeBuffSpellIds[spellId]
  if buffSlot then
    return buffSlot - 1 -- 0-31
  end

  local debuffSlot = DoitePlayerAuras.activeDebuffSpellIds[spellId]
  if debuffSlot then
    return MAX_BUFF_SLOTS + debuffSlot - 1 -- 32-47
  end

  return nil
end

function DoitePlayerAuras.GetBuffStacks(spellName)
  -- check if spell is active and get cached slot
  local cachedSlot = DoitePlayerAuras.activeBuffs[spellName]
  if not cachedSlot then
    -- check if hidden by buff cap
    if DoitePlayerAuras.IsHiddenByBuffCap(spellName) then
      return DoitePlayerAuras.cappedBuffsStacks[spellName]
    end

    return nil
  end

  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  -- check cached slot first
  if DoitePlayerAuras.buffs[cachedSlot] and DoitePlayerAuras.buffs[cachedSlot].spellId == spellId then
    return DoitePlayerAuras.buffs[cachedSlot].stacks
  end

  -- fallback: search through buffs for matching spell ID
  for i = 1, MAX_BUFF_SLOTS do
    if not DoitePlayerAuras.buffs[i].spellId then
      break
    end

    if DoitePlayerAuras.buffs[i].spellId == spellId then
      return DoitePlayerAuras.buffs[i].stacks
    end
  end

  return nil
end

function DoitePlayerAuras.GetBuffStacksBySpellId(spellId)
  local cachedSlot = DoitePlayerAuras.HasBuffSpellId(spellId)
  if not cachedSlot then
    return nil
  end

  if DoitePlayerAuras.buffs[cachedSlot] and DoitePlayerAuras.buffs[cachedSlot].spellId == spellId then
    return DoitePlayerAuras.buffs[cachedSlot].stacks
  end

  for i = 1, MAX_BUFF_SLOTS do
    if not DoitePlayerAuras.buffs[i].spellId then
      break
    end

    if DoitePlayerAuras.buffs[i].spellId == spellId then
      return DoitePlayerAuras.buffs[i].stacks
    end
  end

  return nil
end

function DoitePlayerAuras.GetDebuffStacks(spellName)
  -- check if active and get cached slot
  local cachedSlot = DoitePlayerAuras.activeDebuffs[spellName]
  if not cachedSlot then
    return nil
  end

  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  -- check cached slot first
  if DoitePlayerAuras.debuffs[cachedSlot] and DoitePlayerAuras.debuffs[cachedSlot].spellId == spellId then
    return DoitePlayerAuras.debuffs[cachedSlot].stacks
  end

  -- fallback: search through debuffs for matching spell ID
  for i = 1, MAX_DEBUFF_SLOTS do
    if not DoitePlayerAuras.debuffs[i].spellId then
      break
    end

    if DoitePlayerAuras.debuffs[i].spellId == spellId then
      return DoitePlayerAuras.debuffs[i].stacks
    end
  end

  return nil
end

function DoitePlayerAuras.GetDebuffStacksBySpellId(spellId)
  local cachedSlot = DoitePlayerAuras.HasDebuffSpellId(spellId)
  if not cachedSlot then
    return nil
  end

  if DoitePlayerAuras.debuffs[cachedSlot] and DoitePlayerAuras.debuffs[cachedSlot].spellId == spellId then
    return DoitePlayerAuras.debuffs[cachedSlot].stacks
  end

  for i = 1, MAX_DEBUFF_SLOTS do
    if not DoitePlayerAuras.debuffs[i].spellId then
      break
    end

    if DoitePlayerAuras.debuffs[i].spellId == spellId then
      return DoitePlayerAuras.debuffs[i].stacks
    end
  end

  return nil
end

function DoitePlayerAuras.GetHiddenBuffRemaining(spellName)
  local expirationTime = DoitePlayerAuras.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 then
    local remaining = expirationTime - GetTime()
    if remaining > 0 then
      return remaining
    end
    -- expired, remove the capped buff
    RemoveCappedBuff(spellName)
  end
  return nil
end

-- Debug helpers: counts for UI display.
-- These counts are "client visible + tracked hidden-by-cap buffs".
function DoitePlayerAuras.GetVisibleAuraCounts()
  local buffCount = 0
  local debuffCount = 0

  for i = 1, MAX_BUFF_SLOTS do
    local aura = DoitePlayerAuras.buffs[i]
    if aura and aura.spellId and aura.spellId ~= 0 then
      buffCount = buffCount + 1
    end
  end

  for i = 1, MAX_DEBUFF_SLOTS do
    local aura = DoitePlayerAuras.debuffs[i]
    if aura and aura.spellId and aura.spellId ~= 0 then
      debuffCount = debuffCount + 1
    end
  end

  return buffCount, debuffCount
end

function DoitePlayerAuras.GetTrackedHiddenBuffCount()
  local now = GetTime()
  local count = 0

  for _, expiration in pairs(DoitePlayerAuras.cappedBuffsExpirationTime) do
    if expiration and expiration > now then
      count = count + 1
    end
  end

  return count
end

function DoitePlayerAuras.GetAuraCountSummary()
  local buffs, debuffs = DoitePlayerAuras.GetVisibleAuraCounts()
  local hidden = DoitePlayerAuras.GetTrackedHiddenBuffCount()
  return buffs, debuffs, hidden, (buffs + debuffs + hidden)
end

-- Frame for PLAYER_ENTERING_WORLD event
local PlayerEnteringWorldFrame = CreateFrame("Frame", "DoitePlayerAuras_PlayerEnteringWorld")
PlayerEnteringWorldFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
PlayerEnteringWorldFrame:SetScript("OnEvent", function()
  if not DoitePlayerAuras.debugBuffCap then
    UpdateAuras()
  end

  local _, guid = UnitExists("player")
  DoitePlayerAuras.playerGuid = guid or ""

  -- if at buff cap enable extra events
  if DoitePlayerAuras.numActiveBuffs >= MAX_BUFF_SLOTS or DoitePlayerAuras.debugBuffCap then
    DoitePlayerAuras.RegisterBuffCapEvents()
  end
end)

-- Frame for BUFF_ADDED_SELF event
local BuffAddedFrame = CreateFrame("Frame", "DoitePlayerAuras_BuffAdded")
if not DoitePlayerAuras.debugBuffCap then
  BuffAddedFrame:RegisterEvent("BUFF_ADDED_SELF")
end
BuffAddedFrame:SetScript("OnEvent", function()
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6 -- 0-based raw slot (0-31 for buffs)
  local state = arg7 -- 0=added, 1=removed, 2=modified (stack change)

  local slot = auraSlot + 1 -- convert to 1-based for internal buffs table
  DoitePlayerAuras.buffs[slot].spellId = spellId
  DoitePlayerAuras.buffs[slot].stacks = stacks
  MarkActive(spellId, DoitePlayerAuras.activeBuffs, slot)

  if state == 0 then
    -- newly added
    DoitePlayerAuras.numActiveBuffs = DoitePlayerAuras.numActiveBuffs + 1

    if DoitePlayerAuras.numActiveBuffs >= MAX_BUFF_SLOTS or DoitePlayerAuras.debugBuffCap then
      DoitePlayerAuras.RegisterBuffCapEvents()
    end
  end
end)

-- Frame for BUFF_REMOVED_SELF event
local BuffRemovedFrame = CreateFrame("Frame", "DoitePlayerAuras_BuffRemoved")
if not DoitePlayerAuras.debugBuffCap then
  BuffRemovedFrame:RegisterEvent("BUFF_REMOVED_SELF")
end
BuffRemovedFrame:SetScript("OnEvent", function()
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6 -- 0-based raw slot (0-31 for buffs)
  local state = arg7 -- 0=added, 1=removed, 2=modified (stack decrease)

  local slot = auraSlot + 1 -- convert to 1-based for internal buffs table

  if state == 1 then
    -- fully removed
    DoitePlayerAuras.buffs[slot].spellId = nil
    DoitePlayerAuras.buffs[slot].stacks = nil
    MarkInactive(spellId, DoitePlayerAuras.activeBuffs)
    DoitePlayerAuras.numActiveBuffs = DoitePlayerAuras.numActiveBuffs - 1

    if DoitePlayerAuras.buffCapEventsEnabled then
      -- check if any capped buffs are still active before unregistering
      local hasActiveCappedBuffs = false
      for _, expiration in pairs(DoitePlayerAuras.cappedBuffsExpirationTime) do
        if expiration > GetTime() then
          hasActiveCappedBuffs = true
          break
        end
      end
      if not hasActiveCappedBuffs then
        DoitePlayerAuras.UnregisterBuffCapEvents()
      end
    end
  else
    -- state == 2, stack decrease
    DoitePlayerAuras.buffs[slot].stacks = stacks
  end
end)

-- Frame for DEBUFF_ADDED_SELF event
local DebuffAddedFrame = CreateFrame("Frame", "DoitePlayerAuras_DebuffAdded")
if not DoitePlayerAuras.debugBuffCap then
  DebuffAddedFrame:RegisterEvent("DEBUFF_ADDED_SELF")
end
DebuffAddedFrame:SetScript("OnEvent", function()
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6 -- 0-based raw slot (32-47 for debuffs)
  local state = arg7 -- 0=added, 1=removed, 2=modified (stack change)

  local slot = auraSlot - MAX_BUFF_SLOTS + 1 -- convert to 1-based debuff index (1-16)
  DoitePlayerAuras.debuffs[slot].spellId = spellId
  DoitePlayerAuras.debuffs[slot].stacks = stacks
  MarkActive(spellId, DoitePlayerAuras.activeDebuffs, slot)

  if state == 0 then
    -- newly added
    DoitePlayerAuras.numActiveDebuffs = DoitePlayerAuras.numActiveDebuffs + 1
  end
end)

-- Frame for DEBUFF_REMOVED_SELF event
local DebuffRemovedFrame = CreateFrame("Frame", "DoitePlayerAuras_DebuffRemoved")
if not DoitePlayerAuras.debugBuffCap then
  DebuffRemovedFrame:RegisterEvent("DEBUFF_REMOVED_SELF")
end
DebuffRemovedFrame:SetScript("OnEvent", function()
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6 -- 0-based raw slot (32-47 for debuffs)
  local state = arg7 -- 0=added, 1=removed, 2=modified (stack decrease)

  local slot = auraSlot - MAX_BUFF_SLOTS + 1 -- convert to 1-based debuff index (1-16)

  if state == 1 then
    -- fully removed
    DoitePlayerAuras.debuffs[slot].spellId = nil
    DoitePlayerAuras.debuffs[slot].stacks = nil
    MarkInactive(spellId, DoitePlayerAuras.activeDebuffs)
    DoitePlayerAuras.numActiveDebuffs = DoitePlayerAuras.numActiveDebuffs - 1
  else
    -- state == 2, stack decrease
    DoitePlayerAuras.debuffs[slot].stacks = stacks
  end
end)

-- Frame for AURA_CAST_ON_SELF event (dynamically registered during buff cap)
local AuraCastFrame = CreateFrame("Frame", "DoitePlayerAuras_AuraCast")
AuraCastFrame:SetScript("OnEvent", function()
  -- only care about buffs when at buff cap
  -- int auraCapStatus - bitfield: 1 = buff bar full, 2 = debuff bar full (3 means both)
  local spellId, durationMs, auraCapStatus = arg1, arg8, arg9

  local applyCappedBuff = auraCapStatus == 1 or auraCapStatus == 3 or DoitePlayerAuras.debugBuffCap



  -- double check we are buff capped
  if applyCappedBuff then
    -- cache spell name if not already cached
    local spellName = DoitePlayerAuras.spellIdToNameCache[spellId]
    if not spellName then
      spellName = GetSpellRecField(spellId, "name")
      if spellName then
        DoitePlayerAuras.spellIdToNameCache[spellId] = spellName
        DoitePlayerAuras.spellNameToIdCache[spellName] = spellId
      else
        return
      end
    end

    -- cache max stacks for spell
    if not DoitePlayerAuras.spellNameToMaxStacks[spellName] then
      local maxStacks = GetSpellRecField(spellId, "stackAmount")
      if maxStacks == 0 then
        maxStacks = 1
      end
      DoitePlayerAuras.spellNameToMaxStacks[spellName] = maxStacks
    end

    -- if expired wipe previous stacks
    local expirationTime = DoitePlayerAuras.cappedBuffsExpirationTime[spellName]
    if expirationTime and expirationTime > 0 and expirationTime <= GetTime() then
      DoitePlayerAuras.cappedBuffsStacks[spellName] = 0
    end

    DoitePlayerAuras.cappedBuffsExpirationTime[spellName] = GetTime() + durationMs / 1000.0

    -- increment stacks, capped at max stacks
    local currentStacks = DoitePlayerAuras.cappedBuffsStacks[spellName] or 0
    local maxStacks = DoitePlayerAuras.spellNameToMaxStacks[spellName] or 1

    DoitePlayerAuras.cappedBuffsStacks[spellName] = math.min(currentStacks + 1, maxStacks)
  end
end)

-- Shared logic for processing spell casts that may consume stacks or clearcasting
local function ProcessBuffCappedSpell(spellId, casterGUID, targetGUID)
  if DoiteBuffData.stackModifiers[spellId] then
    local modifiedBuffName = DoiteBuffData.stackModifiers[spellId].modifiedBuffName
    local stackChange = DoiteBuffData.stackModifiers[spellId].stackChange

    local currentStacks = DoitePlayerAuras.cappedBuffsStacks[modifiedBuffName] or 0

    if stackChange > 0 then
      local maxStacks = DoitePlayerAuras.spellNameToMaxStacks[modifiedBuffName] or 1
      local newStacks = math.min(currentStacks + stackChange, maxStacks)
      DoitePlayerAuras.cappedBuffsStacks[modifiedBuffName] = newStacks

      local duration = DoiteBuffData.stackModifiers[spellId].duration
      if duration then
        DoitePlayerAuras.cappedBuffsExpirationTime[modifiedBuffName] = GetTime() + duration
      end
    elseif stackChange < 0 and currentStacks > 0 then
      local newStacks = math.max(0, currentStacks + stackChange)
      DoitePlayerAuras.cappedBuffsStacks[modifiedBuffName] = newStacks

      if newStacks == 0 then
        RemoveCappedBuff(modifiedBuffName)
      end
    end
  end
  -- check for clearcasting
  if DoitePlayerAuras.IsHiddenByBuffCap("Clearcasting") and
      targetGUID ~= casterGUID then
    -- remove clearcasting buff on any spell cast that costs mana and doesn't target yourself
    -- not perfect as buffs on others will remove but pretty good
    local manaCost = GetSpellRecField(spellId, "manaCost")
    if manaCost and manaCost > 0 then
      RemoveCappedBuff("Clearcasting")
    end
  end
end

-- Frame for SPELL_GO_SELF event
local SpellGoSelfFrame = CreateFrame("Frame", "DoitePlayerAuras_SpellGoSelf")
SpellGoSelfFrame:SetScript("OnEvent", function()
  local spellId = arg2
  local casterGUID = arg3
  local targetGUID = arg4
  ProcessBuffCappedSpell(spellId, casterGUID, targetGUID)
end)

-- Frame for SPELL_CHANNEL_START event (fires when player starts or updates a channeled spell)
local SpellChannelStartFrame = CreateFrame("Frame", "DoitePlayerAuras_SpellChannelStart")
SpellChannelStartFrame:SetScript("OnEvent", function()
  local spellId = arg1
  local targetGUID = arg2 -- from ChannelTargetGuid, "0x0000000000000000" if none
  -- arg3 = durationMs (unused for stack/clearcasting logic)
  ProcessBuffCappedSpell(spellId, DoitePlayerAuras.playerGuid, targetGUID)
end)

function DoitePlayerAuras.RegisterBuffCapEvents()
  if DoitePlayerAuras.buffCapEventsEnabled then
    return
  end
  DoitePlayerAuras.buffCapEventsEnabled = true
  AuraCastFrame:RegisterEvent("AURA_CAST_ON_SELF")
  SpellGoSelfFrame:RegisterEvent("SPELL_GO_SELF")
  SpellChannelStartFrame:RegisterEvent("SPELL_CHANNEL_START")
end

-- Currently unused as it is hard to know when we can safely unregister these events
-- shouldn't be an issue if left registered even after someone drops below buff cap
function DoitePlayerAuras.UnregisterBuffCapEvents()
  if not DoitePlayerAuras.buffCapEventsEnabled then
    return
  end
  DoitePlayerAuras.buffCapEventsEnabled = false
  AuraCastFrame:UnregisterEvent("AURA_CAST_ON_SELF")
  SpellGoSelfFrame:UnregisterEvent("SPELL_GO_SELF")
  SpellChannelStartFrame:UnregisterEvent("SPELL_CHANNEL_START")
end

function DoitePlayerAuras.SetDebugBuffCap(enabled)
  local want = (enabled == true)
  if DoitePlayerAuras.debugBuffCap == want then
    return
  end

  DoitePlayerAuras.debugBuffCap = want

  if DoitePlayerAuras.debugBuffCap then
    -- Enabling debug mode: unregister normal events and register buff cap events
    BuffAddedFrame:UnregisterEvent("BUFF_ADDED_SELF")
    BuffRemovedFrame:UnregisterEvent("BUFF_REMOVED_SELF")
    DebuffAddedFrame:UnregisterEvent("DEBUFF_ADDED_SELF")
    DebuffRemovedFrame:UnregisterEvent("DEBUFF_REMOVED_SELF")
    DoitePlayerAuras.RegisterBuffCapEvents()
    print("DoitePlayerAuras: Debug buff cap enabled - simulating buff cap behavior")
  else
    -- Disabling debug mode: register normal events and unregister buff cap events
    BuffAddedFrame:RegisterEvent("BUFF_ADDED_SELF")
    BuffRemovedFrame:RegisterEvent("BUFF_REMOVED_SELF")
    DebuffAddedFrame:RegisterEvent("DEBUFF_ADDED_SELF")
    DebuffRemovedFrame:RegisterEvent("DEBUFF_REMOVED_SELF")
    DoitePlayerAuras.UnregisterBuffCapEvents()
    -- Refresh buff/debuff state
	UpdateAuras()
    print("DoitePlayerAuras: Debug buff cap disabled")
  end
end

function DoitePlayerAuras.ToggleDebugBuffCap()
  DoitePlayerAuras.SetDebugBuffCap(not DoitePlayerAuras.debugBuffCap)
end
