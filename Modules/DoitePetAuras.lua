---------------------------------------------------------------
-- DoitePetAuras.lua
-- Lightweight pet aura cache/helpers for trackpet aura mode
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

local DoitePetAuras = {
  buffs = {},
  debuffs = {},
  buffIds = {},
  debuffIds = {},
  initialized = false
}

_G["DoitePetAuras"] = DoitePetAuras

local function _ClearMap(t)
  for k in pairs(t) do
    t[k] = nil
  end
end

local function _GetSpellNameById(spellId)
  if not spellId then
    return nil
  end

  if GetSpellNameAndRankForId then
    local ok, name = pcall(GetSpellNameAndRankForId, spellId)
    if ok and type(name) == "string" and name ~= "" then
      return name
    end
  end

  if GetSpellRecField then
    local ok2, recName = pcall(GetSpellRecField, spellId, "name")
    if ok2 and type(recName) == "string" and recName ~= "" then
      return recName
    end
  end

  return nil
end

local function _ScanPetAuras()
  _ClearMap(DoitePetAuras.buffs)
  _ClearMap(DoitePetAuras.debuffs)
  _ClearMap(DoitePetAuras.buffIds)
  _ClearMap(DoitePetAuras.debuffIds)

  if not UnitExists("pet") then
    return
  end

  local i = 1
  while i <= 32 do
    local tex, stacks, spellId = UnitBuff("pet", i)
    if not tex then
      break
    end

    if spellId then
      DoitePetAuras.buffIds[spellId] = stacks or 1
      local name = _GetSpellNameById(spellId)
      if name then
        DoitePetAuras.buffs[name] = stacks or 1
      end
    end

    i = i + 1
  end

  i = 1
  while i <= 32 do
    local tex, stacks, _, spellId = UnitDebuff("pet", i)
    if not tex then
      break
    end

    if spellId then
      DoitePetAuras.debuffIds[spellId] = stacks or 1
      local name = _GetSpellNameById(spellId)
      if name then
        DoitePetAuras.debuffs[name] = stacks or 1
      end
    end

    i = i + 1
  end
end

function DoitePetAuras.Refresh()
  _ScanPetAuras()
end

function DoitePetAuras.CanTrack()
  return UnitExists("pet") and true or false
end

function DoitePetAuras.TargetIsPet()
  return UnitExists("pet") and UnitExists("target") and UnitIsUnit("target", "pet") and true or false
end

function DoitePetAuras.HasAura(auraName, auraSpellId, useSpellIdOnly, wantBuff, wantDebuff)
  if not DoitePetAuras.CanTrack() then
    return false
  end

  if useSpellIdOnly == true then
    local sid = tonumber(auraSpellId) or 0
    if sid <= 0 then
      return false
    end
    if wantBuff and DoitePetAuras.buffIds[sid] then
      return true
    end
    if wantDebuff and DoitePetAuras.debuffIds[sid] then
      return true
    end
    return false
  end

  if not auraName or auraName == "" then
    return false
  end

  if wantBuff and DoitePetAuras.buffs[auraName] then
    return true
  end
  if wantDebuff and DoitePetAuras.debuffs[auraName] then
    return true
  end

  return false
end

function DoitePetAuras.GetStacks(auraName, wantDebuff, auraSpellId, useSpellIdOnly)
  if not DoitePetAuras.CanTrack() then
    return nil
  end

  if useSpellIdOnly == true then
    local sid = tonumber(auraSpellId) or 0
    if sid <= 0 then
      return nil
    end
    if wantDebuff then
      return DoitePetAuras.debuffIds[sid]
    end
    return DoitePetAuras.buffIds[sid]
  end

  if not auraName or auraName == "" then
    return nil
  end

  if wantDebuff then
    return DoitePetAuras.debuffs[auraName]
  end
  return DoitePetAuras.buffs[auraName]
end

function DoitePetAuras.GetAuraRemainingSeconds(auraName, auraSpellId, useSpellIdOnly)
  if not DoiteTrack then
    return nil
  end

  if useSpellIdOnly == true then
    if DoiteTrack.GetAuraRemainingSecondsBySpellId then
      local rem = DoiteTrack:GetAuraRemainingSecondsBySpellId(auraSpellId, "pet")
      if rem and rem > 0 then
        return rem
      end
    end
  else
    if DoiteTrack.GetAuraRemainingSecondsByName then
      local rem2 = DoiteTrack:GetAuraRemainingSecondsByName(auraName, "pet")
      if rem2 and rem2 > 0 then
        return rem2
      end
    end
  end

  return nil
end

local f = CreateFrame("Frame", "DoitePetAurasEvents")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("UNIT_PET")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("PLAYER_DEAD")

f:SetScript("OnEvent", function()
  DoitePetAuras.Refresh()
  if DoiteConditions and DoiteConditions.EvaluateAll then
    DoiteConditions:EvaluateAll()
  end
end)

DoitePetAuras.initialized = true
DoitePetAuras.Refresh()
