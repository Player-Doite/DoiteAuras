---------------------------------------------------------------
-- DoiteAuras.lua
-- Simplified WeakAura-style addon for WoW
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

if DoiteAurasFrame then return end

-- SavedVariables init (guarded; do NOT clobber existing data)
DoiteAurasDB = DoiteAurasDB or {}
DoiteAurasDB.spells         = DoiteAurasDB.spells         or {}
DoiteAurasDB.cache          = DoiteAurasDB.cache          or {}
DoiteAurasDB.groupSort      = DoiteAurasDB.groupSort      or {}
DoiteAurasDB.bucketDisabled = DoiteAurasDB.bucketDisabled or {}
DoiteAuras = DoiteAuras or {}

-- Always return a valid name->texture cache table
local function DA_Cache()
  DoiteAurasDB = DoiteAurasDB or {}
  DoiteAurasDB.cache = DoiteAurasDB.cache or {}
  return DoiteAurasDB.cache
end

---------------------------------------------------------------
-- SuperWoW / Nampower / UnitXP SP3 requirement helper
---------------------------------------------------------------
local function DA_GetMissingRequiredMods()
  local missing = {}

  -- SuperWoW: SUPERWOW_VERSION must be a non-empty string
  local hasSuper = (type(SUPERWOW_VERSION) == "string" and SUPERWOW_VERSION ~= "")
  if not hasSuper then
    table.insert(missing, "SuperWoW")
  end

  -- Nampower: GetNampowerVersion() must exist and return numbers
  local hasNampower = false
  if type(GetNampowerVersion) == "function" then
    local ok, maj = pcall(GetNampowerVersion)
    if ok and type(maj) == "number" then
      hasNampower = true
    end
  end
  if not hasNampower then
    table.insert(missing, "Nampower")
  end

  -- UnitXP SP3: pcall(UnitXP, "nop", "nop") must succeed
  local hasUnitXP = false
  if type(UnitXP) == "function" then
    local ok = pcall(UnitXP, "nop", "nop")
    if ok then
      hasUnitXP = true
    end
  end
  if not hasUnitXP then
    table.insert(missing, "UnitXP SP3")
  end

  return missing
end

local function DA_IsHardDisabled()
  return _G["DoiteAuras_HardDisabled"] == true
end

-- Persistent store for group layout computed positions
_G["DoiteGroup_Computed"]       = _G["DoiteGroup_Computed"]       or {}
_G["DoiteGroup_LastLayoutTime"] = _G["DoiteGroup_LastLayoutTime"] or 0

-- ========= Spell Texture Cache (abilities) =========

local function DoiteAuras_RebuildSpellTextureCache()
    local cache = DA_Cache()
    for tab = 1, (GetNumSpellTabs() or 0) do
        local _, _, offset, numSlots = GetSpellTabInfo(tab)
        if numSlots and numSlots > 0 then
            for i = 1, numSlots do
                local idx = offset + i
                local name, rank = GetSpellName(idx, BOOKTYPE_SPELL)
                if not name then break end
                local tex = GetSpellTexture and GetSpellTexture(idx, BOOKTYPE_SPELL)
                if name and tex and cache[name] ~= tex then
                    cache[name] = tex
                end
            end
        end
    end

    -- If already have configured Ability entries, seed their .iconTexture for immediate use
    if DoiteAurasDB.spells then
        for key, data in pairs(DoiteAurasDB.spells) do
            if data and data.type == "Ability" then
                local nm = data.displayName or data.name
                local t  = nm and cache[nm]
                if t then data.iconTexture = t end
            end
        end
    end

    -- Spellbook indices can shift; force a fresh slot lookup next refresh
    if DoiteAuras then
        DoiteAuras._spellSlotCache = nil
    end
end

-- Event hook: rebuild on login/world and whenever the spellbook changes (talent/build swaps)
local _daSpellTex = CreateFrame("Frame", "DoiteSpellTex")
_daSpellTex:RegisterEvent("PLAYER_ENTERING_WORLD")
_daSpellTex:RegisterEvent("SPELLS_CHANGED")
_daSpellTex:SetScript("OnEvent", function()
    if DoiteAuras then
        DoiteAuras._spellSlotCache = nil
    end

    DoiteAuras_RebuildSpellTextureCache()
    if DoiteAuras_RefreshIcons then pcall(DoiteAuras_RefreshIcons) end
end)

-- Title-case function with exceptions for small words (keeps first word capitalized)
-- Special-case Roman numerals like "II", "IV", "VIII", "X" so they stay fully uppercase.
local function TitleCase(str)
    if not str then return "" end
    str = tostring(str)

    local exceptions = {
        ["of"]=true, ["and"]=true, ["the"]=true, ["for"]=true,
        ["in"]=true, ["on"]=true, ["to"]=true, ["a"]=true,
        ["an"]=true, ["with"]=true, ["by"]=true, ["at"]=true
    }

    local function IsRomanNumeralToken(core)
        if not core or core == "" then return false end
        local upper = string.upper(core)
        -- Only Roman numeral characters
        if not string.find(upper, "^[IVXLCDM]+$") then
            return false
        end
        -- Optional: avoid crazy long sequences; ranks are usually short
        if string.len(upper) > 4 then
            return false
        end
        return true
    end

    local result, first = "", true

    for word in string.gfind(str, "%S+") do
        -- If the word starts with "(", force-capitalize the first letter after "(".
        local startsParen = (string.sub(word, 1, 1) == "(")
        local leading     = startsParen and "(" or ""
        local core        = startsParen and string.sub(word, 2) or word

        local lowerCore = string.lower(core or "")
        local upperCore = string.upper(core or "")
        local c         = string.sub(core or "", 1, 1) or ""
        local rest      = string.sub(core or "", 2) or ""

        -- 1) Roman numerals: keep them fully uppercase, everywhere
        if IsRomanNumeralToken(core) then
            result = result .. leading .. upperCore .. " "
            first = false

        else
            -- 2) Normal title-case rules
            if first then
                -- Always capitalize the very first word
                result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
                first = false
            else
                if startsParen then
                    -- First word inside parentheses: force-capitalize regardless of exceptions
                    result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
                elseif exceptions[lowerCore] then
                    -- Normal small-word behavior
                    result = result .. lowerCore .. " "
                else
                    result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
                end
            end
        end
    end

    result = string.gsub(result, "%s+$", "")
    return result
end

-- === Duplicate handling helpers ===
local function BaseKeyFor(data_or_name, typ)
  if type(data_or_name) == "table" then
    local d = data_or_name
    local nm = (d.displayName or d.name or "")
    local tp = (d.type or "Ability")
    return nm .. "_" .. tp
  else
    local nm = tostring(data_or_name or "")
    local tp = tostring(typ or "Ability")
    return nm .. "_" .. tp
  end
end

-- Generate a unique storage key for DB & frames
local function GenerateUniqueKey(name, typ)
  local base = BaseKeyFor(name, typ)
  if not DoiteAurasDB.spells[base] then
    return base, base, 1
  end
  local n = 2
  while DoiteAurasDB.spells[base .. "#" .. tostring(n)] do
    n = n + 1
  end
  return (base .. "#" .. tostring(n)), base, n
end

-- Find siblings (same displayName & type)
local function IterSiblings(name, typ)
  local base = BaseKeyFor(name, typ)
  local function iter(_, last)
    for k, d in pairs(DoiteAurasDB.spells) do
      if k ~= last then
        local bk = BaseKeyFor(d)
        if bk == base then
          return k, d
        end
      end
    end
  end
  return iter, nil, nil
end

-- Tooltip for buff/debuff scanning
local daTip = CreateFrame("GameTooltip", "DoiteAurasTooltip", nil, "GameTooltipTemplate")
daTip:SetOwner(UIParent, "ANCHOR_NONE")

-- Cache tooltip fontstrings once´
local DA_TipLeft = {}
do
    local i = 1
    while i <= 15 do
        DA_TipLeft[i] = getglobal("DoiteAurasTooltipTextLeft" .. i)
        i = i + 1
    end
end

local function GetBuffName(unit, index, debuff)
    daTip:ClearLines()
    if debuff then
        daTip:SetUnitDebuff(unit, index)
    else
        daTip:SetUnitBuff(unit, index)
    end
    return DoiteAurasTooltipTextLeft1:GetText()
end

-- Main frame (layout & sizes)
local frame = CreateFrame("Frame", "DoiteAurasFrame", UIParent)
frame:SetWidth(355)
frame:SetHeight(450)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function() this:StartMoving() end)
frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
frame:Hide()
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 16, edgeSize = 32,
    insets = { left=11, right=12, top=12, bottom=11 }
})
frame:SetBackdropColor(0, 0, 0, 1)
frame:SetBackdropBorderColor(1, 1, 1, 1)
frame:SetFrameStrata("FULLSCREEN_DIALOG")

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -15)
title:SetText("DoiteAuras")

local sep = frame:CreateTexture(nil, "ARTWORK")
sep:SetHeight(1)
sep:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -35)
sep:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -35)
sep:SetTexture(1,1,1)
if sep.SetVertexColor then sep:SetVertexColor(1,1,1,0.25) end

-- Intro text
local intro = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
intro:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)
intro:SetText("Enter the EXACT name or spell ID of the buff or debuff.")

-- Close button
local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -6)
closeBtn:SetScript("OnClick", function() this:GetParent():Hide() end)

-- Import / Export buttons (to the left of the close "X")
local exportBtn = CreateFrame("Button", "DoiteAurasExportButton", frame, "UIPanelButtonTemplate")
exportBtn:SetWidth(60)
exportBtn:SetHeight(20)
exportBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
exportBtn:SetText("Export")
exportBtn:SetScript("OnClick", function()
    if DoiteExport_ShowExportFrame then
        DoiteExport_ShowExportFrame()
    else
        (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffff0000DoiteAuras:|r Export module not loaded.")
    end
end)

local importBtn = CreateFrame("Button", "DoiteAurasImportButton", frame, "UIPanelButtonTemplate")
importBtn:SetWidth(60)
importBtn:SetHeight(20)
importBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
importBtn:SetText("Import")
importBtn:SetScript("OnClick", function()
    if DoiteExport_ShowImportFrame then
        DoiteExport_ShowImportFrame()
    else
        (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffff0000DoiteAuras:|r Export module not loaded.")
    end
end)

-- Input box + Add
local input = CreateFrame("EditBox", "DoiteAurasInput", frame, "InputBoxTemplate")
input:SetWidth(240)
input:SetHeight(20)
input:SetPoint("TOPLEFT", intro, "TOPLEFT", 5, -15)
input:SetAutoFocus(false)

local addBtn = CreateFrame("Button", "DoiteAurasAddBtn", frame, "UIPanelButtonTemplate")
addBtn:SetWidth(60)
addBtn:SetHeight(20)
addBtn:SetPoint("LEFT", input, "RIGHT", 10, 0)
addBtn:SetText("Add")

-- Abilities dropdown (spellbook-based, non-passive)
local abilityDropDown = CreateFrame("Frame", "DoiteAurasAbilityDropDown", frame, "UIDropDownMenuTemplate")
abilityDropDown:SetPoint("TOPLEFT", input, "TOPLEFT", -23, 3) -- tuned to visually overlap input
UIDropDownMenu_Initialize(abilityDropDown, function() end)
UIDropDownMenu_SetWidth(230, abilityDropDown)
UIDropDownMenu_SetText("Select from dropdown", abilityDropDown)
abilityDropDown:Hide()

-- Force the ability dropdown text to be left-aligned
local abilityText  = getglobal("DoiteAurasAbilityDropDownText")
local abilityMiddle = getglobal("DoiteAurasAbilityDropDownMiddle")
if abilityText then
    abilityText:ClearAllPoints()
    if abilityMiddle then
        abilityText:SetPoint("LEFT", abilityMiddle, "LEFT", 10, 2)
    else
        abilityText:SetPoint("LEFT", abilityDropDown, "LEFT", 10, 2)
    end
    abilityText:SetJustifyH("LEFT")
end

-- Items dropdown
local itemDropDown = CreateFrame("Frame", "DoiteAurasItemDropDown", frame, "UIDropDownMenuTemplate")
itemDropDown:SetPoint("TOPLEFT", input, "TOPLEFT", -23, 3) -- tuned to visually overlap input
UIDropDownMenu_Initialize(itemDropDown, function() end)
UIDropDownMenu_SetWidth(230, itemDropDown)
UIDropDownMenu_SetText("Select from dropdown", itemDropDown)
itemDropDown:Hide()

-- Force the item dropdown text to be left-aligned
local itemText  = getglobal("DoiteAurasItemDropDownText")
local itemMiddle = getglobal("DoiteAurasItemDropDownMiddle")
if itemText then
    itemText:ClearAllPoints()
    if itemMiddle then
        itemText:SetPoint("LEFT", itemMiddle, "LEFT", 10, 2)
    else
        itemText:SetPoint("LEFT", itemDropDown, "LEFT", 10, 2)
    end
    itemText:SetJustifyH("LEFT")
end

local barDropDown = CreateFrame("Frame", "DoiteAurasBarDropDown", frame, "UIDropDownMenuTemplate")
barDropDown:SetPoint("TOPLEFT", input, "TOPLEFT", -23, 3)

-- Populate Bars dropdown with static "coming soon" entries
UIDropDownMenu_Initialize(barDropDown, function()
    local info

    info = {}
    info.text = "Healthbar (coming soon)"
    info.func = function()
        UIDropDownMenu_SetText("Healthbar (coming soon)", barDropDown)
    end
    UIDropDownMenu_AddButton(info)

    info = {}
    info.text = "Powerbar (coming soon)"
    info.func = function()
        UIDropDownMenu_SetText("Powerbar (coming soon)", barDropDown)
    end
    UIDropDownMenu_AddButton(info)

    info = {}
    info.text = "Swing/wand timer (coming soon)"
    info.func = function()
        UIDropDownMenu_SetText("Swing/wand timer (coming soon)", barDropDown)
    end
    UIDropDownMenu_AddButton(info)

    info = {}
    info.text = "Castbar (coming soon)"
    info.func = function()
        UIDropDownMenu_SetText("Castbar (coming soon)", barDropDown)
    end
    UIDropDownMenu_AddButton(info)
end)

UIDropDownMenu_SetWidth(230, barDropDown)
UIDropDownMenu_SetText("Select from dropdown", barDropDown)
barDropDown:Hide()

-- Force the bar dropdown text to be left-aligned
local barText  = getglobal("DoiteAurasBarDropDownText")
local barMiddle = getglobal("DoiteAurasBarDropDownMiddle")
if barText then
    barText:ClearAllPoints()
    if barMiddle then
        barText:SetPoint("LEFT", barMiddle, "LEFT", 10, 2)
    else
        barText:SetPoint("LEFT", barDropDown, "LEFT", 10, 2)
    end
    barText:SetJustifyH("LEFT")
end

-- =========================
-- Ability dropdown scanning (spellbook, non-passive)
-- =========================

-- Holds the current ability names shown in the dropdown
local DA_AbilityOptions = {}
local DA_AbilityMenuOffset = 0
local DA_ABILITY_PAGE_SIZE = 20  -- how many real entries per "page"

local function DA_ClearAbilityOptions()
    local n = table.getn(DA_AbilityOptions)
    while n > 0 do
        DA_AbilityOptions[n] = nil
        n = n - 1
    end
end

local function DA_AddAbilityOption(name)
    if not name or name == "" then return end
    local n = table.getn(DA_AbilityOptions)
    local i
    for i = 1, n do
        if DA_AbilityOptions[i] == name then
            return
        end
    end
    DA_AbilityOptions[n + 1] = name
end

-- Helper: close + reopen abilities dropdown on the next frame
local function DA_RepageAbilityDropdown()
    if not abilityDropDown then return end
    local dd = abilityDropDown

    if DA_RunLater then
        DA_RunLater(0.01, function()
            if dd then
                ToggleDropDownMenu(nil, nil, dd)
                ToggleDropDownMenu(nil, nil, dd)
            end
        end)
    else
        ToggleDropDownMenu(nil, nil, dd)
        ToggleDropDownMenu(nil, nil, dd)
    end
end

local function DA_AbilityMenu_Initialize()
    if not abilityDropDown then return end

    local total = table.getn(DA_AbilityOptions)
    local info

    -- Previous page button
    if DA_AbilityMenuOffset > 0 then
        info = {}
        info.text = "|cffffff00<< PREVIOUS PAGE <<|r"
        info.func = function()
            -- Move one page up, clamped at 0
            local newOffset = DA_AbilityMenuOffset - DA_ABILITY_PAGE_SIZE
            if newOffset < 0 then newOffset = 0 end
            DA_AbilityMenuOffset = newOffset

            -- Reopen dropdown with new page
            DA_RepageAbilityDropdown()
        end
        info.keepShownOnClick = 1
        info.notCheckable     = 1
        info.isNotRadio       = 1
        info.checked          = nil
        UIDropDownMenu_AddButton(info)
    end

    local startIndex = DA_AbilityMenuOffset + 1
    local endIndex   = math.min(total, DA_AbilityMenuOffset + DA_ABILITY_PAGE_SIZE)

    local i
    for i = startIndex, endIndex do
        local caption = DA_AbilityOptions[i]
        info = {}
        info.text = caption
        info.func = function()
            UIDropDownMenu_SetText(caption, abilityDropDown)
        end
        UIDropDownMenu_AddButton(info)
    end

    -- Next page button
    if endIndex < total then
        info = {}
        info.text = "|cffffff00>> NEXT PAGE >>|r"
        info.func = function()
            local total = table.getn(DA_AbilityOptions)
            local maxOffset = 0
            if total > DA_ABILITY_PAGE_SIZE then
                maxOffset = total - DA_ABILITY_PAGE_SIZE
            end
            local newOffset = DA_AbilityMenuOffset + DA_ABILITY_PAGE_SIZE
            if newOffset > maxOffset then newOffset = maxOffset end
            DA_AbilityMenuOffset = newOffset

            DA_RepageAbilityDropdown()
        end
        info.keepShownOnClick = 1
        info.notCheckable     = 1
        info.isNotRadio       = 1
        info.checked          = nil
        UIDropDownMenu_AddButton(info)
    end
end

local function DA_RebuildAbilityDropDown()
    if not abilityDropDown then return end

    DA_ClearAbilityOptions()

    local seen = {}

    -- linear scan over spellbook, filter passives by IsPassiveSpell + rank "Passive"
    local i = 1
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then
            break
        end

        local isPassive = false

        if IsPassiveSpell then
            -- best-effort: use IsPassiveSpell if available (signature may differ)
            local ok, passive = pcall(IsPassiveSpell, i, BOOKTYPE_SPELL)
            if ok and passive then
                isPassive = true
            end
        end

        -- Fallback: many passives have "Passive" in the rank string
        if (not isPassive) and rank and string.find(rank, "Passive") then
            isPassive = true
        end

        if (not isPassive) and name ~= "" then
            local lname = string.lower(name or "")
            if not seen[lname] then
                seen[lname] = true
                DA_AddAbilityOption(name)
            end
        end

        i = i + 1
    end

    -- Sort 0–9 A–Z (case-insensitive; ties broken by original)
    table.sort(DA_AbilityOptions, function(a, b)
        local la = string.lower(a or "")
        local lb = string.lower(b or "")
        if la == lb then
            return (a or "") < (b or "")
        end
        return la < lb
    end)

    -- Reset paging to the top and hook custom initializer
    DA_AbilityMenuOffset = 0
    UIDropDownMenu_Initialize(abilityDropDown, DA_AbilityMenu_Initialize)

    -- Reset shown text each time rebuild
    UIDropDownMenu_SetText("Select from dropdown", abilityDropDown)
end

-- =========================
-- Item dropdown scanning (bags + equipped)
-- =========================

-- Holds the current item names shown in the dropdown
local DA_ItemOptions = {}
local DA_ItemMenuOffset = 0
local DA_ITEMMENU_PAGE_SIZE = 20  -- how many real entries per "page"

local function DA_ClearItemOptions()
    local n = table.getn(DA_ItemOptions)
    while n > 0 do
        DA_ItemOptions[n] = nil
        n = n - 1
    end
end

local function DA_AddItemOption(name)
    if not name or name == "" then return end
    -- avoid duplicates by plain name
    local n = table.getn(DA_ItemOptions)
    local i
    for i = 1, n do
        if DA_ItemOptions[i] == name then
            return
        end
    end
    DA_ItemOptions[n + 1] = name
end

-- Check current DoiteAurasTooltip for a line that looks like "Use..." or "consume..."
local function DA_TooltipHasUseOrConsume()
    local i
    for i = 1, 15 do
        local fs = DA_TipLeft[i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if txt then
                local lower = string.lower(txt)
                if string.find(lower, "use:") or string.find(lower, "use ") or string.find(lower, "consume") then
                    return true
                end
            end
        end
    end
    return false
end

-- Scan equipped trinkets + weapons for usable / consumable effects
local function DA_ScanEquippedUsable()
    -- Trinket1 (13), Trinket2 (14), Main hand (16), Off hand (17), Ranged/Wand (18)
    local slots = { 13, 14, 16, 17, 18 }
    local i
    for i = 1, table.getn(slots) do
        local slotId = slots[i]
        if GetInventoryItemLink and GetInventoryItemLink("player", slotId) then
            daTip:ClearLines()
            daTip:SetInventoryItem("player", slotId)

            local nameFS = DoiteAurasTooltipTextLeft1
            local itemName = nameFS and nameFS:GetText()
            if itemName and DA_TooltipHasUseOrConsume() then
                DA_AddItemOption(itemName)
            end
        end
    end
end

-- Scan all bags (0 = backpack, 1–4 = bag slots) for usable / consumable items
local function DA_ScanBagUsable()
    if not GetContainerNumSlots or not GetContainerItemLink then return end

    local bag
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            local slot
            for slot = 1, numSlots do
                if GetContainerItemLink(bag, slot) then
                    daTip:ClearLines()
                    daTip:SetBagItem(bag, slot)

                    local nameFS = DoiteAurasTooltipTextLeft1
                    local itemName = nameFS and nameFS:GetText()
                    if itemName and DA_TooltipHasUseOrConsume() then
                        DA_AddItemOption(itemName)
                    end
                end
            end
        end
    end
end

-- Find the icon texture for a specific item name (case-insensitive)
local function DA_FindItemTextureByName(itemName)
    if not itemName or itemName == "" then return nil end

    local target = string.lower(itemName)

    -- 1) Equipped trinkets + weapons (13,14,16,17,18)
    local slots = { 13, 14, 16, 17, 18 }
    local i
    for i = 1, table.getn(slots) do
        local slotId = slots[i]
        if GetInventoryItemLink and GetInventoryItemLink("player", slotId) then
            daTip:ClearLines()
            daTip:SetInventoryItem("player", slotId)

            local nameFS  = DoiteAurasTooltipTextLeft1
            local tipName = nameFS and nameFS:GetText()
            if tipName and string.lower(tipName) == target then
                if GetInventoryItemTexture then
                    local tex = GetInventoryItemTexture("player", slotId)
                    if tex then return tex end
                end
            end
        end
    end

    -- 2) Bags (0–4)
    if not GetContainerNumSlots or not GetContainerItemLink or not GetContainerItemInfo then
        return nil
    end

    local bag
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            local slot
            for slot = 1, numSlots do
                if GetContainerItemLink(bag, slot) then
                    daTip:ClearLines()
                    daTip:SetBagItem(bag, slot)

                    local nameFS  = DoiteAurasTooltipTextLeft1
                    local tipName = nameFS and nameFS:GetText()
                    if tipName and string.lower(tipName) == target then
                        local tex = GetContainerItemInfo(bag, slot)
                        if tex then return tex end
                    end
                end
            end
        end
    end

    return nil
end

-- Helper: close + reopen dropdown on the next frame
local function DA_RepageItemDropdown()
    if not itemDropDown then return end
    local dd = itemDropDown

    if DA_RunLater then
        DA_RunLater(0.01, function()
            if dd then
                ToggleDropDownMenu(nil, nil, dd)
                ToggleDropDownMenu(nil, nil, dd)
            end
        end)
    else
        ToggleDropDownMenu(nil, nil, dd)
        ToggleDropDownMenu(nil, nil, dd)
    end
end

local function DA_ItemMenu_Initialize()
    if not itemDropDown then return end

    local total = table.getn(DA_ItemOptions)
    local info

    -- Previous page button
    if DA_ItemMenuOffset > 0 then
        info = {}
        info.text = "|cffffff00<< PREVIOUS PAGE <<|r"
        info.func = function()
            -- Move one page up, clamped at 0
            local newOffset = DA_ItemMenuOffset - DA_ITEMMENU_PAGE_SIZE
            if newOffset < 0 then newOffset = 0 end
            DA_ItemMenuOffset = newOffset

            -- Reopen dropdown with new page
            DA_RepageItemDropdown()
        end
        -- pager rows are not real options: no check, no radio, stay non-selected
        info.keepShownOnClick = 1
        info.notCheckable     = 1
        info.isNotRadio       = 1
        info.checked          = nil
        UIDropDownMenu_AddButton(info)
    end

    local startIndex = DA_ItemMenuOffset + 1
    local endIndex   = math.min(total, DA_ItemMenuOffset + DA_ITEMMENU_PAGE_SIZE)

    local i
    for i = startIndex, endIndex do
        local caption = DA_ItemOptions[i]
        info = {}
        info.text = caption
        info.func = function()
            UIDropDownMenu_SetText(caption, itemDropDown)
        end
        -- normal entries: default behaviour (select + close)
        UIDropDownMenu_AddButton(info)
    end

    -- Next page button
    if endIndex < total then
        info = {}
        info.text = "|cffffff00>> NEXT PAGE >>|r"
        info.func = function()
            local total = table.getn(DA_ItemOptions)

            local maxOffset = 0
            if total > DA_ITEMMENU_PAGE_SIZE then
                maxOffset = total - DA_ITEMMENU_PAGE_SIZE
            end
            local newOffset = DA_ItemMenuOffset + DA_ITEMMENU_PAGE_SIZE
            if newOffset > maxOffset then newOffset = maxOffset end
            DA_ItemMenuOffset = newOffset

            DA_RepageItemDropdown()
        end
        info.keepShownOnClick = 1
        info.notCheckable     = 1
        info.isNotRadio       = 1
        info.checked          = nil
        UIDropDownMenu_AddButton(info)
    end
end

local function DA_RebuildItemDropDown()
    if not itemDropDown then return end

    -- constants for headers to keep them consistent everywhere
    local HEADER_TRINKETS = "---EQUIPPED TRINKET SLOTS---"
    local HEADER_WEAPONS  = "---EQUIPPED WEAPON SLOTS---"

    -- 1) Gather raw items into DA_ItemOptions via scans
    DA_ClearItemOptions()
    DA_ScanEquippedUsable()
    DA_ScanBagUsable()

    -- 2) Split out and dedupe, then sort the real items
    local seen  = {}
    local items = {}
    local i
    for i = 1, table.getn(DA_ItemOptions) do
        local nm = DA_ItemOptions[i]
        if nm and nm ~= "" then
            if not seen[nm] then
                seen[nm] = true
                -- headers are added separately, so skip them here
                if nm ~= HEADER_TRINKETS and nm ~= HEADER_WEAPONS then
                    table.insert(items, nm)
                end
            end
        end
    end

    table.sort(items, function(a, b)
        local la = string.lower(a or "")
        local lb = string.lower(b or "")
        if la == lb then
            return (a or "") < (b or "")
        end
        return la < lb
    end)

    -- 3) Rebuild DA_ItemOptions in final display order:
    --    headers first, then sorted items
    DA_ClearItemOptions()
    DA_AddItemOption(HEADER_TRINKETS)
    DA_AddItemOption(HEADER_WEAPONS)
    for i = 1, table.getn(items) do
        DA_AddItemOption(items[i])
    end

    -- 4) Reset paging to the top and hookcustom initializer
    DA_ItemMenuOffset = 0
    UIDropDownMenu_Initialize(itemDropDown, DA_ItemMenu_Initialize)

    -- Reset shown text each time
    UIDropDownMenu_SetText("Select from dropdown", itemDropDown)
end

-- Helper to read current dropdown text
local function DA_GetDropDownText(dd)
    if not dd or not dd.GetName then return nil end
    local n = dd:GetName()
    if not n then return nil end
    local fs = getglobal(n.."Text")
    if fs and fs.GetText then
        return fs:GetText()
    end
    return nil
end

-- Type selector checkboxes
local currentType = "Ability"
local abilityCB, buffCB, debuffCB, itemsCB, barsCB

local function DA_UpdateTypeUI()
    if currentType == "Ability" then
        -- Abilities: use dropdown populated from spellbook (non-passive)
        intro:SetText("Select the ability from the dropdown list (from spellbook).")
        input:Hide()
        if abilityDropDown then
            abilityDropDown:Show()
            -- Text is set/reset by DA_RebuildAbilityDropDown when needed
        end
        if itemDropDown then itemDropDown:Hide() end
        if barDropDown  then barDropDown:Hide()  end
        if addBtn then addBtn:Enable() end

    elseif currentType == "Buff" or currentType == "Debuff" then
        -- Buffs/Debuffs: manual text input
        intro:SetText("Enter the EXACT name or spell ID of the buff or debuff.")
        input:Show()
        if abilityDropDown then abilityDropDown:Hide() end
        if itemDropDown then itemDropDown:Hide() end
        if barDropDown  then barDropDown:Hide()  end
        if addBtn then addBtn:Enable() end

    elseif currentType == "Item" then
        intro:SetText("Select the item or bar from the dropdown list.")
        input:Hide()
        if abilityDropDown then abilityDropDown:Hide() end
        if itemDropDown then
            itemDropDown:Show()
            UIDropDownMenu_SetText("Select from dropdown", itemDropDown)
        end
        if barDropDown then barDropDown:Hide() end
        if addBtn then addBtn:Enable() end

    elseif currentType == "Bar" then
        intro:SetText("Select the item or bar from the dropdown list.")
        input:Hide()
        if abilityDropDown then abilityDropDown:Hide() end
        if barDropDown then
            barDropDown:Show()
            UIDropDownMenu_SetText("Select from dropdown", barDropDown)
        end
        if itemDropDown then itemDropDown:Hide() end
        if addBtn then addBtn:Disable() end
    end
end

abilityCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
abilityCB:SetWidth(20); abilityCB:SetHeight(20)
abilityCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 0, -3)
abilityCB.text = abilityCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
abilityCB.text:SetPoint("LEFT", abilityCB, "RIGHT", 2, 0)
abilityCB.text:SetText("Abilities")

buffCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
buffCB:SetWidth(20); buffCB:SetHeight(20)
buffCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 65, -3)
buffCB.text = buffCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
buffCB.text:SetPoint("LEFT", buffCB, "RIGHT", 2, 0)
buffCB.text:SetText("Buffs")

debuffCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
debuffCB:SetWidth(20); debuffCB:SetHeight(20)
debuffCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 120, -3)
debuffCB.text = debuffCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
debuffCB.text:SetPoint("LEFT", debuffCB, "RIGHT", 2, 0)
debuffCB.text:SetText("Debuffs")

-- Items checkbox
itemsCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
itemsCB:SetWidth(20); itemsCB:SetHeight(20)
itemsCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 185, -3)
itemsCB.text = itemsCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
itemsCB.text:SetPoint("LEFT", itemsCB, "RIGHT", 2, 0)
itemsCB.text:SetText("Items")

-- Bars checkbox (to the right of Items)
barsCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
barsCB:SetWidth(20); barsCB:SetHeight(20)
barsCB:SetPoint("TOPLEFT", input, "BOTTOMLEFT", 240, -3)
barsCB.text = barsCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
barsCB.text:SetPoint("LEFT", barsCB, "RIGHT", 2, 0)
barsCB.text:SetText("Bars")

abilityCB:SetScript("OnClick", function()
    abilityCB:SetChecked(true)
    buffCB:SetChecked(false)
    debuffCB:SetChecked(false)
    if itemsCB then itemsCB:SetChecked(false) end
    if barsCB  then barsCB:SetChecked(false)  end
    currentType = "Ability"
    DA_UpdateTypeUI()
    -- Re-scan spellbook each time Abilities is (re)selected (for quick respecs)
    if DA_RebuildAbilityDropDown then
        DA_RebuildAbilityDropDown()
    end
end)

buffCB:SetScript("OnClick", function()
    abilityCB:SetChecked(false)
    buffCB:SetChecked(true)
    debuffCB:SetChecked(false)
    if itemsCB then itemsCB:SetChecked(false) end
    if barsCB  then barsCB:SetChecked(false)  end
    currentType = "Buff"
    DA_UpdateTypeUI()
end)

debuffCB:SetScript("OnClick", function()
    abilityCB:SetChecked(false)
    buffCB:SetChecked(false)
    debuffCB:SetChecked(true)
    if itemsCB then itemsCB:SetChecked(false) end
    if barsCB  then barsCB:SetChecked(false)  end
    currentType = "Debuff"
    DA_UpdateTypeUI()
end)

itemsCB:SetScript("OnClick", function()
    if not itemsCB:GetChecked() then
        -- prevent "nothing selected": keep it checked if Item is current
        if currentType == "Item" then
            itemsCB:SetChecked(true)
            return
        end
    end

    abilityCB:SetChecked(false)
    buffCB:SetChecked(false)
    debuffCB:SetChecked(false)
    itemsCB:SetChecked(true)
    if barsCB then barsCB:SetChecked(false) end

    currentType = "Item"
    DA_UpdateTypeUI()

    -- Build / refresh the dropdown from bags + equipped items
    DA_RebuildItemDropDown()
end)

barsCB:SetScript("OnClick", function()
    if not barsCB:GetChecked() then
        if currentType == "Bar" then
            barsCB:SetChecked(true)
            return
        end
    end

    abilityCB:SetChecked(false)
    buffCB:SetChecked(false)
    debuffCB:SetChecked(false)
    if itemsCB then itemsCB:SetChecked(false) end
    barsCB:SetChecked(true)
    currentType = "Bar"
    DA_UpdateTypeUI()
end)

frame:SetScript("OnShow", function()
    abilityCB:SetChecked(true)
    buffCB:SetChecked(false)
    debuffCB:SetChecked(false)
    if itemsCB then itemsCB:SetChecked(false) end
    if barsCB  then barsCB:SetChecked(false)  end
    currentType = "Ability"
    DA_UpdateTypeUI()
    -- On open (/da or minimap), rebuild the ability dropdown from the current spellbook
    if DA_RebuildAbilityDropDown then
        DA_RebuildAbilityDropDown()
    end
end)

-- Scrollable container
local listContainer = CreateFrame("Frame", nil, frame)
listContainer:SetWidth(300)
listContainer:SetHeight(260)
listContainer:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -5, -25)
listContainer:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16 })
listContainer:SetBackdropColor(0,0,0,0.7)

local scrollFrame = CreateFrame("ScrollFrame", "DoiteAurasScroll", listContainer, "UIPanelScrollFrameTemplate")
-- Slightly wider & closer to the border so it feels less "inset"
scrollFrame:SetWidth(290)
scrollFrame:SetHeight(250)
scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 5, -5)

local listContent = CreateFrame("Frame", "DoiteAurasListContent", scrollFrame)
listContent:SetWidth(290)
listContent:SetHeight(252)
scrollFrame:SetScrollChild(listContent)

-- Guide text
local guide = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
guide:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 20)
guide:SetWidth(315)
guide:SetJustifyH("LEFT")
if guide.SetTextColor then guide:SetTextColor(0.7,0.7,0.7) end
guide:SetText("Guide: DoiteAuras shows only what matters—abilities, buffs, debuffs, items, or bars—when you actually need them. Add an icon or bar, pick its type, and define when it appears using simple conditions like cooldown, aura state, combat, or target. Everything updates automatically, remembers textures once seen, and keeps your UI clean and reactive.")

-- storage
local spellButtons, icons, groupHeaders = {}, {}, {}

function DoiteAuras_GetIconFrame(key)
    if not key then return nil end
    local f = icons and icons[key]
    if f then return f end

    f = _G["DoiteIcon_" .. key]
    if f and icons then
        icons[key] = f
    end
    return f
end

local function GetIconLayout(key)
    if DoiteDB and DoiteDB.icons and DoiteDB.icons[key] then
        return DoiteDB.icons[key]
    end
    return nil
end

-- helper to get data
local function GetSpellData(key)
  if not DoiteAurasDB.spells[key] then
    DoiteAurasDB.spells[key] = {}
  end
  return DoiteAurasDB.spells[key]
end

-- Helpers
local function GetOrderedSpells()
    local list = {}
    for key, data in pairs(DoiteAurasDB.spells) do
        table.insert(list, { key = key, data = data, order = data.order or 999 })
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

-- One shared comparator (avoids allocating a new closure in hot paths that sort by order).
if DoiteAuras and not DoiteAuras._cmpSpellKeyByOrder then
    DoiteAuras._cmpSpellKeyByOrder = function(a, b)
        local da = DoiteAurasDB.spells[a]
        local db = DoiteAurasDB.spells[b]
        local oa = (da and da.order) or 999
        local ob = (db and db.order) or 999
        return oa < ob
    end
end

-- small helpers for group-aware list building and movement
local function DA_IsGrouped(data)
    if not data then return false end
    if not data.group or data.group == "" or data.group == "no" then return false end
    return true
end

local function DA_ParseGroupIndex(groupName)
    if not groupName or type(groupName) ~= "string" then return 9999 end
    local _, _, num = string.find(groupName, "[Gg]roup%s*(%d+)")
    if num then
        local n = tonumber(num)
        if n then return n end
    end
    return 9999
end

-- category helper for ungrouped icons (shared with DoiteEdit)
local function DA_GetCategoryForEntry(entry)
    if not entry or not entry.data then return nil end
    local d = entry.data

    -- Prefer category stored on the DoiteAuras spell data itself
    local cat = d.category

    -- Fallback: look at legacy DoiteDB.icons if present
    if (not cat or cat == "" or cat == "no") and DoiteDB and DoiteDB.icons and DoiteDB.icons[entry.key] then
        cat = DoiteDB.icons[entry.key].category
    end

    if cat and cat ~= "" and cat ~= "no" then
        return tostring(cat)
    end
    return nil
end

-- Per-group sort mode helper ("prio" or "time", default "prio")
local function DA_GetGroupSortMode(groupName)
    if not DoiteAurasDB then DoiteAurasDB = {} end
    DoiteAurasDB.groupSort = DoiteAurasDB.groupSort or {}

    if not groupName or groupName == "" then
        return "prio"
    end

    local mode = DoiteAurasDB.groupSort[groupName]
    if mode ~= "time" then
        mode = "prio"
    end
    DoiteAurasDB.groupSort[groupName] = mode
    return mode
end

-- Shared helpers for per-bucket Disable (groups, categories, ungrouped)
local function DA_GetBucketKeyForHeaderEntry(entry)
    if not entry then return nil end
    if entry.kind == "group" then
        return entry.groupName
    elseif entry.kind == "category" then
        return entry.groupName
    elseif entry.kind == "ungrouped" then
        return "Ungrouped"
    end
    return nil
end

local function DA_GetBucketKeyForCandidate(entry)
    if not entry or not entry.data then return nil end
    local d = entry.data

    -- Grouped entries: bucket is the group name.
    if DA_IsGrouped(d) then
        return d.group
    end

    -- Ungrouped: use the same category logic as DA_BuildDisplayList.
    local dummy = { key = entry.key, data = d }
    local cat = DA_GetCategoryForEntry(dummy)
    if cat and cat ~= "" then
        return cat
    end

    -- Plain ungrouped
    return "Ungrouped"
end

local function DA_IsBucketDisabled(bucketKey)
    if not bucketKey then return false end
    if not DoiteAurasDB or not DoiteAurasDB.bucketDisabled then return false end
    return DoiteAurasDB.bucketDisabled[bucketKey] == true
end

local function DoiteAuras_IsKeyDisabled(key)
    if not key or not DoiteAurasDB or not DoiteAurasDB.spells then return false end
    local data = DoiteAurasDB.spells[key]
    if not data then return false end

    -- Reuse existing bucket logic
    local entry = { key = key, data = data }
    local bucketKey = DA_GetBucketKeyForCandidate(entry)
    if not bucketKey then return false end

    return DA_IsBucketDisabled(bucketKey)
end
_G["DoiteAuras_IsKeyDisabled"] = DoiteAuras_IsKeyDisabled

-- When the last icon in a group/category is removed, clear
local function DA_CleanupEmptyGroupAndCategory(groupName, categoryName)
    if not DoiteAurasDB or not DoiteAurasDB.spells then
        return
    end

    -- Normalize sentinels
    if groupName == "" or groupName == "no" then
        groupName = nil
    end
    if categoryName == "" or categoryName == "no" then
        categoryName = nil
    end

    if not groupName and not categoryName then
        return
    end

    local hasGroup = false
    local hasCategory = false

    -- Scan remaining icons to see if any still reference this group/category
    local k, d
    for k, d in pairs(DoiteAurasDB.spells) do
        if d then
            if groupName and not hasGroup and d.group == groupName then
                hasGroup = true
            end
            if categoryName and not hasCategory and d.category == categoryName then
                hasCategory = true
            end
            if (not groupName or hasGroup) and (not categoryName or hasCategory) then
                break
            end
        end
    end

    -- If no icons left in this group: drop its sort mode + disabled flag
    if groupName and not hasGroup then
        if DoiteAurasDB.groupSort then
            DoiteAurasDB.groupSort[groupName] = nil
        end
        if DoiteAurasDB.bucketDisabled then
            DoiteAurasDB.bucketDisabled[groupName] = nil
        end
    end

    -- If no icons left with this category: remove it from the global list
    if categoryName and not hasCategory then
        local list = DoiteAurasDB.categories
        if list then
            local i = 1
            local n = table.getn(list)
            while i <= n do
                if list[i] == categoryName then
                    table.remove(list, i)
                    n = n - 1
                else
                    i = i + 1
                end
            end
        end

        if DoiteAurasDB.bucketDisabled then
            DoiteAurasDB.bucketDisabled[categoryName] = nil
        end
    end
end

local function DA_BuildDisplayList(ordered)
    local groupedByName      = {}
    local groupOrderList     = {}
    local categorizedByName  = {}
    local categoryOrderList  = {}
    local ungrouped          = {}

    local i
    for i = 1, table.getn(ordered) do
        local entry = ordered[i]
        local d     = entry.data
        if DA_IsGrouped(d) then
            local g = d.group
            if not groupedByName[g] then
                groupedByName[g] = {}
                table.insert(groupOrderList, g)
            end
            table.insert(groupedByName[g], entry)
        else
            -- Ungrouped: split into categories vs plain ungrouped
            local cat = DA_GetCategoryForEntry(entry)
            if cat then
                if not categorizedByName[cat] then
                    categorizedByName[cat] = {}
                    table.insert(categoryOrderList, cat)
                end
                table.insert(categorizedByName[cat], entry)
            else
                table.insert(ungrouped, entry)
            end
        end
    end

    -- sort groups by "Group N" numeric index when possible, otherwise by name
    table.sort(groupOrderList, function(a, b)
        local ia = DA_ParseGroupIndex(a)
        local ib = DA_ParseGroupIndex(b)
        if ia ~= ib then
            return ia < ib
        end
        return tostring(a or "") < tostring(b or "")
    end)

    -- sort categories in 0–9 A–Z order (case-insensitive)
    table.sort(categoryOrderList, function(a, b)
        local la = string.lower(a or "")
        local lb = string.lower(b or "")
        if la == lb then
            return (a or "") < (b or "")
        end
        return la < lb
    end)

    -- Stamp per-bucket index/total for category + ungrouped
    local _, catName
    for _, catName in ipairs(categoryOrderList) do
        local list = categorizedByName[catName]
        local n = table.getn(list or {})
        local j
        for j = 1, n do
            local e = list[j]
            e._bucketName  = catName
            e._bucketIndex = j
            e._bucketTotal = n
        end
    end

    local unTotal = table.getn(ungrouped)
    if unTotal > 0 then
        local j
        for j = 1, unTotal do
            local e = ungrouped[j]
            e._bucketName  = "Ungrouped"
            e._bucketIndex = j
            e._bucketTotal = unTotal
        end
    end

    local display = {}

    local _, groupName
    for _, groupName in ipairs(groupOrderList) do
        table.insert(display, { isHeader = true, groupName = groupName, kind = "group" })
        local list = groupedByName[groupName]
        local j
        for j = 1, table.getn(list) do
            table.insert(display, list[j])
        end
    end

    for _, catName in ipairs(categoryOrderList) do
        table.insert(display, { isHeader = true, groupName = catName, kind = "category" })
        local list = categorizedByName[catName]
        local j
        for j = 1, table.getn(list) do
            table.insert(display, list[j])
        end
    end

    local showUngroupedHeader = false
    if unTotal > 0 and (table.getn(groupOrderList) > 0 or table.getn(categoryOrderList) > 0) then
        showUngroupedHeader = true
    end

    if showUngroupedHeader then
        table.insert(display, { isHeader = true, groupName = "Ungrouped/Uncategorized", kind = "ungrouped" })
    end

    local j
    for j = 1, unTotal do
        table.insert(display, ungrouped[j])
    end

    return display
end

-- Move an entry within its group only; returns true if a swap occurred
local function DA_MoveOrderWithinGroup(key, direction)
    local data = DoiteAurasDB.spells[key]
    if not DA_IsGrouped(data) then return false end

    local grp = data.group
    local ordered = GetOrderedSpells()
    local groupMembers = {}
    local i

    -- Collect all members of this group in order[]
    for i = 1, table.getn(ordered) do
        local e = ordered[i]
        if e.data and e.data.group == grp then
            table.insert(groupMembers, e)
        end
    end

    local idx = nil
    local n   = table.getn(groupMembers)
    for i = 1, n do
        if groupMembers[i].key == key then
            idx = i
            break
        end
    end
    if not idx then return false end

    if direction == "up" then
        -- move towards the start of the group
        if idx <= 1 then return false end
        local swapKey = groupMembers[idx - 1].key
        local tmp = DoiteAurasDB.spells[key].order
        DoiteAurasDB.spells[key].order     = DoiteAurasDB.spells[swapKey].order
        DoiteAurasDB.spells[swapKey].order = tmp
        return true

    elseif direction == "down" then
        -- move towards the end of the group
        if idx >= n then return false end
        local swapKey = groupMembers[idx + 1].key
        local tmp = DoiteAurasDB.spells[key].order
        DoiteAurasDB.spells[key].order     = DoiteAurasDB.spells[swapKey].order
        DoiteAurasDB.spells[swapKey].order = tmp
        return true
    end

    return false
end

-- Move an ungrouped entry within its category bucket (or plain Ungrouped) only
local function DA_MoveOrderWithinCategoryOrUngrouped(key, direction)
    if not key then return false end
    local data = DoiteAurasDB.spells[key]
    if not data or DA_IsGrouped(data) then return false end

    -- Determine this entry's bucket name: its category or "Ungrouped"
    local dummyEntry = { key = key, data = data }
    local cat = DA_GetCategoryForEntry(dummyEntry)
    local bucketName = cat or "Ungrouped"

    local ordered = GetOrderedSpells()
    local bucket = {}
    local i

    -- Collect all ungrouped entries that share the same bucket
    for i = 1, table.getn(ordered) do
        local e = ordered[i]
        local d = e.data
        if d and not DA_IsGrouped(d) then
            local bc = DA_GetCategoryForEntry(e)
            local bname = bc or "Ungrouped"
            if bname == bucketName then
                table.insert(bucket, e)
            end
        end
    end

    local idx, n = nil, table.getn(bucket)
    for i = 1, n do
        if bucket[i].key == key then
            idx = i
            break
        end
    end
    if not idx then return false end

    if direction == "up" then
        if idx <= 1 then return false end
        local swapKey = bucket[idx - 1].key
        local tmp = DoiteAurasDB.spells[key].order
        DoiteAurasDB.spells[key].order     = DoiteAurasDB.spells[swapKey].order
        DoiteAurasDB.spells[swapKey].order = tmp
        return true

    elseif direction == "down" then
        if idx >= n then return false end
        local swapKey = bucket[idx + 1].key
        local tmp = DoiteAurasDB.spells[key].order
        DoiteAurasDB.spells[key].order     = DoiteAurasDB.spells[swapKey].order
        DoiteAurasDB.spells[swapKey].order = tmp
        return true
    end

    return false
end

-- Throttle RefreshIcons() to avoid recursive layout overrides
local _lastRefresh = 0
local function _CanRunRefresh()
    local now = GetTime and GetTime() or 0
    if now - _lastRefresh < 0.1 then return false end
    _lastRefresh = now
    return true
end

local function RebuildOrder()
    local ordered = GetOrderedSpells()
    for i=1, table.getn(ordered) do DoiteAurasDB.spells[ordered[i].key].order = i end
end

local function FindSpellBookSlot(spellName)
    if not spellName or spellName == "" then return nil end

    -- Prefer Nampower fast lookup when available
    if type(GetSpellSlotTypeIdForName) == "function" then
        local ok, slot, bookType = pcall(GetSpellSlotTypeIdForName, spellName)
        if ok and slot and slot > 0 and (bookType == "spell" or bookType == "pet" or bookType == "unknown") then
            return slot
        end
    end

    -- Fallback: legacy full spellbook scan (should almost never run with Nampower present)
    if not GetNumSpellTabs or not GetSpellTabInfo or not GetSpellName then
        return nil
    end

    for tab = 1, (GetNumSpellTabs() or 0) do
        local _, _, offset, numSlots = GetSpellTabInfo(tab)
        if numSlots and numSlots > 0 then
            for i = 1, numSlots do
                local idx  = offset + i
                local name = GetSpellName(idx, BOOKTYPE_SPELL)
                if name == spellName then
                    return idx
                end
            end
        end
    end
    return nil
end

-- Buff/Debuff check via tooltip
local function FindPlayerBuff(name)
    local i=1
    while true do
        local bname = GetBuffName("player", i, false)
        if not bname then break end
        if bname == name then
            local tex = UnitBuff("player", i)
            return true, tex
        end
        i=i+1
    end
    return false,nil
end

local function FindPlayerDebuff(name)
    local i=1
    while true do
        local dname = GetBuffName("player", i, true)
        if not dname then break end
        if dname == name then
            local tex = UnitDebuff("player", i)
            return true, tex
        end
        i=i+1
    end
    return false,nil
end

-- Create or update icon *structure only* (no positioning or texture changes here)
local function CreateOrUpdateIcon(key, layer)
    local globalName = "DoiteIcon_" .. key
    local f = _G[globalName]
    if not f then
        f = CreateFrame("Frame", globalName, UIParent)
        f:SetFrameStrata("MEDIUM")
        -- default size; actual sizing applied in RefreshIcons
        f:SetWidth(36)
        f:SetHeight(36)
        f:EnableMouse(false)
        f:SetMovable(false)

        -- icon texture (created once)
        f.icon = f:CreateTexture(nil, "BACKGROUND")
        f.icon:SetAllPoints(f)

        -- optional count text (created once)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
        fs:SetText("")
        f.count = fs
    end

    -- Wrap Show() exactly once so bucket Disable always wins
    if not f._daOrigShow then
        f._daOrigShow = f.Show
        f._daOrigHide = f.Hide

        f.Show = function(self)
            local blocked = false
            if DoiteAuras_IsKeyDisabled then
                blocked = DoiteAuras_IsKeyDisabled(key)
            end

            if blocked then
                -- Force hidden even if someone tries to show it
                if self._daOrigHide then
                    self._daOrigHide(self)
                else
                    self:Hide()
                end
                return
            end

            if self._daOrigShow then
                self._daOrigShow(self)
            end
        end
    end

    -- cache locally as before
    icons[key] = f
    if layer then f:SetFrameLevel(layer) end

    return f
end

-- Refresh icons (group-aware)
local function RefreshIcons()
    if DA_IsHardDisabled() then
        -- Make sure all existing icon frames stay hidden
        if icons then
            for _, f in pairs(icons) do
                if f and f.Hide then f:Hide() end
            end
        end
        return
    end
    if not _CanRunRefresh() then return end
    -- Build a sorted key list by "order" without allocating {key,data,order} tables each refresh.
    local keyList = DoiteAuras._orderedKeyList
    if not keyList then
        keyList = {}
        DoiteAuras._orderedKeyList = keyList
    end

    local oldKeyN = table.getn(keyList)
    local total = 0
    for key in pairs(DoiteAurasDB.spells) do
        total = total + 1
        keyList[total] = key
    end
    for i = total + 1, oldKeyN do
        keyList[i] = nil
    end

    if DoiteAuras._cmpSpellKeyByOrder then
        table.sort(keyList, DoiteAuras._cmpSpellKeyByOrder)
    else
        -- Fallback (should not happen if Patch 1 applied)
        table.sort(keyList, function(a, b)
            local da = DoiteAurasDB.spells[a]
            local db = DoiteAurasDB.spells[b]
            local oa = (da and da.order) or 999
            local ob = (db and db.order) or 999
            return oa < ob
        end)
    end

    -- Candidates + pool (internal only) to avoid per-refresh tables
    local candidates = DoiteAuras._refreshCandidates
    if not candidates then
        candidates = {}
        DoiteAuras._refreshCandidates = candidates
    end
    local pool = DoiteAuras._refreshCandidatePool
    if not pool then
        pool = {}
        DoiteAuras._refreshCandidatePool = pool
    end

    local oldN = table.getn(candidates)
    local n = 0

    -- Cache table is stable; avoid re-calling DA_Cache() per entry
    local cache = DA_Cache()

    -- Cache spellbook slot per displayName (cleared on SPELLS_CHANGED via _daSpellTex)
    local slotCache = DoiteAuras._spellSlotCache
    if not slotCache then
        slotCache = {}
        DoiteAuras._spellSlotCache = slotCache
    end

    -- Build leader-size map so grouped followers can inherit the leader's size
    local leaderSizeByGroup = DoiteAuras._leaderSizeByGroup
    if not leaderSizeByGroup then
        leaderSizeByGroup = {}
        DoiteAuras._leaderSizeByGroup = leaderSizeByGroup
    else
        local k
        for k in pairs(leaderSizeByGroup) do
            leaderSizeByGroup[k] = nil
        end
    end

    for i = 1, total do
        local key  = keyList[i]
        local data = DoiteAurasDB.spells[key]
        if data and data.group and data.group ~= "" and data.group ~= "no" and data.isLeader == true then
            leaderSizeByGroup[data.group] = (data.iconSize or data.size) or 36
        end
    end

    -- Step 1: collect lightweight icon state (no extra combat logic – DoiteConditions owns that)
    for i = 1, total do
        local key  = keyList[i]
        local data = DoiteAurasDB.spells[key]
        local typ  = data and data.type or "Ability"

        local displayName = (data and (data.displayName or data.name)) or key

        -- Start from any cached/saved texture
        local tex = cache[displayName]
        if not tex and data and data.iconTexture then
            tex = data.iconTexture
        end

        -- For Abilities only: single cheap fallback via spell slot (Nampower-accelerated)
        if not tex and typ == "Ability" then
            local slot = slotCache[displayName]
            if slot == nil then
                slot = FindSpellBookSlot(displayName)
                slotCache[displayName] = slot or false
            elseif slot == false then
                slot = nil
            end

            if slot and GetSpellTexture then
                tex = GetSpellTexture(slot, BOOKTYPE_SPELL)
            end
        end

        -- Persist texture back into cache + DB once its known
        if tex then
            cache[displayName] = tex
            if data and not data.iconTexture then
                data.iconTexture = tex
            end
        end

        -- Show/hide intent comes solely from DoiteConditions via icon flags
        local f = (DoiteAuras_GetIconFrame and DoiteAuras_GetIconFrame(key)) or _G["DoiteIcon_" .. key]
        local wants = false
        if f then
            wants = (f._daShouldShow == true) or (f._daSliding == true)
        end

        n = n + 1
        local candidate = pool[n]
        if not candidate then
            candidate = {}
            pool[n] = candidate
        end

        -- Overwrite all downstream-used fields so reuse can't leak state
        candidate.key  = key
        candidate.data = data
        candidate.show = wants
        candidate.tex  = tex
        do
            local sz = (data and (data.iconSize or data.size)) or 36
            if data and data.group and data.group ~= "" and data.group ~= "no" and (data.isLeader ~= true) then
                local ls = leaderSizeByGroup and leaderSizeByGroup[data.group]
                if ls then
                    sz = ls
                end
            end
            candidate.size = sz
        end
        candidate._computedPos = nil

        -- Stamp the logical bucket this icon belongs to (group/category/ungrouped)
        candidate.bucketKey = DA_GetBucketKeyForCandidate(candidate)

        candidates[n] = candidate
    end

    -- Trim old references so candidates[] doesn't keep stale pooled entries alive
    for i = n + 1, oldN do
        candidates[i] = nil
    end

    -- Step 2: ensure icons exist first, then apply group layout once
    for _, entry in ipairs(candidates) do
        if not (DoiteAuras_GetIconFrame and DoiteAuras_GetIconFrame(entry.key)) then
            CreateOrUpdateIcon(entry.key, 36)
        end
    end

    -- exclude icons in disabled buckets so groups don't account for them
    local layoutCandidates = candidates
    if DoiteGroup and DoiteGroup.ApplyGroupLayout then
        local lc = DoiteAuras._layoutCandidates
        if not lc then
            lc = {}
            DoiteAuras._layoutCandidates = lc
        end

        local oldLC = table.getn(lc)
        local nLC = 0
        for _, entry in ipairs(candidates) do
            local bkey = entry.bucketKey
            if not (bkey and DA_IsBucketDisabled(bkey)) then
                nLC = nLC + 1
                lc[nLC] = entry
            end
        end
        for i = nLC + 1, oldLC do
            lc[i] = nil
        end

        layoutCandidates = lc
    end

    if DoiteGroup and not _G["DoiteGroup_LayoutInProgress"] and DoiteGroup.ApplyGroupLayout then
        pcall(DoiteGroup.ApplyGroupLayout, layoutCandidates)
    end
	
	-- Persist the computed layout so future refresh passes keep using it
	do
		local map = _G["DoiteGroup_Computed"]
		local now = (GetTime and GetTime()) or 0
		for _, e in ipairs(candidates) do
			local d = e.data
			if d and d.group and d.group ~= "" and d.group ~= "no" and e._computedPos then
				map[d.group] = map[d.group] or {}
				local list = map[d.group]

				-- Update in-place to avoid allocating new tables each refresh
				local found = false
				for i = 1, table.getn(list) do
					local li = list[i]
					if li and li.key == e.key then
						li.key = e.key
						local p = li._computedPos
						if not p then
							p = {}
							li._computedPos = p
						end
						p.x = e._computedPos.x
						p.y = e._computedPos.y
						p.size = e._computedPos.size
						found = true
						break
					end
				end

				if not found then
					-- First time this key is seen in this group: create once (same data shape as before)
					table.insert(list, { key = e.key, _computedPos = {
						x = e._computedPos.x, y = e._computedPos.y, size = e._computedPos.size
					}})
				end
			end
		end
		_G["DoiteGroup_LastLayoutTime"] = now
	end

    -- Step 3: create/update frames and apply positions (single place)
    if _G["DoiteAuras_RefreshInProgress"] then return end
    _G["DoiteAuras_RefreshInProgress"] = true

    local cache = DA_Cache()

    -- Track which keys were processed this refresh, so removed icons (that previously visible) get hidden immediately.
    local used = DoiteAuras._iconsUsed
    if not used then
        used = {}
        DoiteAuras._iconsUsed = used
    else
        local k
        for k in pairs(used) do
            used[k] = nil
        end
    end

    for _, entry in ipairs(candidates) do
        local key, data = entry.key, entry.data
        if key then
            used[key] = true
        end

        -- Prefer the local icons[] cache to avoid per-icon string concat + _G lookup
        local f = (icons and icons[key]) or nil
        if not f then
            -- Rare fallback: pick up an existing global frame if icons[] was reset
            f = _G["DoiteIcon_" .. key]
            if f and icons then
                icons[key] = f
            end
        end

        if not f then
            f = CreateOrUpdateIcon(key, 36)
        end

        -- compute final pos/size (group-aware, sticky)
        local posX, posY, size
        local isGrouped = (data and data.group and data.group ~= "" and data.group ~= "no")
        local isLeader  = (data and data.isLeader == true)

        -- 1) Prefer the freshly computed position (if present on this entry)
        if entry._computedPos then
            posX = entry._computedPos.x
            posY = entry._computedPos.y
            size = entry._computedPos.size

        -- 2) Otherwise prefer the persisted computed layout from the last layout tick
        elseif isGrouped and _G["DoiteGroup_Computed"] and _G["DoiteGroup_Computed"][data.group] then
            local list = _G["DoiteGroup_Computed"][data.group]
            for i = 1, table.getn(list) do
                local ge = list[i]
                if ge.key == key and ge._computedPos then
                    posX = ge._computedPos.x
                    posY = ge._computedPos.y
                    size = ge._computedPos.size
                    break
                end
            end
        end

        if not posX then
            if isGrouped and not isLeader then
                -- keep current point; but size must follow leader when grouped
                local currentSize = (data and (data.iconSize or data.size)) or 36
                if leaderSizeByGroup and data and data.group then
                    local ls = leaderSizeByGroup[data.group]
                    if ls then
                        currentSize = ls
                    end
                end
                size = size or currentSize
                -- DO NOT SetPoint here for follower without computed pos (avoid snap-back)
            else
                -- ungrouped or leader: use saved offsets
                posX = (data and (data.offsetX or data.x)) or 0
                posY = (data and (data.offsetY or data.y)) or 0
                size = size or (data and (data.iconSize or data.size)) or 36
            end
        end

        f:SetScale((data and data.scale) or 1)
        f:SetAlpha((data and data.alpha) or 1)
        f:SetWidth(size); f:SetHeight(size)

        -- Do not re-anchor while a slide preview owns the frame for this tick
        if not f._daSliding then
            if posX ~= nil and posY ~= nil then
                f:ClearAllPoints()
                f:SetPoint("CENTER", UIParent, "CENTER", posX, posY)
            end
        end

        -- Texture handling (with saved iconTexture fallback; no extra game queries here)
        local displayName = (data and (data.displayName or data.name)) or key
        local texToUse    = entry.tex
                          or cache[displayName]
                          or (data and data.iconTexture)

        if texToUse then
            cache[displayName] = texToUse
            if data and not data.iconTexture then
                data.iconTexture = texToUse
            end
        end

        f.icon:SetTexture(texToUse or "Interface\\Icons\\INV_Misc_QuestionMark")

        -- Visibility: conditions OR slide … but the group limit and bucket Disable have final say
        local wantsFromConditions = (f._daShouldShow == true)
        local wantsFromSlide      = (f._daSliding == true)
        local blockedByGroup      = (f._daBlockedByGroup == true)

        -- Per-bucket Disable (group/category/ungrouped)
        local blockedByBucket = false
        if entry.bucketKey then
            blockedByBucket = DA_IsBucketDisabled(entry.bucketKey)
        end

        local shouldBeVisible = (wantsFromConditions or wantsFromSlide)
                             and (not blockedByGroup)
                             and (not blockedByBucket)

        if shouldBeVisible then
            f:Show()
        else
            f:Hide()
        end
    end

    -- If an icon was removed while visible, it may still exist in the local icons[] cache and would otherwise remain visible until /reload.
    if icons and DoiteAurasDB and DoiteAurasDB.spells then
        local used = DoiteAuras._iconsUsed
        local k, f
        for k, f in pairs(icons) do
            if f and (not used or not used[k]) then
                if not DoiteAurasDB.spells[k] then
                    f:Hide()
                    -- keep or drop the cache entry; dropping avoids table growth on add/remove churn
                    icons[k] = nil
                end
            end
        end
    end

    _G["DoiteAuras_RefreshInProgress"] = false
end

-- Refresh list (group-aware, but still uses .order as the only truth)
local function RefreshList()
    if DA_IsHardDisabled() then
        return
    end

    local _, v

    -- Mark all existing row frames "unused" for this rebuild, and hide them.
    for _, v in pairs(spellButtons) do
        if v then
            v._daInList = false
            if v.Hide then v:Hide() end
        end
    end

    -- Hide all existing header frames (reuse by index)
    local oldHeaderN = table.getn(groupHeaders)
    local i
    for i = 1, oldHeaderN do
        local h = groupHeaders[i]
        if h and h.Hide then h:Hide() end
    end

    local ordered = GetOrderedSpells()

    -- Duplicate-info for "(i/N)" suffix based on name+type
    local groupCount = {}
    local groupIndex = {}

    for i, entry in ipairs(ordered) do
        local d = entry.data
        local base = BaseKeyFor(d)
        groupCount[base] = (groupCount[base] or 0) + 1
    end
    for i, entry in ipairs(ordered) do
        local d = entry.data
        local base = BaseKeyFor(d)
        groupIndex[base] = (groupIndex[base] or 0) + 1
        entry._groupCnt = groupCount[base] or 1
        entry._groupIdx = groupIndex[base] or 1
    end

    local groupMembers = {}
    for i, entry in ipairs(ordered) do
        local d = entry.data
        if DA_IsGrouped(d) then
            local g = d.group
            if not groupMembers[g] then
                groupMembers[g] = {}
            end
            table.insert(groupMembers[g], entry)
        end
    end
    for g, list in pairs(groupMembers) do
        local n = table.getn(list)
        local j
        for j = 1, n do
            local e = list[j]
            e._prioInGroup = j
            e._groupSize   = n
        end
    end

    local displayList = DA_BuildDisplayList(ordered)

    -- compute content height based on separate header + row heights
    local headerCount, entryCount = 0, 0
    for _, entry in ipairs(displayList) do
        if entry.isHeader then
            headerCount = headerCount + 1
        else
            entryCount = entryCount + 1
        end
    end
    local totalHeight = headerCount * 25 + entryCount * 55 + 20
    listContent:SetHeight(math.max(160, totalHeight))

    -- running vertical offset (tighter spacing for headers)
    local yOffset = 0

    local headerIndex = 0

    for _, entry in ipairs(displayList) do
        if entry.isHeader then
            headerIndex = headerIndex + 1

            -- Reuse header frame by index
            local hdr = groupHeaders[headerIndex]
            if not hdr then
                hdr = CreateFrame("Frame", nil, listContent)
                hdr:SetWidth(290); hdr:SetHeight(22)

                hdr.bg = hdr:CreateTexture(nil, "BACKGROUND")
                hdr.bg:SetAllPoints(hdr)
                hdr.bg:SetTexture(1, 1, 1, 0.06)

                hdr.label = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                hdr.label:SetPoint("LEFT", hdr, "LEFT", 5, 0)

                -- Disable checkbox (created once; shown/hidden per header)
                hdr.disableCheck = CreateFrame("CheckButton", nil, hdr, "UICheckButtonTemplate")
                hdr.disableCheck:SetWidth(14); hdr.disableCheck:SetHeight(14)
                hdr.disableCheck:SetHitRectInsets(0, -40, 0, 0)

                hdr.disableCheck.text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                hdr.disableCheck.text:SetPoint("LEFT", hdr.disableCheck, "RIGHT", 2, 0)
                hdr.disableCheck.text:SetText("Disable")
                if hdr.disableCheck.text.SetTextColor then
                    hdr.disableCheck.text:SetTextColor(0.7, 0.7, 0.7)
                end

                hdr.disableCheck:SetScript("OnClick", function()
                    local p = this:GetParent()
                    local bk = p and p.bucketKey
                    if not bk then return end

                    DoiteAurasDB.bucketDisabled = DoiteAurasDB.bucketDisabled or {}
                    if this:GetChecked() then
                        DoiteAurasDB.bucketDisabled[bk] = true
                    else
                        DoiteAurasDB.bucketDisabled[bk] = nil
                    end

                    if DoiteAuras_RefreshIcons then
                        pcall(DoiteAuras_RefreshIcons)
                    end
                end)

                -- Sort controls (created once; shown only for group headers)
                hdr.sortTime = CreateFrame("CheckButton", nil, hdr, "UICheckButtonTemplate")
                hdr.sortTime:SetWidth(14); hdr.sortTime:SetHeight(14)
                hdr.sortTime.text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                hdr.sortTime.text:SetPoint("LEFT", hdr.sortTime, "RIGHT", 2, 0)
                hdr.sortTime.text:SetText("Time")
                if hdr.sortTime.text.SetTextColor then
                    hdr.sortTime.text:SetTextColor(1, 1, 1)
                end

                hdr.sortPrio = CreateFrame("CheckButton", nil, hdr, "UICheckButtonTemplate")
                hdr.sortPrio:SetWidth(14); hdr.sortPrio:SetHeight(14)
                hdr.sortPrio.text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                hdr.sortPrio.text:SetPoint("LEFT", hdr.sortPrio, "RIGHT", 2, 0)
                hdr.sortPrio.text:SetText("Prio")
                if hdr.sortPrio.text.SetTextColor then
                    hdr.sortPrio.text:SetTextColor(1, 1, 1)
                end

                hdr.sortPrio:SetScript("OnClick", function()
                    local p = this:GetParent()
                    if not p or not p.groupName or p.groupName == "" then
                        this:SetChecked(true)
                        return
                    end
                    if not this:GetChecked() then
                        this:SetChecked(true)
                        return
                    end
                    this:SetChecked(true)
                    if p.sortTime then p.sortTime:SetChecked(false) end
                    DoiteAurasDB.groupSort = DoiteAurasDB.groupSort or {}
                    DoiteAurasDB.groupSort[p.groupName] = "prio"
                    _G["DoiteGroup_NeedReflow"] = true
                end)

                hdr.sortTime:SetScript("OnClick", function()
                    local p = this:GetParent()
                    if not p or not p.groupName or p.groupName == "" then
                        this:SetChecked(true)
                        return
                    end
                    if not this:GetChecked() then
                        this:SetChecked(true)
                        return
                    end
                    this:SetChecked(true)
                    if p.sortPrio then p.sortPrio:SetChecked(false) end
                    DoiteAurasDB.groupSort = DoiteAurasDB.groupSort or {}
                    DoiteAurasDB.groupSort[p.groupName] = "time"
                    _G["DoiteGroup_NeedReflow"] = true
                end)

                hdr.sepTex = hdr:CreateTexture(nil, "ARTWORK")
                hdr.sepTex:SetHeight(1)
                hdr.sepTex:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 0, -2)
                hdr.sepTex:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", 0, -2)
                hdr.sepTex:SetTexture(0.9, 0.9, 0.9, 0.12)

                groupHeaders[headerIndex] = hdr
            end

            -- Update dynamic header text
            hdr.groupName = entry.groupName or ""
            local hdrName = string.upper(hdr.groupName or "")
            hdr.label:SetText(hdrName)

            -- Bucket key + disable toggle visibility/state
            hdr.bucketKey = DA_GetBucketKeyForHeaderEntry(entry)
            DoiteAurasDB.bucketDisabled = DoiteAurasDB.bucketDisabled or {}

            if hdr.bucketKey then
                hdr.disableCheck:ClearAllPoints()
                hdr.disableCheck:SetPoint("RIGHT", hdr, "RIGHT", -45, 0)
                hdr.disableCheck:Show()
                hdr.disableCheck:SetChecked(DoiteAurasDB.bucketDisabled[hdr.bucketKey] == true)
            else
                hdr.disableCheck:Hide()
            end

            -- Group sort controls (only for group headers)
            if entry.kind == "group" and hdr.groupName and hdr.groupName ~= "" then
                local mode = DA_GetGroupSortMode(hdr.groupName)  -- "prio" or "time"

                local rightAnchor = hdr
                local rightPointX = -45
                if hdr.disableCheck and hdr.disableCheck.IsShown and hdr.disableCheck:IsShown() then
                    rightAnchor = hdr.disableCheck
                    rightPointX = -30
                end

                hdr.sortTime:ClearAllPoints()
                hdr.sortTime:SetPoint("RIGHT", rightAnchor, "LEFT", rightPointX, 0)

                hdr.sortPrio:ClearAllPoints()
                hdr.sortPrio:SetPoint("RIGHT", hdr.sortTime, "LEFT", -30, 0)

                hdr.sortPrio:SetChecked(mode == "prio")
                hdr.sortTime:SetChecked(mode == "time")

                hdr.sortPrio:Show()
                hdr.sortTime:Show()
            else
                hdr.sortPrio:Hide()
                hdr.sortTime:Hide()
            end

            -- Position header
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, yOffset)
            yOffset = yOffset - 25
            hdr:Show()

        else
            local key, data = entry.key, entry.data
            if key and data then
                local display = data.displayName or key
                -- show "(i/N)" only if N > 1 (duplicates of same name+type)
                if entry._groupCnt and entry._groupCnt > 1 then
                    display = string.format("%s (%d/%d)", display, entry._groupIdx, entry._groupCnt)
                end

                -- Reuse per-key row frame
                local btn = spellButtons[key]
                if not btn then
                    btn = CreateFrame("Frame", nil, listContent)
                    btn:SetWidth(290); btn:SetHeight(50)

                    btn.fontString = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    btn.fontString:SetPoint("TOPLEFT", btn, "TOPLEFT", 15, -2)

                    btn.tag = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    btn.tag:SetPoint("TOPLEFT", btn.fontString, "BOTTOMLEFT", 0, -2)

                    btn.removeBtn = CreateFrame("Button", nil, btn, "UIPanelButtonTemplate")
                    btn.removeBtn:SetWidth(60); btn.removeBtn:SetHeight(18)
                    btn.removeBtn:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -5, -29)
                    btn.removeBtn:SetText("Remove")

                    btn.editBtn = CreateFrame("Button", nil, btn, "UIPanelButtonTemplate")
                    btn.editBtn:SetWidth(50); btn.editBtn:SetHeight(18)
                    btn.editBtn:SetPoint("RIGHT", btn.removeBtn, "LEFT", -5, 0)
                    btn.editBtn:SetText("Edit")

                    btn.downBtn = CreateFrame("Button", nil, btn)
                    btn.downBtn:SetWidth(18); btn.downBtn:SetHeight(18)
                    btn.downBtn:SetNormalTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollUpButton-Up")
                    btn.downBtn:SetPushedTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollUpButton-Down")
                    btn.downBtn:SetPoint("RIGHT", btn.editBtn, "LEFT", -5, 0)

                    btn.upBtn = CreateFrame("Button", nil, btn)
                    btn.upBtn:SetWidth(18); btn.upBtn:SetHeight(18)
                    btn.upBtn:SetNormalTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollDownButton-Up")
                    btn.upBtn:SetPushedTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollDownButton-Down")
                    btn.upBtn:SetPoint("RIGHT", btn.downBtn, "LEFT", -5, 0)

                    btn.sep = btn:CreateTexture(nil, "ARTWORK")
                    btn.sep:SetHeight(1)
                    btn.sep:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, -2)
                    btn.sep:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, -2)
                    btn.sep:SetTexture(0.9, 0.9, 0.9, 0.12)

                    spellButtons[key] = btn
                end

                btn._daInList = true

                -- Update row visuals
                btn.fontString:SetText(display)

                -- Type + group/ungrouped priority text
                local baseLabel, baseColor
                if data.type == "Ability" then
                    baseLabel = "Ability"
                    baseColor = "|cff4da6ff"
                elseif data.type == "Buff" then
                    baseLabel = "Buff"
                    baseColor = "|cff7dff7d"
                elseif data.type == "Debuff" then
                    baseLabel = "Debuff"
                    baseColor = "|cffff7d7d"
                elseif data.type == "Item" then
                    baseLabel = "Item"
                    baseColor = "|cffffd27d"
                elseif data.type == "Bar" then
                    baseLabel = "Bar"
                    baseColor = "|cffd27dff"
                else
                    baseLabel = tostring(data.type or "Unknown")
                    baseColor = "|cffcccccc"
                end

                local suffix = ""
                if DA_IsGrouped(data) then
                    local groupDesc = data.group
                    local prio = entry._prioInGroup or 1
                    local leaderSuffix = ""
                    if data.isLeader then
                        leaderSuffix = " - Group Leader"
                    end
                    suffix = string.format(" (%s - Prio %d%s)", tostring(groupDesc or "Group"), prio, leaderSuffix)
                else
                    local bucketName  = entry._bucketName or "Ungrouped"
                    local x = entry._bucketIndex or 1
                    local y = entry._bucketTotal or 1
                    local bucketLabel = string.upper(bucketName)
                    suffix = string.format(" (%s - Order# %d/%d)", bucketLabel, x, y)
                end

                local typeText = baseColor .. baseLabel .. "|r|cffaaaaaa" .. suffix .. "|r"
                btn.tag:SetText(typeText)

                -- Scripts are re-bound each refresh (keeps exact existing logic with current locals)

                btn.removeBtn:SetScript("OnClick", function()
                    -- detect if this was the last icon using them.
                    local groupName    = data and data.group
                    local categoryName = data and data.category

                    -- Remove from DoiteAuras DB
                    DoiteAurasDB.spells[key] = nil

                    -- Also drop any legacy DoiteDB entry so evaluation stops touching this key
                    if DoiteDB and DoiteDB.icons and DoiteDB.icons[key] then
                        DoiteDB.icons[key] = nil
                    end

                    -- Remove cached row frame reference so add/remove cycles don't grow without bound
                    if spellButtons and spellButtons[key] then
                        spellButtons[key]:Hide()
                        spellButtons[key] = nil
                    end

                    -- Rebuild ordering + UI
                    RebuildOrder()
                    RefreshList()
                    RefreshIcons()

                    if DoiteConditions_RequestEvaluate then
                        DoiteConditions_RequestEvaluate()
                    end
                end)

                btn.editBtn:SetScript("OnClick", function()
                    local baseName = data.displayName or data.name or display

                    currentType = data.type or "Ability"
                    if abilityCB then abilityCB:SetChecked(currentType == "Ability") end
                    if buffCB    then buffCB:SetChecked(currentType == "Buff")    end
                    if debuffCB  then debuffCB:SetChecked(currentType == "Debuff") end
                    if itemsCB   then itemsCB:SetChecked(currentType == "Item")   end
                    if barsCB    then barsCB:SetChecked(currentType == "Bar")     end

                    if currentType == "Item" then
                        DA_UpdateTypeUI()
                        if itemDropDown then
                            UIDropDownMenu_SetText(baseName, itemDropDown)
                        end

                    elseif currentType == "Bar" then
                        DA_UpdateTypeUI()
                        if barDropDown then
                            UIDropDownMenu_SetText(baseName, barDropDown)
                        end

                    else
                        DA_UpdateTypeUI()
                        if spellDropDown then
                            UIDropDownMenu_SetText(baseName, spellDropDown)
                        end
                    end

                    if DoiteConditions_Show then
                        DoiteConditions_Show(key)
                    end
                end)

                btn.downBtn:SetScript("OnClick", function()
                    local isGrouped = DA_IsGrouped(data)
                    local moved = false

                    if isGrouped then
                        -- move "up" inside the group (towards first member)
                        moved = DA_MoveOrderWithinGroup(key, "up")
                    else
                        -- ungrouped: move only within its category / Ungrouped bucket
                        moved = DA_MoveOrderWithinCategoryOrUngrouped(key, "up")
                    end

                    if moved then
                        RebuildOrder()
                        RefreshList()
                        RefreshIcons()
                        if DoiteConditions_RequestEvaluate then
                            DoiteConditions_RequestEvaluate()
                        end
                    end
                end)

                btn.upBtn:SetScript("OnClick", function()
                    local isGrouped = DA_IsGrouped(data)
                    local moved = false

                    if isGrouped then
                        moved = DA_MoveOrderWithinGroup(key, "down")
                    else
                        moved = DA_MoveOrderWithinCategoryOrUngrouped(key, "down")
                    end

                    if moved then
                        RebuildOrder()
                        RefreshList()
                        RefreshIcons()
                        if DoiteConditions_RequestEvaluate then
                            DoiteConditions_RequestEvaluate()
                        end
                    end
                end)

                -- Position row (ClearAllPoints is important when reusing frames)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, yOffset)
                yOffset = yOffset - 55
                btn:Show()
            end
        end
    end

    -- Hide any row frames that weren't used this refresh (covers removed keys)
    for _, v in pairs(spellButtons) do
        if v and (v._daInList ~= true) then
            if v.Hide then v:Hide() end
        end
    end

    scrollFrame:SetScrollChild(listContent)
end

-- Add button
addBtn:SetScript("OnClick", function()
  local t = currentType
  local name

  -- Bars are UI-only placeholders for now: never add them to the DB
  if t == "Bar" then
    (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cff6FA8DCDoiteAuras:|r Bars are not implemented yet (coming soon).")
    return
  end

  if t == "Item" then
      name = DA_GetDropDownText(itemDropDown)
  elseif t == "Ability" then
      name = DA_GetDropDownText(abilityDropDown)
  else
      name = input:GetText()
  end

  if not name or name == "" then return end
  if name == "Select from dropdown" then return end

  local isSpecialHeader = (name == "---EQUIPPED TRINKET SLOTS---" or name == "---EQUIPPED WEAPON SLOTS---")
  if not isSpecialHeader and (t == "Buff" or t == "Debuff") then
      name = TitleCase(name)
  end

  -- Detect pure numeric Buff/Debuff input as "spell ID mode"
  local spellIdStr = nil
  if (t == "Buff" or t == "Debuff") and not isSpecialHeader then
      if string.find(name, "^(%d+)$") then
          spellIdStr = name
          -- UI label while not knowing know the real spell name
          name = "Spell ID: " .. spellIdStr .. " (will update when seen)"
      end
  end

  -- Ability validation stays
  if t == "Ability" and not FindSpellBookSlot(name) then
    (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffff0000DoiteAuras:|r Spell not found in spellbook.")
    return
  end

  ----------------------------------------------------------------
  -- Buff/Debuff duplicate rule:
  -- Only allow ONE entry per (name,type) while NONE of the existing
  -- siblings have a texture yet (iconTexture or cache entry).
  --
  -- For spell ID entries this still groups by the visible label
  -- "Spell ID: 12345 (will update when seen)".
  ----------------------------------------------------------------
  if t == "Buff" or t == "Debuff" then
      local cache   = DA_Cache()
      local baseKey = BaseKeyFor(name, t)

      local hasSibling         = false
      local siblingHasTexture  = false

      if DoiteAurasDB and DoiteAurasDB.spells then
          local sk, sd
          for sk, sd in pairs(DoiteAurasDB.spells) do
              if sd and BaseKeyFor(sd) == baseKey then
                  hasSibling = true

                  local nm  = sd.displayName or sd.name
                  local tex = sd.iconTexture
                  if not tex and nm then
                      tex = cache[nm]
                  end

                  if tex then
                      siblingHasTexture = true
                      break
                  end
              end
          end
      end

      -- If there is already at least one Buff/Debuff with this name+type and NONE of them have a texture yet, block adding another.
      if hasSibling and not siblingHasTexture then
          local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
          if cf then
              cf:AddMessage("|cff6FA8DCDoiteAuras:|r To add another duplicate aura of the same type (buff/debuff) with the name |cffffff00" .. name .. "|r, you must first have seen/applied it at least once.")
          end
          return
      end
  end
  ----------------------------------------------------------------

  -- generate unique key; baseKey groups duplicates by name+type
  local key, baseKey, instanceIdx = GenerateUniqueKey(name, t)

  -- Order = append at end
  local nextOrder = table.getn(GetOrderedSpells()) + 1

  -- Create the DB entry (defaults filled later by EnsureDBEntry/DoiteEdit)
  DoiteAurasDB.spells[key] = {
    order       = nextOrder,
    type        = t,
    displayName = name,
    baseKey     = baseKey,
    uid         = instanceIdx,
  }

  local entry = DoiteAurasDB.spells[key]
  local cache = DA_Cache()

  -- If this was created by spell ID, persist it so DoiteConditions can resolve it by ID.
  if spellIdStr then
      entry.spellid = spellIdStr
  end

  -- Auto-prime texture
  if t == "Ability" then
    local slot = FindSpellBookSlot(name)
    if slot and GetSpellTexture then
      local tex = GetSpellTexture(slot, BOOKTYPE_SPELL)
      if tex then
        cache[name]       = tex
        entry.iconTexture = tex
      end
    end

  elseif t == "Item" then
    -- Items: use real item icon where possible, or "?" for special EQUIPPED headers
    if isSpecialHeader then
      -- "EQUIPPED TRINKET SLOTS" / "EQUIPPED WEAPON SLOTS" -> placeholder for later conditions
      local tex = "Interface\\Icons\\INV_Misc_QuestionMark"
      cache[name]       = tex
      entry.iconTexture = tex
    else
      -- Concrete item selected: capture its icon now so it persists even if unequipped later
      local itemTex = DA_FindItemTextureByName(name)
      if itemTex then
        cache[name]       = itemTex
        entry.iconTexture = itemTex
      end
    end
  end

  -- Generic fallback: use any existing cache or sibling iconTexture if still missing
  if not entry.iconTexture then
    local cached = DA_Cache()[name]
    if cached then
      entry.iconTexture = cached
    else
      for sk, sd in IterSiblings(name, t) do
        if sd and sd.iconTexture then
          entry.iconTexture = sd.iconTexture
          break
        end
      end
    end
  end

  if EnsureDBEntry then pcall(EnsureDBEntry, key) end
  input:SetText("")
  RebuildOrder(); RefreshList(); RefreshIcons()
  scrollFrame:SetVerticalScroll(math.max(0, listContent:GetHeight() - scrollFrame:GetHeight()))
  if DoiteConditions_RequestEvaluate then DoiteConditions_RequestEvaluate() end
end)

-- =========================
-- Minimap Button (DoiteAuras)
-- =========================
local function DA_GetVersion()
  local v = (GetAddOnMetadata and GetAddOnMetadata("DoiteAuras", "Version")) or (DoiteAuras_Version) or "?"
  return v or "?"
end

local function _DA_MiniSV()
  DoiteAurasDB.minimap = DoiteAurasDB.minimap or {}
  if DoiteAurasDB.minimap.angle == nil then DoiteAurasDB.minimap.angle = 45 end -- default angle
  return DoiteAurasDB.minimap
end

local function _DA_PlaceMini(btn)
  local ang = ((_DA_MiniSV().angle or 45) * math.pi / 180)
  local x = math.cos(ang) * 80
  local y = math.sin(ang) * 80
  btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function DA_CreateMinimapButton()
  if _G["DoiteAurasMinimapButton"] then return end

  local btn = CreateFrame("Button", "DoiteAurasMinimapButton", Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetWidth(31); btn:SetHeight(31)

  -- Ring overlay
  local overlay = btn:CreateTexture(nil, "OVERLAY")
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetWidth(54); overlay:SetHeight(54)
  overlay:SetPoint("TOPLEFT", 0, 0)

  -- Icon (DA tga)
  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\AddOns\\DoiteAuras\\Textures\\doiteauras-icon")
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetPoint("TOPLEFT", 6, -5)

  local hlt = btn:CreateTexture(nil, "HIGHLIGHT")
  hlt:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  hlt:SetBlendMode("ADD")
  hlt:SetAllPoints(btn)

  btn:RegisterForDrag("LeftButton", "RightButton")
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  -- drag to move along the minimap ring
  btn:SetScript("OnDragStart", function()
    btn:SetScript("OnUpdate", function()
      local x, y = GetCursorPosition()
      local mx, my = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      local ang = math.deg(math.atan2(y/scale - my, x/scale - mx))
      _DA_MiniSV().angle = ang
      _DA_PlaceMini(btn)
    end)
  end)
  btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)

  -- click: opens/close DoiteAuras
  btn:SetScript("OnClick", function()
    if DA_IsHardDisabled and DA_IsHardDisabled() then
      local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
      if cf then
        cf:AddMessage("|cff6FA8DCDoiteAuras:|r Disabled because required mods are missing (SuperWoW, Nampower, UnitXP SP3).")
      end
      return
    end
	if DoiteAurasFrame and DoiteAurasFrame:IsShown() then
      DoiteAurasFrame:Hide()
    else
	-- center-on-open logic (keeps Step #1 behavior)
    if DoiteAurasFrame then
     DoiteAurasFrame:ClearAllPoints()
     DoiteAurasFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
     DoiteAurasFrame:Show()
		end
	end
  end)

  -- tooltip
  btn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
    GameTooltip:AddLine("DOITEAURAS", 0.435, 0.659, 0.863) -- #6FA8DC = DoiteAuras color - personal note
    GameTooltip:AddLine("Click to open DoiteAuras", 1, 1, 1)
    GameTooltip:AddLine("Version: " .. tostring(DA_GetVersion()), 0.9, 0.9, 0.9)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
  end)

  -- initial placement
  _DA_PlaceMini(btn)
end

-- create/show on load
local _daMiniInit = CreateFrame("Frame", "DoiteMiniInit")
_daMiniInit:RegisterEvent("ADDON_LOADED")
_daMiniInit:SetScript("OnEvent", function()
  if event ~= "ADDON_LOADED" or arg1 ~= "DoiteAuras" then return end
  DA_CreateMinimapButton()
end)

-- /slash commands
SLASH_DOITEAURAS1="/da"
SLASH_DOITEAURAS2="/doiteaurs"
SLASH_DOITEAURAS3="/doiteaura"
SLASH_DOITEAURAS4="/doite"

SlashCmdList["DOITEAURAS"] = function(msg)
  -- msg is a plain string in 1.12, no methods on it
  msg = msg or ""
  msg = string.lower(msg)

  -- Split into first word (cmd) and rest (arguments)
  local cmd, rest
  local firstSpace = string.find(msg, " ", 1, true)
  if firstSpace then
    cmd  = string.sub(msg, 1, firstSpace - 1)
    rest = string.sub(msg, firstSpace + 1)
  else
    cmd  = msg
    rest = ""
  end

  -- Trim whitespace around rest
  rest = string.gsub(rest, "^%s+", "")
  rest = string.gsub(rest, "%s+$", "")

  -- /da cleartimers [name/spellid]  or  /da ct [name/spellid]
  if cmd == "cleartimers" or cmd == "ct" then
    local clearFn = _G["DoiteTrack_ClearTimers"]
    if type(clearFn) == "function" then
      -- ""      -> clear all
      -- "rend"  -> clear all ranks whose meta.name normalises to "rend"
      -- "11574" -> clear only that spellId
      clearFn(rest)
    else
      local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
      if cf then
        cf:AddMessage("|cff6FA8DCDoiteAuras:|r Timer clear function not available (DoiteTrack not loaded?).")
      end
    end
    return
  end

  -- No /ct command -> normal DoiteAuras toggle
  if DA_IsHardDisabled() then
    local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
    if cf then
      cf:AddMessage("|cff6FA8DCDoiteAuras:|r Disabled because required mods are missing (SuperWoW, Nampower, UnitXP SP3).")
    end
    return
  end

  if frame:IsShown() then
    frame:Hide()
  else
    -- Always (re)center on open
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:Show()
    RefreshList()
  end
end

-- =========================
-- Version WHO (/daversionwho)
-- =========================
local DA_PREFIX = "DOITEAURAS"

local function DA_GetVersion_Safe()
  -- Reuse existing DA_GetVersion() if present (minimap section defines it)
  if type(DA_GetVersion) == "function" then
    return DA_GetVersion() or "?"
  end
  local v = (GetAddOnMetadata and GetAddOnMetadata("DoiteAuras", "Version")) or (DoiteAuras_Version) or "?"
  return v or "?"
end

-- Broadcast helpers
local function DA_BroadcastVersion(channel)
  if not SendAddonMessage then return end
  SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), channel)
end

local function DA_BroadcastVersionAll()
  if not SendAddonMessage then return end
  if UnitInRaid and UnitInRaid("player") then
    SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), "RAID")
  elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
    SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), "PARTY")
  elseif IsInGuild and IsInGuild() then
    SendAddonMessage(DA_PREFIX, "DA_VER:" .. tostring(DA_GetVersion_Safe()), "GUILD")
  end
end

-- Version compare helpers
local function DA_ParseVersion(v)
  local s = tostring(v or "")
  local _, _, a, b, c = string.find(s, "^(%d+)%.(%d+)%.?(%d*)$")

  return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

local function DA_IsNewer(v1, v2)
  local a1,b1,c1 = DA_ParseVersion(v1)
  local a2,b2,c2 = DA_ParseVersion(v2)
  if a1 ~= a2 then return a1 > a2 end
  if b1 ~= b2 then return b1 > b2 end
  return c1 > c2
end
local _daVerNotifiedOnce = false
local _daVerLastEcho = 0

-- /daversionwho: ask others to report their version
SLASH_DAVERSIONWHO1 = "/daversionwho"
SlashCmdList["DAVERSIONWHO"] = function()
  local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
  if cf then cf:AddMessage("|cff6FA8DCDoiteAuras:|r version WHO sent. Listening for replies...") end
  local sent = false
  if UnitInRaid and UnitInRaid("player") then
    SendAddonMessage(DA_PREFIX, "DA_WHO", "RAID");  sent = true
  elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
    SendAddonMessage(DA_PREFIX, "DA_WHO", "PARTY"); sent = true
  elseif IsInGuild and IsInGuild() then
    SendAddonMessage(DA_PREFIX, "DA_WHO", "GUILD"); sent = true
  end
  if not sent and cf then
    cf:AddMessage("|cff6FA8DCDoiteAuras:|r No channels available (raid/party/guild).")
  end
end

-- Small delayed runner
function DA_RunLater(delay, func)
  local f = CreateFrame("Frame")
  local acc = 0
  f:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc >= delay then
      f:SetScript("OnUpdate", nil)
      if type(func) == "function" then pcall(func) end
    end
  end)
end

-- Version event listener (compare, notify, echo replies)
local _daVer = CreateFrame("Frame", "DoiteVersion")
_daVer:RegisterEvent("CHAT_MSG_ADDON")
_daVer:SetScript("OnEvent", function()
  if event ~= "CHAT_MSG_ADDON" then return end
  local prefix, text, channel, sender = arg1, arg2, arg3, arg4
  if prefix ~= DA_PREFIX or type(text) ~= "string" then return end

  local mine = tostring(DA_GetVersion_Safe())
  local cf   = (DEFAULT_CHAT_FRAME or ChatFrame1)

  if text == "DA_WHO" then
    if channel and SendAddonMessage then
      SendAddonMessage(DA_PREFIX, "DA_ME:" .. mine, channel)
    end
    return
  end

  if string.sub(text, 1, 6) == "DA_ME:" then
    local other = string.sub(text, 7)
    -- show who has what (existing behavior)
    if cf then
      cf:AddMessage(string.format("|cff6FA8DCDoiteAuras:|r %s has %s (you: %s)", tostring(sender or "?"), tostring(other or "?"), tostring(mine)))
    end
    -- notify once if theirs is newer than mine
    if (not _daVerNotifiedOnce) and DA_IsNewer(other, mine) then
      _daVerNotifiedOnce = true
      DA_RunLater(8, function()
        if cf then
          cf:AddMessage(string.format("|cff6FA8DCDoiteAuras:|r A newer version is available (yours: %s, latest seen: %s). Consider updating.", tostring(mine), tostring(other)))
        end
      end)
    end
    return
  end

  if string.sub(text, 1, 7) == "DA_VER:" then
    local other = string.sub(text, 8)
    -- notify once if theirs is newer than mine
    if (not _daVerNotifiedOnce) and DA_IsNewer(other, mine) then
      _daVerNotifiedOnce = true
      DA_RunLater(8, function()
        if cf then
          cf:AddMessage(string.format("|cff6FA8DCDoiteAuras:|r A newer version is available (yours: %s, latest seen: %s). Consider updating.", tostring(mine), tostring(other)))
        end
      end)
    end
    -- echo mine back (rate-limited) so others see my version too
    if channel and SendAddonMessage then
      local now = (GetTime and GetTime()) or 0
      if now - _daVerLastEcho > 10 then
        _daVerLastEcho = now
        SendAddonMessage(DA_PREFIX, "DA_VER:" .. mine, channel)
      end
    end
    return
  end
end)


-- Loaded message + delayed version broadcast(s)
local _daRaidAnnounced = false

local _daLoad = CreateFrame("Frame", "DoiteLoad")
_daLoad:RegisterEvent("ADDON_LOADED")
_daLoad:RegisterEvent("PLAYER_ENTERING_WORLD")
_daLoad:RegisterEvent("RAID_ROSTER_UPDATE")

_daLoad:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and arg1 == "DoiteAuras" then
    -- 1s after load: run modern-mod check, then print either "loaded" or "missing" line
    DA_RunLater(1, function()
      local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
      if not cf then return end

      local missing = DA_GetMissingRequiredMods()

      if table.getn(missing) == 0 then
        -- All required mods present → normal loaded message
        local v = tostring(DA_GetVersion_Safe())
        cf:AddMessage("|cff6FA8DCDoiteAuras|r v"..v.." loaded. Use |cffffff00/da|r (or minimap icon).")
      else
        -- One or more missing → modern client requirement message
        local list = table.concat(missing, ", ")
        cf:AddMessage("|cff6FA8DCDoiteAuras:|r This addon requires SuperWoW, Nampower and UnitXP SP3 mods to modernize the 1.12 client. You are missing " .. list .. ".")
        -- BLOCKER: after printing the message, hard-disable the addon
        _G["DoiteAuras_HardDisabled"] = true

        -- Hide config frame and any icons if they exist
        if DoiteAurasFrame and DoiteAurasFrame.Hide then
          DoiteAurasFrame:Hide()
        end
        if icons then
          for _, f in pairs(icons) do
            if f and f.Hide then f:Hide() end
          end
        end
      end
    end)

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- 10s after entering world: broadcast my version to an available channel
    DA_RunLater(10, function()
      DA_BroadcastVersionAll()
    end)

  elseif event == "RAID_ROSTER_UPDATE" then
    -- first time player are in a raid: announce on RAID after ~3s
    if not _daRaidAnnounced and UnitInRaid and UnitInRaid("player") then
      _daRaidAnnounced = true
      DA_RunLater(3, function()
        if SendAddonMessage then
          SendAddonMessage("DOITEAURAS", "DA_VER:"..tostring(DA_GetVersion_Safe()), "RAID")
        end
      end)
    end
  end
end)

-- Update icons frequently
local updateFrame = CreateFrame("Frame", "DoiteUpdateFrame")
updateFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
updateFrame:SetScript("OnEvent", function()
  if DA_IsHardDisabled and DA_IsHardDisabled() then return end
  if event == "PLAYER_ENTERING_WORLD" then RefreshIcons() end
end)

RebuildOrder(); RefreshList(); RefreshIcons()

DoiteAuras_RefreshList  = RefreshList
DoiteAuras_RefreshIcons = RefreshIcons

-- Reusable candidate list/pool
local _daCandidates_list = {}
local _daCandidates_pool = {}

local function _daClearArray(t)
    local i = 1
    while t[i] ~= nil do
        t[i] = nil
        i = i + 1
    end
end

function DoiteAuras.GetAllCandidates()
    if DA_IsHardDisabled and DA_IsHardDisabled() then
        return {}
    end

    local list = _daCandidates_list
    local pool = _daCandidates_pool
    _daClearArray(list)

    local editKey   = _G["DoiteEdit_CurrentKey"]
    local editFrame = _G["DoiteEdit_Frame"] or _G["DoiteEditMain"] or _G["DoiteEdit"]
    local editOpen  = (editFrame and editFrame.IsShown and editFrame:IsShown() == 1)

    local n = 0
    for key, data in pairs(DoiteAurasDB.spells or {}) do
        -- Skip entries whose bucket is disabled, unless the helper doesn't exist
        if (not DoiteAuras_IsKeyDisabled) or (not DoiteAuras_IsKeyDisabled(key)) then
            local f = (DoiteAuras_GetIconFrame and DoiteAuras_GetIconFrame(key)) or _G["DoiteIcon_" .. key]

            local wants = false
            if f then
                wants = (f._daShouldShow == true) or (f._daSliding == true)
            end
            -- While editing: force the edited key into the pool so groups can place it
            if editOpen and editKey == key then
                wants = true
            end

            n = n + 1
            local e = pool[n]
            if not e then
                e = {}
                pool[n] = e
            end

            e.key  = key
            e.data = data
            e.show = wants
            e.tex  = (f and f.icon and f.icon:GetTexture()) or nil
            e.size = data.iconSize or data.size or 36

            list[n] = e
        end
    end

    return list
end

-- Ensure an icon frame exists for a given key (no visibility changes)
function DoiteAuras_TouchIcon(key)
  if not key then return end
  if DA_IsHardDisabled and DA_IsHardDisabled() then return end
  local name = "DoiteIcon_"..key
  if _G[name] then return end
  if CreateOrUpdateIcon then CreateOrUpdateIcon(key, 36) end
end