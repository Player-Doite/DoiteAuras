-- DoiteAuras: Simplified WeakAura-style addon for Turtle WoW 1.12 (Lua 5.0)
-- Tracks spells by name + type (Ability/Buff/Debuff) so duplicates with different types allowed
-- Shows movable icons (Abilities & Buff/Debuff when present on player), scrollable list, edit/remove/up/down
-- Default logic = show when usable/off CD for Abilities; Buff/Debuff show when present on player
-- SavedVariables: DoiteAurasDB

if DoiteAurasFrame then return end

-- SavedVariables init (guarded; do NOT clobber existing data)
DoiteAurasDB = DoiteAurasDB or {}
DoiteAurasDB.spells   = DoiteAurasDB.spells   or {}
DoiteAurasDB.cache = DoiteAurasDB.cache or {}
DoiteAuras = DoiteAuras or {}

-- Always return a valid name->texture cache table
local function DA_Cache()
  DoiteAurasDB = DoiteAurasDB or {}
  DoiteAurasDB.cache = DoiteAurasDB.cache or {}
  return DoiteAurasDB.cache
end


-- Persistent store for group layout computed positions
_G["DoiteGroup_Computed"]       = _G["DoiteGroup_Computed"]       or {}
_G["DoiteGroup_LastLayoutTime"] = _G["DoiteGroup_LastLayoutTime"] or 0

-- ========= Spell Texture Cache (abilities) =========
-- Populates DoiteAurasDB.cache[name] = texture from the player's spellbook.
-- Works on Turtle/1.12 via GetSpellName / GetSpellTexture.

local function DoiteAuras_RebuildSpellTextureCache()
    local cache = DA_Cache()
    -- Scan all tabs/slots once and remember textures by NAME (rank-agnostic, matches your displayName use)
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

    -- If we already have configured Ability entries, seed their .iconTexture for immediate use
    if DoiteAurasDB.spells then
        for key, data in pairs(DoiteAurasDB.spells) do
            if data and data.type == "Ability" then
                local nm = data.displayName or data.name
                local t  = nm and cache[nm]
                if t then data.iconTexture = t end
            end
        end
    end
end

-- Event hook: rebuild on login/world and whenever the spellbook changes (talent/build swaps on Turtle fire this)
local _daSpellTex = CreateFrame("Frame")
_daSpellTex:RegisterEvent("PLAYER_ENTERING_WORLD")
_daSpellTex:RegisterEvent("SPELLS_CHANGED")
_daSpellTex:SetScript("OnEvent", function()
    DoiteAuras_RebuildSpellTextureCache()
    -- repaint so brand-new abilities get icons instantly
    if DoiteAuras_RefreshIcons then pcall(DoiteAuras_RefreshIcons) end
end)
-- ==================================================

-- Title-case function with exceptions for small words (keeps first word capitalized)
local function TitleCase(str)
    if not str then return "" end
    str = tostring(str)
    local exceptions = {
        ["of"]=true, ["and"]=true, ["the"]=true, ["for"]=true,
        ["in"]=true, ["on"]=true, ["to"]=true, ["a"]=true,
        ["an"]=true, ["with"]=true, ["by"]=true, ["at"]=true
    }
    local result, first = "", true
    for word in string.gmatch(str, "%S+") do
        -- If the word starts with "(", force-capitalize the first letter after "(".
        local startsParen = (string.sub(word, 1, 1) == "(")
        local leading = startsParen and "(" or ""
        local core = startsParen and string.sub(word, 2) or word

        local lowerCore = string.lower(core or "")
        local c = string.sub(core or "", 1, 1) or ""
        local rest = string.sub(core or "", 2) or ""

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

-- Generate a unique storage key for DB & frames.
-- Keeps the very first as <name>_<type>; subsequent siblings append #2, #3, ...
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
intro:SetText("Enter the EXACT name of the buff or debuff.")

-- Close button
local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() this:GetParent():Hide() end)

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

-- Dropdowns for Abilities, Items and Bars (share the same slot as the input)

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
    -- avoid duplicates by plain name (case-sensitive here, but we dedupe by lower for safety later)
    local n = table.getn(DA_AbilityOptions)
    local i
    for i = 1, n do
        if DA_AbilityOptions[i] == name then
            return
        end
    end
    DA_AbilityOptions[n + 1] = name
end

-- Helper: close + reopen abilities dropdown on the next frame so we rebuild with new page
local function DA_RepageAbilityDropdown()
    if not abilityDropDown then return end
    local dd = abilityDropDown

    if DA_RunLater then
        DA_RunLater(0.01, function()
            if dd then
                -- vanilla-safe: toggle closed then open again
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

    -- Previous page button (if we are not at the first page)
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
        info.keepShownOnClick = 1   -- we manage the close/open ourselves
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
        -- normal entries: default behaviour (select + close)
        UIDropDownMenu_AddButton(info)
    end

    -- Next page button (if we have more abilities below)
    if endIndex < total then
        info = {}
        info.text = "|cffffff00>> NEXT PAGE >>|r"
        info.func = function()
            local total = table.getn(DA_AbilityOptions)
            -- Max offset such that we still have something to show
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

    -- Mirror DoiteEdit's AuraCond_BuildAbilitySpellList logic:
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

    -- Reset paging to the top and hook our custom initializer
    DA_AbilityMenuOffset = 0
    UIDropDownMenu_Initialize(abilityDropDown, DA_AbilityMenu_Initialize)

    -- Reset shown text each time we rebuild
    UIDropDownMenu_SetText("Select from dropdown", abilityDropDown)
end

-- =========================
-- Item dropdown scanning (bags + equipped)
-- =========================

-- Holds the current item names shown in the dropdown
local DA_ItemOptions = {}
-- Paged dropdown for long lists
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
        local fs = getglobal("DoiteAurasTooltipTextLeft"..i)
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
-- in equipped trinkets/weapons + bags. Returns a texture path or nil.
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

-- Helper: close + reopen dropdown on the next frame so we rebuild with new page
local function DA_RepageItemDropdown()
    if not itemDropDown then return end
    local dd = itemDropDown

    if DA_RunLater then
        DA_RunLater(0.01, function()
            if dd then
                -- vanilla-safe: toggle closed then open again
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

    -- Previous page button (if we are not at the first page)
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
        info.keepShownOnClick = 1   -- we manage the close/open ourselves
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

    -- Next page button (if we have more items below)
    if endIndex < total then
        info = {}
        info.text = "|cffffff00>> NEXT PAGE >>|r"
        info.func = function()
            local total = table.getn(DA_ItemOptions)
            -- Max offset such that we still have something to show
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

    -- 4) Reset paging to the top and hook our custom initializer
    DA_ItemMenuOffset = 0
    UIDropDownMenu_Initialize(itemDropDown, DA_ItemMenu_Initialize)

    -- Reset shown text each time we rebuild
    UIDropDownMenu_SetText("Select from dropdown", itemDropDown)
end

-- Helper to read current dropdown text (1.12-style)
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
        intro:SetText("Enter the EXACT name of the ability, buff or debuff.")
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
scrollFrame:SetWidth(280)
scrollFrame:SetHeight(250)
scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 15, -5)

local listContent = CreateFrame("Frame", "DoiteAurasListContent", scrollFrame)
listContent:SetWidth(280)
listContent:SetHeight(250)
scrollFrame:SetScrollChild(listContent)

-- Guide text
local guide = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
guide:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 20)
guide:SetWidth(315)
guide:SetJustifyH("LEFT")
if guide.SetTextColor then guide:SetTextColor(0.7,0.7,0.7) end
guide:SetText("Guide: DoiteAuras shows only what matters—abilities, buffs, debuffs, items, or bars—when you actually need them. Add an icon or bar, pick its type, and define when it appears using simple conditions like cooldown, aura state, combat, or target. Everything updates automatically, remembers textures once seen, and keeps your UI clean and reactive.")

-- storage
local spellButtons, icons = {}, {}

local function GetIconLayout(key)
    if DoiteDB and DoiteDB.icons and DoiteDB.icons[key] then
        return DoiteDB.icons[key]
    end
    return nil
end

-- helper to get data (safe init)
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
    table.sort(list, function(a,b) return a.order < b.order end)
    return list
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
    for tab=1, GetNumSpellTabs() do
        local _, _, offset, numSlots = GetSpellTabInfo(tab)
        for i=1, numSlots do
            local name = GetSpellName(i+offset, BOOKTYPE_SPELL)
            if name == spellName then return i+offset end
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

-- Create/update icon (fixed: use offsetX/offsetY/iconSize saved fields and create global DoiteIcon_<key> frames)
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

        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")

        -- icon texture (created once)
        f.icon = f:CreateTexture(nil, "BACKGROUND")
        f.icon:SetAllPoints(f)

        -- optional count text (created once)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
        fs:SetText("")
        f.count = fs

        -- drag handlers: followers ignore write; leaders update DB
        f:SetScript("OnDragStart", function()
			-- Followers should not start moving
			local data = GetSpellData(key)
			if data and data.group and data.group ~= "" and data.group ~= "no" and not data.isLeader then
				return
			end
			this:StartMoving()
		end)

		f:SetScript("OnDragStop", function()
			this:StopMovingOrSizing()
			local point, relTo, relPoint, x, y = this:GetPoint()
			local data = GetSpellData(key)
			-- Followers must never write offsets or trigger refresh
			if data and data.group and data.group ~= "" and data.group ~= "no" and not data.isLeader then
				return
			end
			if data then
				data.offsetX = x or 0
				data.offsetY = y or 0
			end
			if data and data.group and data.group ~= "" and data.group ~= "no" and data.isLeader then
				if _G["DoiteGroup_Computed"] then
					_G["DoiteGroup_Computed"][data.group] = nil
				end
			end
			if DoiteAuras_RefreshIcons then
				if DA_RunLater then
					DA_RunLater(0.05, function() if DoiteAuras_RefreshIcons then pcall(DoiteAuras_RefreshIcons) end end)
				else
					local fDelay = CreateFrame("Frame")
					local acc = 0
					fDelay:SetScript("OnUpdate", function()
						acc = acc + arg1
						if acc >= 0.05 then
							fDelay:SetScript("OnUpdate", nil)
							if DoiteAuras_RefreshIcons then pcall(DoiteAuras_RefreshIcons) end
						end
					end)
				end
			end
		end)
    end

    -- cache locally as before
    icons[key] = f
    if layer then f:SetFrameLevel(layer) end

    return f
end

-- Refresh icons (group-aware)
local function RefreshIcons()
    if not _CanRunRefresh() then return end
    local ordered = GetOrderedSpells()
    local total = table.getn(ordered)
    local candidates = {}

    -- Step 1: collect all icon states
    for i = 1, total do
        local key = ordered[i].key
        local data = ordered[i].data
        local typ = data and data.type or "Ability"
        local tex, shouldShow = nil, false

        if typ == "Ability" then
            local slot = FindSpellBookSlot(data.displayName or data.name)
            if slot then
                local start, dur, en = GetSpellCooldown(slot, BOOKTYPE_SPELL)
                if en == 1 and (dur == 0 or dur == nil) then
                    tex = GetSpellTexture(slot, BOOKTYPE_SPELL)
                    shouldShow = true
                end
            end

        elseif typ == "Buff" then
            local found, btex = FindPlayerBuff(data.displayName or data.name)
            if found then shouldShow, tex = true, btex end

        elseif typ == "Debuff" then
            local found, dtex = FindPlayerDebuff(data.displayName or data.name)
            if found then shouldShow, tex = true, dtex end

        elseif typ == "Item" then
            -- Items: just resolve the texture here; visibility is driven by conditions.
            local nm    = data.displayName or data.name
            local cache = DA_Cache()
            tex = (nm and cache[nm]) or data.iconTexture
            -- keep shouldShow = false; DoiteConditions will set _daShouldShow when appropriate
        end

        table.insert(candidates, {
            key = key,
            data = data,
            show = shouldShow,
            tex  = tex,
            size = data.iconSize or data.size or 36,
        })
    end

    -- Step 2: ensure icons exist first, then apply group layout once
    for _, entry in ipairs(candidates) do
        if not _G["DoiteIcon_" .. entry.key] then
            CreateOrUpdateIcon(entry.key, 36)
        end
    end
    if DoiteGroup and not _G["DoiteGroup_LayoutInProgress"] and DoiteGroup.ApplyGroupLayout then
		pcall(DoiteGroup.ApplyGroupLayout, candidates)
	end
	
	-- Persist the computed layout so future refresh passes keep using it
	do
		local map = _G["DoiteGroup_Computed"]
		local now = (GetTime and GetTime()) or 0
		for _, e in ipairs(candidates) do
			local d = e.data
			if d and d.group and d.group ~= "" and d.group ~= "no" and e._computedPos then
				map[d.group] = map[d.group] or {}
				-- store/replace entry for this key
				local list = map[d.group]
				local found = false
				for i=1, table.getn(list) do
					if list[i].key == e.key then
						list[i] = { key = e.key, _computedPos = {
							x = e._computedPos.x, y = e._computedPos.y, size = e._computedPos.size
						} }
						found = true
						break
					end
				end
				if not found then
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

    for _, entry in ipairs(candidates) do
        local key, data = entry.key, entry.data
        local globalName = "DoiteIcon_" .. key
        local f = _G[globalName]

        if not f then
            f = CreateOrUpdateIcon(key, 36)
        end

        -- ensure drag scripts are correct (followers cannot start dragging)
        f:SetScript("OnDragStart", function()
			if data and data.group and data.group ~= "" and data.group ~= "no" and not data.isLeader then return end
			this:StartMoving()
		end)

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
			for i=1, table.getn(list) do
				local ge = list[i]
				if ge.key == key and ge._computedPos then
					posX = ge._computedPos.x
					posY = ge._computedPos.y
					size = ge._computedPos.size
					break
				end
			end
		end

		-- 3) If grouped follower and we still don't have a computed pos:
		--    don't snap back to saved offsets; leave point untouched (sticky) until next layout.
		if not posX then
			if isGrouped and not isLeader then
				-- keep current point; just use saved alpha/scale/size for visual consistency
				local currentSize = (data and (data.iconSize or data.size)) or 36
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
            else
                -- Grouped follower with no computed position this tick:
                -- DO NOT ClearAllPoints or SetPoint; keep last good layout anchor.
            end
        end

		-- Texture handling (with saved iconTexture fallback)
		local cache = DA_Cache()
		local displayName = (data and (data.displayName or data.name)) or key
		local texToUse = entry.tex
		  or cache[displayName]
		  or (data and data.iconTexture)


		if not texToUse and data and data.type == "Ability" then
		  local slot = FindSpellBookSlot(displayName)
		  if slot then texToUse = GetSpellTexture(slot, BOOKTYPE_SPELL) end
		end

		if texToUse then
		  -- Keep a name-level cache and also stamp it on this entry so it persists
		  cache[displayName] = texToUse
		  if data and not data.iconTexture then
			data.iconTexture = texToUse
		  end
		end

		f.icon:SetTexture(texToUse or "Interface\\Icons\\INV_Misc_QuestionMark")

		-- Visibility: conditions OR slide … but the group limit has final say
		local wantsFromConditions = (f._daShouldShow == true)
		local wantsFromSlide      = (f._daSliding == true)
		local blockedByGroup      = (f._daBlockedByGroup == true)

		local shouldBeVisible = (wantsFromConditions or wantsFromSlide) and (not blockedByGroup)
		if shouldBeVisible then
			f:Show()
		else
			f:Hide()
		end
    end
    _G["DoiteAuras_RefreshInProgress"] = false
end

-- Refresh list
local function RefreshList()
	  for _, v in pairs(spellButtons) do if v.Hide then v:Hide() end end
	  spellButtons = {}
	  local ordered = GetOrderedSpells()
	  local total   = table.getn(ordered)
	  listContent:SetHeight(math.max(160, total * 55))

	  -- NEW: build grouping info: baseKey -> {count, idxByKey}
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
		entry._groupIdx = groupIndex[base]
		entry._groupCnt = groupCount[base]
	  end

	  for i, entry in ipairs(ordered) do
		local key, data = entry.key, entry.data
		local base = BaseKeyFor(data)

		local display = data.displayName or key
		-- NEW: show "(i/N)" only if N > 1
		if entry._groupCnt and entry._groupCnt > 1 then
		  display = string.format("%s (%d/%d)", display, entry._groupIdx, entry._groupCnt)
		end

		local btn = CreateFrame("Frame", nil, listContent)
		btn:SetWidth(260); btn:SetHeight(50)

		btn.fontString = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		btn.fontString:SetPoint("TOPLEFT", btn, "TOPLEFT", 5, -5)
		btn.fontString:SetText(display)

		btn.tag = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		btn.tag:SetPoint("TOPLEFT", btn.fontString, "BOTTOMLEFT", 0, -2)
		if data.type == "Ability" then
		  btn.tag:SetText("|cff4da6ffAbility|r")
		elseif data.type == "Buff" then
		  btn.tag:SetText("|cff22ff22Buff|r")
		elseif data.type == "Debuff" then
		  btn.tag:SetText("|cffff4d4dDebuff|r")
		elseif data.type == "Item" then
		  btn.tag:SetText("|cffffffffItem|r")        -- white
		elseif data.type == "Bar" then
		  btn.tag:SetText("|cffff8000Bar|r")         -- orange
		end

        -- Remove
        btn.removeBtn=CreateFrame("Button",nil,btn,"UIPanelButtonTemplate")
        btn.removeBtn:SetWidth(60); btn.removeBtn:SetHeight(18)
        btn.removeBtn:SetPoint("TOPRIGHT",btn,"TOPRIGHT",-5,-25); btn.removeBtn:SetText("Remove")
        btn.removeBtn:SetScript("OnClick", function()
            -- Remove from DoiteAuras DB
            DoiteAurasDB.spells[key] = nil

            -- Also drop any legacy DoiteDB entry so evaluation stops touching this key
            if DoiteDB and DoiteDB.icons then
                DoiteDB.icons[key] = nil
            end

            -- Clear cached texture for this entry's display name (if any)
            local displayName = data and (data.displayName or data.name)
            if displayName and DoiteAurasDB and DoiteAurasDB.cache then
                DoiteAurasDB.cache[displayName] = nil
            end

            -- Hard-destroy the icon frame so no lingering "?" can remain
            local gname = "DoiteIcon_" .. key
            local f = _G[gname]
            if f then
                f:Hide()
                f:SetParent(nil)
                _G[gname] = nil
            end
            icons[key] = nil

            -- Hide the list row
            if spellButtons[key] and spellButtons[key].Hide then
                spellButtons[key]:Hide()
            end

            RebuildOrder()
            RefreshList()
            RefreshIcons()
            if DoiteConditions_RequestEvaluate then
                DoiteConditions_RequestEvaluate()
            end
        end)
        -- Edit
        btn.editBtn=CreateFrame("Button",nil,btn,"UIPanelButtonTemplate")
        btn.editBtn:SetWidth(50); btn.editBtn:SetHeight(18)
        btn.editBtn:SetPoint("RIGHT",btn.removeBtn,"LEFT",-5,0)
		btn.editBtn:SetText("Edit")
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

            elseif currentType == "Ability" then
                -- Switch to ability dropdown and select this spell if possible
                DA_UpdateTypeUI()
                if DA_RebuildAbilityDropDown then
                    DA_RebuildAbilityDropDown()
                end
                if abilityDropDown then
                    UIDropDownMenu_SetText(baseName, abilityDropDown)
                end

            else
                -- Buff / Debuff: keep using manual text input
                DA_UpdateTypeUI()
                input:SetText(baseName)
            end

            -- open conditions editor for this entry (pass the composite key)
            if DoiteConditions_Show then
                DoiteConditions_Show(key)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000DoiteAuras:|r DoiteConditions not loaded.")
            end
        end)


        -- Move buttons
        btn.downBtn=CreateFrame("Button",nil,btn); btn.downBtn:SetWidth(18); btn.downBtn:SetHeight(18)
        btn.downBtn:SetNormalTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollUpButton-Up")
        btn.downBtn:SetPushedTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollUpButton-Down")
        btn.downBtn:SetPoint("RIGHT",btn.editBtn,"LEFT",-5,0)
        btn.downBtn:SetScript("OnClick",function()
            local ord=GetOrderedSpells()
            for j=1,table.getn(ord) do if ord[j].key==key and j>1 then
                local above=ord[j-1].key; local tmp=DoiteAurasDB.spells[key].order
                DoiteAurasDB.spells[key].order=DoiteAurasDB.spells[above].order; DoiteAurasDB.spells[above].order=tmp
                RebuildOrder(); RefreshList(); RefreshIcons(); break end end
            if DoiteConditions_RequestEvaluate then DoiteConditions_RequestEvaluate() end
		end)
        btn.upBtn=CreateFrame("Button",nil,btn); btn.upBtn:SetWidth(18); btn.upBtn:SetHeight(18)
        btn.upBtn:SetNormalTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollDownButton-Up")
        btn.upBtn:SetPushedTexture("Interface\\MainMenuBar\\UI-MainMenu-ScrollDownButton-Down")
        btn.upBtn:SetPoint("RIGHT",btn.downBtn,"LEFT",-5,0)
        btn.upBtn:SetScript("OnClick",function()
            local ord=GetOrderedSpells()
            for j=1,table.getn(ord) do if ord[j].key==key and j<table.getn(ord) then
                local below=ord[j+1].key; local tmp=DoiteAurasDB.spells[key].order
                DoiteAurasDB.spells[key].order=DoiteAurasDB.spells[below].order; DoiteAurasDB.spells[below].order=tmp
                RebuildOrder(); RefreshList(); RefreshIcons(); break end end
			if DoiteConditions_RequestEvaluate then DoiteConditions_RequestEvaluate() end
		end)
        btn.sep=btn:CreateTexture(nil,"ARTWORK"); btn.sep:SetHeight(1)
        btn.sep:SetPoint("BOTTOMLEFT",btn,"BOTTOMLEFT",0,-2)
        btn.sep:SetPoint("BOTTOMRIGHT",btn,"BOTTOMRIGHT",0,-2); btn.sep:SetTexture(0.9,0.9,0.9,0.12)
        btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -10 - (i - 1) * 55)
    spellButtons[key] = btn
    btn:Show()
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

  -- Keep special headers exactly as written; everything else gets TitleCase
  local isSpecialHeader = (name == "---EQUIPPED TRINKET SLOTS---" or name == "---EQUIPPED WEAPON SLOTS---")
  if not isSpecialHeader then
      name = TitleCase(name)
  end

  -- Ability validation stays
  if t == "Ability" and not FindSpellBookSlot(name) then
    (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffff0000DoiteAuras:|r Spell not found in spellbook.")
    return
  end

  -- NEW: generate unique key; baseKey groups duplicates by name+type
  local key, baseKey, instanceIdx = GenerateUniqueKey(name, t)

  -- Order = append at end
  local nextOrder = table.getn(GetOrderedSpells()) + 1

  -- Create the DB entry (defaults filled later by EnsureDBEntry/DoiteEdit)
  DoiteAurasDB.spells[key] = {
    order = nextOrder,
    type  = t,
    displayName = name,
    baseKey = baseKey,  -- helpful but not required (we still compute BaseKeyFor on the fly)
    uid = instanceIdx,  -- 1 for the first, 2,3,... for next siblings
  }

  local entry = DoiteAurasDB.spells[key]
  local cache = DA_Cache()

  -- Auto-prime texture when we can:
  if t == "Ability" then
    local slot = FindSpellBookSlot(name)
    if slot then
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

  -- Icon (your DA tga)
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
    if DoiteAurasFrame and DoiteAurasFrame:IsShown() then
      DoiteAurasFrame:Hide()
    else
	-- center-on-open logic (keeps your Step #1 behavior)
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
    GameTooltip:AddLine("DOITEAURAS", 0.435, 0.659, 0.863) -- #6FA8DC
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
local _daMiniInit = CreateFrame("Frame")
_daMiniInit:RegisterEvent("ADDON_LOADED")
_daMiniInit:SetScript("OnEvent", function()
  if event ~= "ADDON_LOADED" or arg1 ~= "DoiteAuras" then return end
  DA_CreateMinimapButton()
end)

-- Slash
SLASH_DOITEAURAS1="/da"
SLASH_DOITEAURAS2="/doiteauras"
SLASH_DOITEAURAS3="/doiteaura"
SLASH_DOITEAURAS4="/doite"
SlashCmdList["DOITEAURAS"] = function()
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
  -- Reuse your existing DA_GetVersion() if present (minimap section defines it)
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
  local a,b,c = string.match(tostring(v or ""), "^(%d+)%.(%d+)%.?(%d*)$")
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

-- Small delayed runner (Vanilla/Turtle: use arg1 in OnUpdate)
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
local _daVer = CreateFrame("Frame")
_daVer:RegisterEvent("CHAT_MSG_ADDON")
_daVer:SetScript("OnEvent", function()
  if event ~= "CHAT_MSG_ADDON" then return end
  local prefix, text, channel, sender = arg1, arg2, arg3, arg4
  if prefix ~= DA_PREFIX or type(text) ~= "string" then return end

  local mine = tostring(DA_GetVersion_Safe())
  local cf   = (DEFAULT_CHAT_FRAME or ChatFrame1)

  if text == "DA_WHO" then
    -- someone asked; tell them our version back on the same channel
    if channel and SendAddonMessage then
      SendAddonMessage(DA_PREFIX, "DA_ME:" .. mine, channel)
    end
    return
  end

  if string.sub(text, 1, 6) == "DA_ME:" then
    local other = string.sub(text, 7)
    -- show who has what (your existing behavior)
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

local _daLoad = CreateFrame("Frame")
_daLoad:RegisterEvent("ADDON_LOADED")
_daLoad:RegisterEvent("PLAYER_ENTERING_WORLD")
_daLoad:RegisterEvent("RAID_ROSTER_UPDATE")

_daLoad:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and arg1 == "DoiteAuras" then
    -- 1s after load: print “loaded” line with version
    DA_RunLater(1, function()
      local v  = tostring(DA_GetVersion_Safe())
      local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
      if cf then
        cf:AddMessage("|cff6FA8DCDoiteAuras|r v"..v.." loaded. Use |cffffff00/da|r (or minimap icon).")
      end
    end)

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- 10s after entering world: broadcast my version to an available channel
    DA_RunLater(10, function()
      DA_BroadcastVersionAll()
    end)

  elseif event == "RAID_ROSTER_UPDATE" then
    -- first time you are in a raid: announce on RAID after ~3s
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
local updateFrame = CreateFrame("Frame")
updateFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
updateFrame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then RefreshIcons() end
end)

RebuildOrder(); RefreshList(); RefreshIcons()

DoiteAuras_RefreshList  = RefreshList
DoiteAuras_RefreshIcons = RefreshIcons

function DoiteAuras.GetAllCandidates()
    local list = {}
    local editKey = _G["DoiteEdit_CurrentKey"]
    local editFrame = _G["DoiteEdit_Frame"] or _G["DoiteEditMain"] or _G["DoiteEdit"]
    local editOpen = (editFrame and editFrame.IsShown and editFrame:IsShown() == 1)

    for key, data in pairs(DoiteAurasDB.spells or {}) do
        local f = _G["DoiteIcon_" .. key]
        -- Intent-based visibility: conditions OR active slide
        local wants = false
        if f then
            wants = (f._daShouldShow == true) or (f._daSliding == true)
        end
        -- While editing: force the edited key into the pool so groups can place it
        if editOpen and editKey == key then wants = true end

        table.insert(list, {
            key  = key,
            data = data,
            show = wants,
            tex  = (f and f.icon and f.icon:GetTexture()) or nil,
            size = data.iconSize or data.size or 36,
        })
    end
    return list
end

-- Ensure an icon frame exists for a given key (no visibility changes)
function DoiteAuras_TouchIcon(key)
  if not key then return end
  local name = "DoiteIcon_"..key
  if _G[name] then return end
  if CreateOrUpdateIcon then CreateOrUpdateIcon(key, 36) end
end