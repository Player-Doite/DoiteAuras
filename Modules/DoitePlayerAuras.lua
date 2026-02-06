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

  cappedBuffsExpirationTime = {}, -- spell name -> expiration time
  cappedBuffsStacks = {}, -- spell name -> stacks

  playerBuffIndexCache = {}, -- spell name -> player buff index (for GetPlayerBuffX functions)

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

local function UpdateBuffs()
  -- clear active buffs
  DoitePlayerAuras.activeBuffs = {}

  -- update existing buffs/debuffs
  for i = 1, MAX_BUFF_SLOTS do
    local _, stacks, spellId = UnitBuff("player", i)
    if spellId then
      DoitePlayerAuras.buffs[i].spellId = spellId
      DoitePlayerAuras.buffs[i].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeBuffs, i)
    else
      -- once we hit nil, all remaining will be nil, so clear them and break
      for j = i, MAX_BUFF_SLOTS do
        DoitePlayerAuras.buffs[j].spellId = nil
        DoitePlayerAuras.buffs[j].stacks = nil
      end
      break
    end
  end
end

local function UpdateDebuffs()
  -- clear active debuffs
  DoitePlayerAuras.activeDebuffs = {}

  for i = 1, MAX_DEBUFF_SLOTS do
    local _, stacks, _, spellId = UnitDebuff("player", i)
    if spellId then
      DoitePlayerAuras.debuffs[i].spellId = spellId
      DoitePlayerAuras.debuffs[i].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeDebuffs, i)
    else
      -- once we hit nil, all remaining will be nil, so clear them and break
      for j = i, MAX_DEBUFF_SLOTS do
        DoitePlayerAuras.debuffs[j].spellId = nil
        DoitePlayerAuras.debuffs[j].stacks = nil
      end
      break
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

function DoitePlayerAuras.HasDebuff(spellName)
  -- don't think it's possible to hit debuff cap as a player currently, not gonna worry about it
  return DoitePlayerAuras.activeDebuffs[spellName] or false
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

-- returns the player buff index (buffs and debuffs are mixed together) for use with GetPlayerBuffX functions
function DoitePlayerAuras.GetBuffBarSlot(spellName)
  -- convert spellName to spellId using cache
  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  -- check cached index first
  local cachedIndex = DoitePlayerAuras.playerBuffIndexCache[spellName]
  if cachedIndex then
    local buffSpellId = GetPlayerBuffID(cachedIndex)
    if buffSpellId == spellId then
      return cachedIndex
    end
  end

  -- loop through 0-47 to find the buff/debuff index
  for i = 0, 47 do
    local buffSpellId = GetPlayerBuffID(i)

    if not buffSpellId then
      break
    end

    if buffSpellId == spellId then
      -- cache the index
      DoitePlayerAuras.playerBuffIndexCache[spellName] = i
      return i
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

-- Frame for PLAYER_ENTERING_WORLD event
local PlayerEnteringWorldFrame = CreateFrame("Frame", "DoitePlayerAuras_PlayerEnteringWorld")
PlayerEnteringWorldFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
PlayerEnteringWorldFrame:SetScript("OnEvent", function()
  if not DoitePlayerAuras.debugBuffCap then
    UpdateBuffs()
    UpdateDebuffs()
  end

  local _, guid = UnitExists("player")
  DoitePlayerAuras.playerGuid = guid or ""

  -- if already buff capped enable extra events
  if DoitePlayerAuras.buffs[MAX_BUFF_SLOTS].spellId or DoitePlayerAuras.debugBuffCap then
    DoitePlayerAuras.RegisterBuffCapEvents()
  end
end)

-- Frame for BUFF_ADDED_SELF event
local BuffAddedFrame = CreateFrame("Frame", "DoitePlayerAuras_BuffAdded")
if not DoitePlayerAuras.debugBuffCap then
  BuffAddedFrame:RegisterEvent("BUFF_ADDED_SELF")
end
BuffAddedFrame:SetScript("OnEvent", function()
  local unitSlot, spellId, stacks = arg2, arg3, arg4

  -- some spells like passive auras will not use the last open slot and will push down other buffs, check for this
  if DoitePlayerAuras.buffs[unitSlot].spellId then
    UpdateBuffs()
  else
    DoitePlayerAuras.buffs[unitSlot].spellId = spellId
    DoitePlayerAuras.buffs[unitSlot].stacks = stacks
    MarkActive(spellId, DoitePlayerAuras.activeBuffs, unitSlot)
  end

  -- check if unit buff slot 32 is filled
  if DoitePlayerAuras.buffs[MAX_BUFF_SLOTS].spellId then
    -- just hit buff cap, enable AURA_CAST event
    DoitePlayerAuras.RegisterBuffCapEvents()
  end
end)

-- Frame for BUFF_REMOVED_SELF event
local BuffRemovedFrame = CreateFrame("Frame", "DoitePlayerAuras_BuffRemoved")
if not DoitePlayerAuras.debugBuffCap then
  BuffRemovedFrame:RegisterEvent("BUFF_REMOVED_SELF")
end
BuffRemovedFrame:SetScript("OnEvent", function()
  local spellId = arg3
  -- probably could just shift down buffs a slot but not sure what happens when 2 get removed at the exact same time
  UpdateBuffs()
  MarkInactive(spellId, DoitePlayerAuras.activeBuffs)

  -- check if unit buff slot 32 is open
  if not DoitePlayerAuras.buffs[MAX_BUFF_SLOTS].spellId then
    -- no longer buff capped, disable AURA_CAST event
    DoitePlayerAuras.UnregisterBuffCapEvents()
  end
end)

-- Frame for DEBUFF_ADDED_SELF event
local DebuffAddedFrame = CreateFrame("Frame", "DoitePlayerAuras_DebuffAdded")
if not DoitePlayerAuras.debugBuffCap then
  DebuffAddedFrame:RegisterEvent("DEBUFF_ADDED_SELF")
end
DebuffAddedFrame:SetScript("OnEvent", function()
  local unitSlot, spellId, stacks = arg2, arg3, arg4
  DoitePlayerAuras.debuffs[unitSlot].spellId = spellId
  DoitePlayerAuras.debuffs[unitSlot].stacks = stacks
  MarkActive(spellId, DoitePlayerAuras.activeDebuffs, unitSlot)
end)

-- Frame for DEBUFF_REMOVED_SELF event
local DebuffRemovedFrame = CreateFrame("Frame", "DoitePlayerAuras_DebuffRemoved")
if not DoitePlayerAuras.debugBuffCap then
  DebuffRemovedFrame:RegisterEvent("DEBUFF_REMOVED_SELF")
end
DebuffRemovedFrame:SetScript("OnEvent", function()
  local spellId = arg3
  -- probably could just shift down buffs a slot but not sure what happens when 2 get removed at the exact same time
  UpdateDebuffs()
  MarkInactive(spellId, DoitePlayerAuras.activeDebuffs)
end)

-- Frame for AURA_CAST_ON_SELF event (dynamically registered during buff cap)
local AuraCastFrame = CreateFrame("Frame", "DoitePlayerAuras_AuraCast")
AuraCastFrame:SetScript("OnEvent", function()
  -- only care about buffs when at buff cap
  -- int auraCapStatus - bitfield: 1 = buff bar full, 2 = debuff bar full (3 means both)
  local spellId, durationMs, auraCapStatus = arg1, arg8, arg9

  -- double check we are buff capped
  if auraCapStatus == 1 or auraCapStatus == 3 or DoitePlayerAuras.debugBuffCap then
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
  if DoiteBuffData.stackConsumers[spellId] then
    local modifiedBuffName = DoiteBuffData.stackConsumers[spellId].modifiedBuffName
    local stackChange = DoiteBuffData.stackConsumers[spellId].stackChange

    local currentStacks = DoitePlayerAuras.cappedBuffsStacks[modifiedBuffName] or 0

    if currentStacks and stackChange < 0 and currentStacks > 0 then
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

function DoitePlayerAuras.ToggleDebugBuffCap()
  DoitePlayerAuras.debugBuffCap = not DoitePlayerAuras.debugBuffCap

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
    UpdateBuffs()
    UpdateDebuffs()
    print("DoitePlayerAuras: Debug buff cap disabled")
  end
end
