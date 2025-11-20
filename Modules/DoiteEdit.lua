-- DoiteEdit.lua
-- Secondary frame for editing Aura conditions / edit UI
-- Attached to DoiteAuras main frame (DoiteAurasFrame)

if DoiteConditionsFrame then
    DoiteConditionsFrame:Hide()
    DoiteConditionsFrame = nil
end

local condFrame = nil
local currentKey = nil
local SafeRefresh
local SafeEvaluate
local srows
local ShowSeparatorsForType
local SetSeparator

-- Per-type containers for the new dynamic "Aura Conditions" rows
local AuraCond_Managers = {}
local AuraCond_RegisterManager -- called from CreateConditionsUI
local AuraCond_RefreshFromDB   -- called from UpdateConditionsUI
local AuraCond_ResetEditing    -- currently a no-op, reserved for future if needed

-- class gate used by UpdateConditionsUI and others
local function _IsRogueOrDruid()
    local _, c = UnitClass("player")
    c = c and string.upper(c) or ""
    return (c == "ROGUE" or c == "DRUID")
end

-- Lightweight Cursive detection (evaluated on demand so load order doesn't matter)
local function _HasCursive()
    if type(Cursive) ~= "table" then return false end
    local curses = Cursive.curses
    if type(curses) ~= "table" then return false end
    -- We only test for APIs we plan to rely on; no calls are made here.
    if type(curses.GetCurseData) ~= "function" then return false end
    if type(curses.TimeRemaining) ~= "function" then return false end
    return true
end

-- === Lightweight throttle for heavy UI work (prevents lag while dragging sliders) ===
local _DoiteEdit_PendingHeavy = false
local _DoiteEdit_Accum = 0
local _DoiteEdit_Throttle = CreateFrame("Frame")

-- Global flag toggled while the main Edit or Main frames are being dragged
_G["DoiteUI_Dragging"] = _G["DoiteUI_Dragging"] or false

local function DoiteEdit_QueueHeavy()
    _DoiteEdit_PendingHeavy = true
end

local function DoiteEdit_FlushHeavy()
    _DoiteEdit_PendingHeavy = false
    _DoiteEdit_Accum = 0
    -- one combined heavy pass
    SafeRefresh()
    SafeEvaluate()
end

_DoiteEdit_Throttle:SetScript("OnUpdate", function()
    if not _DoiteEdit_PendingHeavy then return end
    if _G["DoiteUI_Dragging"] then return end  -- defer while the user is dragging frames
    _DoiteEdit_Accum = _DoiteEdit_Accum + (arg1 or 0)
    if _DoiteEdit_Accum >= 0.05 then           -- ~20 fps cap for heavy work while sliding
        DoiteEdit_FlushHeavy()
    end
end)

-- Ensure DB entry exists for a key
local function EnsureDBEntry(key)
    if not DoiteAurasDB.spells[key] then
        DoiteAurasDB.spells[key] = {
            order = 999,
            type = "Ability",
            displayName = key,
            growth = "Horizontal Right",
            numAuras = 5,
            offsetX = 0,
            offsetY = 0,
            iconSize = 40,
            conditions = {}
        }
    end

    local d = DoiteAurasDB.spells[key]

    -- general defaults (don't override existing values)
    if not d.growth then d.growth = "Horizontal Right" end
    if not d.numAuras then d.numAuras = 5 end
    if not d.offsetX then d.offsetX = 0 end
    if not d.offsetY then d.offsetY = 0 end
    if not d.iconSize then d.iconSize = 40 end
    if not d.conditions then d.conditions = {} end

    -- create ONLY the correct subtable for this entry type and prune the other ones
    if d.type == "Ability" then
        -- keep ability; remove aura/item
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.aura    = nil
        d.conditions.item    = nil
		-- dynamic Aura Conditions (extra Buff/Debuff checks)
        if not d.conditions.ability.auraConditions then
            d.conditions.ability.auraConditions = {}
        end

        -- defaults (ability)
        if d.conditions.ability.mode        == nil then d.conditions.ability.mode        = "notcd" end
        if d.conditions.ability.inCombat    == nil then d.conditions.ability.inCombat    = true    end
        if d.conditions.ability.outCombat   == nil then d.conditions.ability.outCombat   = true    end
        if d.conditions.ability.targetHelp  == nil then d.conditions.ability.targetHelp  = false   end
        if d.conditions.ability.targetHarm  == nil then d.conditions.ability.targetHarm  = false   end
        if d.conditions.ability.targetSelf  == nil then d.conditions.ability.targetSelf  = false   end
        if d.conditions.ability.form        == nil then d.conditions.ability.form        = "All"   end

        -- legacy cleanup
        d.conditions.ability.target = nil

	elseif d.type == "Item" then
		-- keep item; remove ability/aura
		d.conditions.item    = d.conditions.item or {}
		d.conditions.ability = nil
		d.conditions.aura    = nil

		-- defaults (item)
		local ic = d.conditions.item

		-- dynamic Aura Conditions (extra Buff/Debuff checks)
		if not ic.auraConditions then
			ic.auraConditions = {}
		end

		if ic.whereEquipped == nil then ic.whereEquipped = true  end
		if ic.whereBag      == nil then ic.whereBag      = true  end
		if ic.whereMissing  == nil then ic.whereMissing  = false end

		if ic.mode          == nil then ic.mode          = "notcd" end
		if ic.inCombat      == nil then ic.inCombat      = true    end
		if ic.outCombat     == nil then ic.outCombat     = true    end
		if ic.targetHelp    == nil then ic.targetHelp    = false   end
		if ic.targetHarm    == nil then ic.targetHarm    = false   end
		if ic.targetSelf    == nil then ic.targetSelf    = false   end
		if ic.form          == nil then ic.form          = "All"   end

    else -- Buff / Debuff (treat anything not "Ability"/"Item" as an aura carrier)
        -- keep aura; remove ability/item
        d.conditions.aura    = d.conditions.aura or {}
        d.conditions.ability = nil
        d.conditions.item    = nil
		-- dynamic Aura Conditions (extra Buff/Debuff checks)
        if not d.conditions.aura.auraConditions then
            d.conditions.aura.auraConditions = {}
        end


        -- defaults (aura)
        if d.conditions.aura.mode        == nil then d.conditions.aura.mode        = "found" end
        if d.conditions.aura.inCombat    == nil then d.conditions.aura.inCombat    = true    end
        if d.conditions.aura.outCombat   == nil then d.conditions.aura.outCombat   = true    end
        if d.conditions.aura.targetSelf  == nil then d.conditions.aura.targetSelf  = true    end  -- default self
        if d.conditions.aura.targetHelp  == nil then d.conditions.aura.targetHelp  = false   end
        if d.conditions.aura.targetHarm  == nil then d.conditions.aura.targetHarm  = false   end
        if d.conditions.aura.form        == nil then d.conditions.aura.form        = "All"   end

        -- legacy cleanup
        d.conditions.aura.target       = nil
        d.conditions.aura.targetTarget = nil
    end

    return d
end

-- clear a dropdown so it can be safely re-initialized
local function ClearDropdown(dd)
    if not dd then return end
    if UIDropDownMenu_Initialize then
        pcall(UIDropDownMenu_Initialize, dd, function() end)
    end
    if UIDropDownMenu_ClearAll then
        pcall(UIDropDownMenu_ClearAll, dd)
    end
    dd._initializedForKey = nil
    dd._initializedForType = nil
end

local function BuildGroupLeaders()
    local leaders = {}
    for k, v in pairs(DoiteAurasDB.spells) do
        if v.group and v.isLeader then
            leaders[v.group] = k
        end
    end
    return leaders
end

SafeEvaluate = function()
  if DoiteConditions_RequestEvaluate then
    DoiteConditions_RequestEvaluate()
  elseif DoiteConditions and DoiteConditions.EvaluateAll then
    DoiteConditions:EvaluateAll()
  end
end

SafeRefresh = function()
  if DoiteAuras_RefreshList then DoiteAuras_RefreshList() end
  if DoiteAuras_RefreshIcons then DoiteAuras_RefreshIcons() end
end

-- === Dynamic bounds for Position & Size sliders (based on UIParent) ===
local function _DA_GetParentDims()
    local w = (UIParent and UIParent.GetWidth and UIParent:GetWidth()) or (GetScreenWidth and GetScreenWidth()) or 1024
    local h = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or (GetScreenHeight and GetScreenHeight()) or 768
    return w, h
end

-- compute ranges:
--  X/Y are offsets from CENTER, so bounds are roughly +/- half the parent size (with a tiny padding)
--  Size max scales with the smaller screen dimension so big resolutions can use larger icons.
local function _DA_ComputePosSizeRanges()
    local w, h = _DA_GetParentDims()
    local pad = 4
    local halfW = math.floor(w * 0.5 + 0.5)
    local halfH = math.floor(h * 0.5 + 0.5)

    local minX, maxX = -halfW + pad, halfW - pad
    local minY, maxY = -halfH + pad, halfH - pad

    local minSize = 10
    -- cap icon at ~20% of the shortest side, but never below 100 so small res behaves like before
    local maxSize = math.max(100, math.floor(math.min(w, h) * 0.20 + 0.5))

    return minX, maxX, minY, maxY, minSize, maxSize
end

-- apply to existing sliders and clamp the current DB values if out of range
local function _DA_ApplySliderRanges()
    if not condFrame or not condFrame.sliderX or not condFrame.sliderY or not condFrame.sliderSize then return end

    local minX, maxX, minY, maxY, minSize, maxSize = _DA_ComputePosSizeRanges()

    -- X
    condFrame.sliderX:SetMinMaxValues(minX, maxX)
    local lowX  = _G[condFrame.sliderX:GetName() .. "Low"]
    local highX = _G[condFrame.sliderX:GetName() .. "High"]
    if lowX  then lowX:SetText(tostring(minX)) end
    if highX then highX:SetText(tostring(maxX)) end

    -- Y
    condFrame.sliderY:SetMinMaxValues(minY, maxY)
    local lowY  = _G[condFrame.sliderY:GetName() .. "Low"]
    local highY = _G[condFrame.sliderY:GetName() .. "High"]
    if lowY  then lowY:SetText(tostring(minY)) end
    if highY then highY:SetText(tostring(maxY)) end

    -- Size
    condFrame.sliderSize:SetMinMaxValues(minSize, maxSize)
    local lowS  = _G[condFrame.sliderSize:GetName() .. "Low"]
    local highS = _G[condFrame.sliderSize:GetName() .. "High"]
    if lowS  then lowS:SetText(tostring(minSize)) end
    if highS then highS:SetText(tostring(maxSize)) end

    -- Clamp current values (and DB) into the new ranges
    local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

    if currentKey then
        local d = DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[currentKey]
        if d then
            d.offsetX = clamp(d.offsetX or 0, minX, maxX)
            d.offsetY = clamp(d.offsetY or 0, minY, maxY)
            d.iconSize = clamp(d.iconSize or 40, minSize, maxSize)
        end
    end

    -- Push clamped values into sliders/boxes
    if currentKey then
        local d = DoiteAurasDB.spells[currentKey]
        if d then
            condFrame.sliderX:SetValue(d.offsetX or 0)
            condFrame.sliderY:SetValue(d.offsetY or 0)
            condFrame.sliderSize:SetValue(d.iconSize or 40)
            if condFrame.sliderXBox then condFrame.sliderXBox:SetText(tostring(math.floor((d.offsetX or 0) + 0.5))) end
            if condFrame.sliderYBox then condFrame.sliderYBox:SetText(tostring(math.floor((d.offsetY or 0) + 0.5))) end
            if condFrame.sliderSizeBox then condFrame.sliderSizeBox:SetText(tostring(math.floor((d.iconSize or 40) + 0.5))) end
        end
    end
end


-- Internal: initialize group dropdown contents for current data
local function InitGroupDropdown(dd, data)
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        local info
        local choices = { "No" }
        for i = 1, 10 do table.insert(choices, "Group " .. tostring(i)) end

        for _, choice in ipairs(choices) do
            info = {}
            info.text = choice
            info.value = choice
            local pickedChoice = choice
            info.func = function(button)
                local picked = (button and button.value) or pickedChoice
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)

                if picked == "No" then
                    d.group = nil
                    d.isLeader = false
                else
                    local leaders = BuildGroupLeaders()
                    d.group = picked
                    if not leaders[picked] then
                        d.isLeader = true
                    else
                        if leaders[picked] ~= currentKey then
                            d.isLeader = false
                        end
                    end
                end

                UIDropDownMenu_SetSelectedValue(dd, picked)
                UIDropDownMenu_SetText(picked, dd)
                CloseDropDownMenus()
                UpdateCondFrameForKey(currentKey)
                SafeRefresh()
				SafeEvaluate()
            end

            if data and ((not data.group and choice == "No") or (data.group == choice)) then
                info.checked = true
            else
                info.checked = false
            end

            UIDropDownMenu_AddButton(info)
        end
    end)
end

-- Internal: initialize growth direction dropdown (leader-only control)
local function InitGrowthDropdown(dd, data)
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        local info
        local directions = { "Horizontal Right", "Horizontal Left", "Vertical Down", "Vertical Up" }
        for _, dir in ipairs(directions) do
            info = {}
            info.text = dir
            info.value = dir
            local pickedDir = dir
            info.func = function(button)
                local picked = (button and button.value) or pickedDir
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)
                d.growth = picked
                UIDropDownMenu_SetSelectedValue(dd, picked)
                UIDropDownMenu_SetText(picked, dd)
                CloseDropDownMenus()
                SafeRefresh()
				SafeEvaluate()
            end
            info.checked = (data and data.growth == dir)
            UIDropDownMenu_AddButton(info)
        end
    end)
end

-- Internal: initialize numAuras dropdown (leader-only control)
local function InitNumAurasDropdown(dd, data)
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        local info
        for i = 1, 10 do
            info = {}
            info.text = tostring(i)
            info.value = i
            local pickedNum = i
            info.func = function(button)
                local picked = (button and button.value) or pickedNum
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)
                d.numAuras = picked
                UIDropDownMenu_SetSelectedValue(dd, picked)
                UIDropDownMenu_SetText(tostring(picked), dd)
                CloseDropDownMenus()
                SafeRefresh()
				SafeEvaluate()
            end
            info.checked = (data and data.numAuras == i)
            UIDropDownMenu_AddButton(info)
        end
        info = {}
        info.text = "Unlimited"
        info.value = "Unlimited"
        info.func = function(button)
            local picked = (button and button.value) or "Unlimited"
            if not currentKey then return end
            local d = EnsureDBEntry(currentKey)
            d.numAuras = picked
            UIDropDownMenu_SetSelectedValue(dd, picked)
            UIDropDownMenu_SetText(picked, dd)
            CloseDropDownMenus()
            SafeRefresh()
			SafeEvaluate()
        end
        info.checked = (data and data.numAuras == "Unlimited")
        UIDropDownMenu_AddButton(info)
    end)
end

-- Unified Form/Stance dropdown initializer (works for Ability / Aura / Item)
local function InitFormDropdown(dd, data, condType)
    if not dd then return end
    condType = condType or "ability"

    local thisKey = currentKey
    if not thisKey then
        ClearDropdown(dd)
        return
    end

    if dd._initializedForKey == thisKey and dd._initializedForType == condType then
        return
    end

    -- Determine player class and build options (reordered + Priest added)
    local _, class = UnitClass("player")
    class = class and string.upper(class) or ""

    local forms = {}
    if class == "DRUID" then
        forms = {
            "All forms",
            "0. No forms", "1. Bear", "2. Aquatic", "3. Cat", "4. Travel",
            "5. Moonkin", "6. Tree", "7. Stealth", "8. No Stealth",
            "Multi: 0+5", "Multi: 0+6", "Multi: 1+3", "Multi: 3+7", "Multi: 3+8",
            "Multi: 5+6", "Multi: 0+5+6", "Multi: 1+3+8"
        }
    elseif class == "WARRIOR" then
        forms = { "All stances", "1. Battle", "2. Defensive", "3. Berserker",
                  "Multi: 1+2", "Multi: 1+3", "Multi: 2+3" }
    elseif class == "ROGUE" then
        forms = { "All forms", "0. No Stealth", "1. Stealth" }
    elseif class == "PRIEST" then
        forms = { "All forms", "0. No form", "1. Shadowform" }
    elseif class == "PALADIN" then
        forms = {
            "All Auras", "No Aura", "1. Devotion", "2. Retribution", "3. Concentration",
            "4. Shadow Resistance", "5. Frost Resistance", "6. Fire Resistance", "7. Sanctity",
            "Multi: 1+2", "Multi: 1+3", "Multi: 1+4+5+6", "Multi: 1+7", "Multi: 1+2+3", "Multi: 1+2+3+4+5+6",
            "Multi: 2+3", "Multi: 2+4+5+6", "Multi: 2+7", "Multi: 2+3+4+5+6",
            "Multi: 3+4+5+6", "Multi: 3+7",
            "Multi: 4+5+6+7"
        }
    else
        dd:Hide()
        return
    end

    -- make absolutely sure the old menu is cleared before building
    ClearDropdown(dd)

    -- Build/initialize the dropdown
    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        for i, form in ipairs(forms) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = form
            info.value = form
            local pickedForm = form -- capture

			info.func = function(button)
				local picked = (button and button.value) or pickedForm
				UIDropDownMenu_SetSelectedValue(dd, picked)
				UIDropDownMenu_SetText(picked, dd)

				if condType == "ability" then
					data.conditions.ability = data.conditions.ability or {}
					data.conditions.ability.form = picked
				elseif condType == "aura" then
					data.conditions.aura = data.conditions.aura or {}
					data.conditions.aura.form = picked
				elseif condType == "item" then
					data.conditions.item = data.conditions.item or {}
					data.conditions.item.form = picked
				end

				SafeRefresh()
				SafeEvaluate()
				UpdateCondFrameForKey(currentKey)
			end

            -- checked state based on the passed `data`
            local savedForm = (data and data.conditions and data.conditions[condType] and data.conditions[condType].form)
            info.checked = (savedForm == form)

            UIDropDownMenu_AddButton(info)
        end
    end)

    -- Restore visible value (saved or default)
    local savedForm = (data and data.conditions and data.conditions[condType] and data.conditions[condType].form)

    local matched = false
    if savedForm and savedForm ~= "All" and savedForm ~= "" then
        for i, f in ipairs(forms) do
            if f == savedForm then
                UIDropDownMenu_SetSelectedID(dd, i)
                matched = true
                break
            end
        end
    end

    if matched then
        UIDropDownMenu_SetText(savedForm, dd)
    else
        UIDropDownMenu_SetText("Select form", dd)
    end

    dd._initializedForKey = thisKey
    dd._initializedForType = condType
end


----------------------------------------------------------------
-- Exclusive helper functions
----------------------------------------------------------------
local function SetExclusiveAbilityMode(mode)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions.ability = d.conditions.ability or {}
    d.conditions.ability.mode = mode
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
	SafeEvaluate()
end

local function SetExclusiveItemMode(mode)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions.item = d.conditions.item or {}
    d.conditions.item.mode = mode
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
    SafeEvaluate()
end

-- independent combat flag toggles (inCombat / outCombat)
local function SetCombatFlag(typeTable, which, enabled)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions[typeTable] = d.conditions[typeTable] or {}

    -- hard separation: never allow the opposite table to exist
    if typeTable == "ability" then
        d.conditions.aura = nil
        d.conditions.item = nil
    elseif typeTable == "aura" then
        d.conditions.ability = nil
        d.conditions.item = nil
    elseif typeTable == "item" then
        d.conditions.ability = nil
        d.conditions.aura = nil
    end

    if which == "in" then
        d.conditions[typeTable].inCombat = enabled and true or false
    elseif which == "out" then
        d.conditions[typeTable].outCombat = enabled and true or false
    end
    d.conditions[typeTable].combat = nil
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
	SafeEvaluate()
end

local function SetExclusiveTargetMode(mode)
    -- legacy no-op; we now use ability.targetHelp/targetHarm/targetSelf
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    if d and d.conditions and d.conditions.ability then
        d.conditions.ability.target = nil
    end
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
    SafeEvaluate()
end

local function SetExclusiveAuraFoundMode(mode)
    if not currentKey then return end
    local d = EnsureDBEntry(currentKey)
    d.conditions = d.conditions or {}
    d.conditions.aura = d.conditions.aura or {}
    d.conditions.aura.mode = mode
    UpdateCondFrameForKey(currentKey)
    SafeRefresh()
	SafeEvaluate()
end

-- File-scope helper so both CreateConditionsUI and UpdateConditionsUI can call it
local function _GoldifyDD(dd)
    if not dd or not dd.GetName then return end
    local name = dd:GetName()
    if not name then return end
    local txt = _G[name .. "Text"]
    if txt and txt.SetTextColor then txt:SetTextColor(1, 0.82, 0) end
end

local function _GreyifyDD(dd)
    if not dd or not dd.GetName then return end
    local name = dd:GetName()
    local txt = _G[name .. "Text"]
    if txt and txt.SetTextColor then txt:SetTextColor(0.6, 0.6, 0.6) end
end

-- Local copy of the TitleCase helper used by DoiteAuras (for pretty printing aura names)
local function AuraCond_TitleCase(str)
    if not str then return "" end
    str = tostring(str)
    local exceptions = {
        ["of"]=true, ["and"]=true, ["the"]=true, ["for"]=true,
        ["in"]=true, ["on"]=true, ["to"]=true, ["a"]=true,
        ["an"]=true, ["with"]=true, ["by"]=true, ["at"]=true
    }
    local result, first = "", true
    local word
    for word in string.gmatch(str, "%S+") do
        local startsParen = (string.sub(word, 1, 1) == "(")
        local leading = startsParen and "(" or ""
        local core = startsParen and string.sub(word, 2) or word

        local lowerCore = string.lower(core or "")
        local c = string.sub(core or "", 1, 1) or ""
        local rest = string.sub(core or "", 2) or ""

        if first then
            result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
            first = false
        else
            if startsParen then
                result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
            elseif exceptions[lowerCore] then
                result = result .. lowerCore .. " "
            else
                result = result .. leading .. string.upper(c) .. string.lower(rest) .. " "
            end
        end
    end
    result = string.gsub(result, "%s+$", "")
    return result
end

----------------------------------------------------------------
-- Conditions UI creation & wiring
----------------------------------------------------------------
local function CreateConditionsUI()
    if not condFrame then return end

    -- helpers (parent to the scrollable content area)
	local function _Parent()
		return (condFrame and condFrame._condArea) or condFrame
	end

	local function MakeCheck(name, label, x, y)
		local parent = _Parent()
		local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
		cb:SetWidth(20); cb:SetHeight(20)
		cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
		cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		cb.text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
		cb.text:SetText(label)
		return cb
	end

	local function MakeComparatorDD(name, x, y, width)
		local parent = _Parent()
		local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
		dd:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
		if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, width or 55, dd) end
		return dd
	end

	local function MakeSmallEdit(name, x, y, width)
		local parent = _Parent()
		local eb = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
		eb:SetWidth(width or 44)
		eb:SetHeight(18)
		eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
		eb:SetAutoFocus(false)
		eb:SetJustifyH("CENTER")
		eb:SetFontObject("GameFontNormalSmall")
		return eb
	end

    -- renders a small bold white title with a "split" separator line that does not pass under the text
    local function MakeSeparatorRow(parent, y, title, drawLine)
        drawLine = (drawLine ~= false)
        local holder = CreateFrame("Frame", nil, parent)
        holder:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
        holder:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, y)
        holder:SetHeight(16)

        local label = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        label:SetJustifyH("LEFT")
        label:SetText("|cffffffff" .. (title or "") .. "|r")

        local lineY = -8
        local lineL = holder:CreateTexture(nil, "ARTWORK")
        lineL:SetHeight(1); lineL:SetTexture(1,1,1); lineL:SetVertexColor(1,1,1,0.25)
        lineL:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, lineY)
        lineL:SetPoint("TOPRIGHT", label, "TOPLEFT", -6, lineY)

        local lineR = holder:CreateTexture(nil, "ARTWORK")
        lineR:SetHeight(1); lineR:SetTexture(1,1,1); lineR:SetVertexColor(1,1,1,0.25)
        lineR:SetPoint("TOPLEFT", label, "TOPRIGHT", 6, lineY)
        lineR:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, lineY)

        if not drawLine then lineL:Hide(); lineR:Hide() end

        holder._label = label
        holder._lineL = lineL
        holder._lineR = lineR
        holder:Hide() -- start hidden; visibility handled by manager
        return holder
    end

    local function SetSeparatorLineVisible(sep, visible)
        if not sep then return end
        if visible then
            if sep._lineL then sep._lineL:Show() end
            if sep._lineR then sep._lineR:Show() end
        else
            if sep._lineL then sep._lineL:Hide() end
            if sep._lineR then sep._lineR:Hide() end
        end
    end
	
    -- === Separator Y positions ===
    local srow1_y, srow2_y, srow3_y, srow4_y, srow5_y  = -5, -45, -85, -125, -165
    local srow6_y, srow7_y, srow8_y, srow9_y, srow10_y = -205, -245, -285, -325, -365
    local srow11_y, srow12_y, srow13_y, srow14_y, srow15_y = -405, -445, -485, -525, -565
    local srow16_y, srow17_y, srow18_y, srow19_y, srow20_y = -605, -645, -685, -725, -765

    srows = {
        srow1_y, srow2_y, srow3_y, srow4_y, srow5_y,
        srow6_y, srow7_y, srow8_y, srow9_y, srow10_y,
        srow11_y, srow12_y, srow13_y, srow14_y, srow15_y,
        srow16_y, srow17_y, srow18_y, srow19_y, srow20_y
    }

    -- === Per-type separator caches (ability/aura/item are independent)
    condFrame._seps = condFrame._seps or { ability = {}, aura = {}, item = {} }

    local function _EnsureSep(typeKey, slot)
        local list = condFrame._seps[typeKey]
        if not list[slot] then
            local y = srows[slot] or srows[1]
            list[slot] = MakeSeparatorRow(_Parent(), y, "", true)
            list[slot]._visible = false
            list[slot]._lineOn  = true
        end
        return list[slot]
    end

    -- typeKey = "ability" | "aura" | "item"; slot = 1..20
    SetSeparator = function(typeKey, slot, title, showLine, isVisible)
        if typeKey ~= "ability" and typeKey ~= "aura" and typeKey ~= "item" then return end
        if slot < 1 or slot > 20 then return end
        local sep = _EnsureSep(typeKey, slot)
        if sep._label then
            sep._label:SetText("|cffffffff" .. (title or "") .. "|r")
        end
        sep._lineOn  = (showLine ~= false)
        SetSeparatorLineVisible(sep, sep._lineOn)
        sep._visible = (isVisible and true) or false
        if sep._visible then
            sep:Show()
        else
            sep:Hide()
        end
        return sep
    end

    -- exported: UpdateConditionsUI calls this
    ShowSeparatorsForType = function(typeKey)
        -- Hide every separator first
        for _, list in pairs(condFrame._seps) do
            for _, sep in pairs(list) do
                sep:Hide()
            end
        end
        -- Then reveal only this type’s visible ones (with line state)
        local mine = condFrame._seps[typeKey] or {}
        for _, sep in pairs(mine) do
            if sep._visible then
                SetSeparatorLineVisible(sep, sep._lineOn)
                sep:Show()
            end
        end
    end

    -- row positions
	local row1_y, row2_y, row3_y, row4_y, row5_y  = -20, -60, -100, -140, -180
	local row6_y, row7_y, row8_y, row9_y, row10_y = -220, -260, -300, -340, -380
	local row11_y, row12_y, row13_y, row14_y, row15_y = -420, -460, -500, -540, -580
	local row16_y, row17_y, row18_y, row19_y, row20_y = -620, -660, -700, -740, -780

	condFrame._rowY = {
		[7]  = row7_y,
		[8]  = row8_y,
		[10] = row10_y,
		[11] = row11_y,
	}

    --------------------------------------------------
    -- Ability rows
    --------------------------------------------------
    if GetNampowerVersion then
        condFrame.cond_ability_usable = MakeCheck("DoiteCond_Ability_Usable", "Usable", 0, row1_y)
    else
        condFrame.cond_ability_usable = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.cond_ability_usable:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 4, row1_y + 3)
        condFrame.cond_ability_usable:SetText("(Usable req. Nampower mod)")
        condFrame.cond_ability_usable:SetWidth(80)
    end
    condFrame.cond_ability_notcd  = MakeCheck("DoiteCond_Ability_NotCD", "Not on cooldown", 70, row1_y)
    condFrame.cond_ability_oncd   = MakeCheck("DoiteCond_Ability_OnCD", "On cooldown", 190, row1_y)
	SetSeparator("ability", 1, "USABILITY & COOLDOWN", true, true)

    condFrame.cond_ability_incombat   = MakeCheck("DoiteCond_Ability_InCombat", "In combat", 0, row2_y)
    condFrame.cond_ability_outcombat  = MakeCheck("DoiteCond_Ability_OutCombat", "Out of combat", 80, row2_y)
	SetSeparator("ability", 2, "COMBAT STATE", true, true)

    condFrame.cond_ability_target_help = MakeCheck("DoiteCond_Ability_TargetHelp", "Target (help)", 0, row3_y)
    condFrame.cond_ability_target_harm = MakeCheck("DoiteCond_Ability_TargetHarm", "Target (harm)", 95, row3_y)
    condFrame.cond_ability_target_self = MakeCheck("DoiteCond_Ability_TargetSelf", "Target (self)", 200, row3_y)
	SetSeparator("ability", 3, "TARGET CONDITIONS", true, true)

    condFrame.cond_ability_glow = MakeCheck("DoiteCond_Ability_Glow", "Glow", 0, row4_y)
	condFrame.cond_ability_greyscale = MakeCheck("DoiteCond_Ability_Greyscale", "Grey", 70, row4_y)
	condFrame.cond_ability_slider_glow = MakeCheck("DoiteCond_Ability_SliderGlow", "CD Glow", 140, row4_y)
    condFrame.cond_ability_slider_grey = MakeCheck("DoiteCond_Ability_SliderGrey", "CD Grey", 220, row4_y)
	SetSeparator("ability", 4, "VISUAL EFFECTS", true, true)
	
	condFrame.cond_ability_slider = MakeCheck("DoiteCond_Ability_Slider", "Soon off CD indicator", 0, row5_y)
    condFrame.cond_ability_slider_dir = CreateFrame("Frame", "DoiteCond_Ability_SliderDir", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_ability_slider_dir:SetPoint("LEFT", condFrame.cond_ability_slider, "RIGHT", 110, -3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 60, condFrame.cond_ability_slider_dir) end
    condFrame.cond_ability_remaining_cb   = MakeCheck("DoiteCond_Ability_RemainingCB", "Remaining", 0, row5_y)
    condFrame.cond_ability_remaining_comp = MakeComparatorDD("DoiteCond_Ability_RemComp", 65, row5_y+3, 50)
    condFrame.cond_ability_remaining_val  = MakeSmallEdit("DoiteCond_Ability_RemVal", 160, row5_y-2, 40)
    condFrame.cond_ability_remaining_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_remaining_val_enter:SetPoint("LEFT", condFrame.cond_ability_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_ability_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_ability_remaining_val_enter:Hide()
	SetSeparator("ability", 5, "REMAINING TIME", true, true)
	
    condFrame.cond_ability_power = MakeCheck("DoiteCond_Ability_PowerCB", "Power", 0, row6_y)
    condFrame.cond_ability_power_comp = MakeComparatorDD("DoiteCond_Ability_PowerComp", 65, row6_y+3, 50)
    condFrame.cond_ability_power_val  = MakeSmallEdit("DoiteCond_Ability_PowerVal", 160, row6_y-2, 40)
    condFrame.cond_ability_power_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_power_val_enter:SetPoint("LEFT", condFrame.cond_ability_power_val, "RIGHT", 4, 0)
    condFrame.cond_ability_power_val_enter:SetText("(%)")
    condFrame.cond_ability_power_val_enter:Hide()
	SetSeparator("ability", 6, "RESOURCE", true, true)
	
	condFrame.cond_ability_hp_my   = MakeCheck("DoiteCond_Ability_HP_My", "My HP", 0, row7_y)
    condFrame.cond_ability_hp_tgt  = MakeCheck("DoiteCond_Ability_HP_Tgt", "Target HP", 65, row7_y)
    condFrame.cond_ability_hp_comp = MakeComparatorDD("DoiteCond_Ability_HP_Comp", 130, row7_y+3, 50)
    condFrame.cond_ability_hp_val  = MakeSmallEdit("DoiteCond_Ability_HP_Val", 225, row7_y-2, 40)
    condFrame.cond_ability_hp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_hp_val_enter:SetPoint("LEFT", condFrame.cond_ability_hp_val, "RIGHT", 4, 0)
    condFrame.cond_ability_hp_val_enter:SetText("(%)")
    condFrame.cond_ability_hp_comp:Hide()
    condFrame.cond_ability_hp_val:Hide()
    condFrame.cond_ability_hp_val_enter:Hide()
	SetSeparator("ability", 7, "HEALTH CONDITION", true, true)
	
	condFrame.cond_ability_text_time = MakeCheck("DoiteCond_Ability_TextTime", "Text: Time remaining", 0, row8_y)
	SetSeparator("ability", 8, "ICON TEXT", true, true)

    condFrame.cond_ability_cp_cb   = MakeCheck("DoiteCond_Ability_CP_CB", "Combo points", 0, row9_y)
    condFrame.cond_ability_cp_comp = MakeComparatorDD("DoiteCond_Ability_CP_Comp", 85, row9_y+3, 50)
    condFrame.cond_ability_cp_val  = MakeSmallEdit("DoiteCond_Ability_CP_Val", 180, row9_y-2, 40)
    condFrame.cond_ability_cp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_cp_val_enter:SetPoint("LEFT", condFrame.cond_ability_cp_val, "RIGHT", 4, 0)
    condFrame.cond_ability_cp_val_enter:SetText("(#)")
    condFrame.cond_ability_cp_val_enter:Hide()
    SetSeparator("ability", 9, "CLASS-SPECIFIC", true, true)

    -- Ability: class-specific note for classes without combo points
    condFrame.cond_ability_class_note = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_class_note:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 0, row9_y)
    condFrame.cond_ability_class_note:SetTextColor(1, 0.82, 0)
    condFrame.cond_ability_class_note:SetText("No class-specific option added for your class.")
    condFrame.cond_ability_class_note:Hide()
	
	-- Ability: dynamic Aura Conditions section
    local abilityAuraBaseY = row10_y
    SetSeparator("ability", 10, "ABILITY, BUFF & DEBUFF CONDITIONS", true, true)
    condFrame.abilityAuraAnchor = CreateFrame("Frame", nil, _Parent())
    condFrame.abilityAuraAnchor:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, abilityAuraBaseY)
    condFrame.abilityAuraAnchor:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, abilityAuraBaseY)
    condFrame.abilityAuraAnchor:SetHeight(20)

    --------------------------------------------------
    -- Buff/Debuff rows
    --------------------------------------------------
    condFrame.cond_aura_found   = MakeCheck("DoiteCond_Aura_Found", "Aura found", 0, row1_y)
	condFrame.cond_aura_missing = MakeCheck("DoiteCond_Aura_Missing", "Aura missing", 85, row1_y)
	condFrame.cond_aura_tip = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	condFrame.cond_aura_tip:SetPoint("LEFT", condFrame.cond_aura_missing.text, "RIGHT", 2, 0)
	condFrame.cond_aura_tip:SetText("(to show icon, aura must be applied once)")
	condFrame.cond_aura_tip:SetWidth(120)
	condFrame.cond_aura_tip:Hide()
	SetSeparator("aura", 1, "AURA PRESENCE", true, true)

    condFrame.cond_aura_incombat   = MakeCheck("DoiteCond_Aura_InCombat", "In combat", 0, row2_y)
    condFrame.cond_aura_outcombat  = MakeCheck("DoiteCond_Aura_OutCombat", "Out of combat", 80, row2_y)
	SetSeparator("aura", 2, "COMBAT STATE", true, true)

	condFrame.cond_aura_target_help = MakeCheck("DoiteCond_Aura_TargetHelp", "Target (help)", 0, row3_y)
	condFrame.cond_aura_target_harm = MakeCheck("DoiteCond_Aura_TargetHarm", "Target (harm)", 94, row3_y)
	condFrame.cond_aura_onself      = MakeCheck("DoiteCond_Aura_OnSelf", "On player (self)", 192, row3_y)
	SetSeparator("aura", 3, "TARGET CONDITIONS", true, true)

    condFrame.cond_aura_glow = MakeCheck("DoiteCond_Aura_Glow", "Glow", 0, row4_y)
    condFrame.cond_aura_greyscale = MakeCheck("DoiteCond_Aura_Greyscale", "Grey", 70, row4_y)	
	SetSeparator("aura", 4, "VISUAL EFFECTS", true, true)

    condFrame.cond_aura_power = MakeCheck("DoiteCond_Aura_PowerCB", "Power", 0, row5_y)
    condFrame.cond_aura_power_comp = MakeComparatorDD("DoiteCond_Aura_PowerComp", 65, row5_y+3, 50)
    condFrame.cond_aura_power_val  = MakeSmallEdit("DoiteCond_Aura_PowerVal", 160, row5_y-2, 40)
    condFrame.cond_aura_power_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_power_val_enter:SetPoint("LEFT", condFrame.cond_aura_power_val, "RIGHT", 4, 0)
    condFrame.cond_aura_power_val_enter:SetText("(%)")
    condFrame.cond_aura_power_comp:Hide()
    condFrame.cond_aura_power_val:Hide()
    condFrame.cond_aura_power_val_enter:Hide()
	SetSeparator("aura", 5, "RESOURCE", true, true)
	
    condFrame.cond_aura_hp_my   = MakeCheck("DoiteCond_Aura_HP_My", "My HP", 0, row6_y)
    condFrame.cond_aura_hp_tgt  = MakeCheck("DoiteCond_Aura_HP_Tgt", "Target HP", 65, row6_y)
    condFrame.cond_aura_hp_comp = MakeComparatorDD("DoiteCond_Aura_HP_Comp", 130, row6_y+3, 50)
    condFrame.cond_aura_hp_val  = MakeSmallEdit("DoiteCond_Aura_HP_Val", 225, row6_y-2, 40)
    condFrame.cond_aura_hp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_hp_val_enter:SetPoint("LEFT", condFrame.cond_aura_hp_val, "RIGHT", 4, 0)
    condFrame.cond_aura_hp_val_enter:SetText("(%)")
    condFrame.cond_aura_hp_comp:Hide()
    condFrame.cond_aura_hp_val:Hide()
    condFrame.cond_aura_hp_val_enter:Hide()	
	SetSeparator("aura", 6, "HEALTH CONDITION", true, true)

    -- Row 7: Aura owner
    condFrame.cond_aura_mine = MakeCheck("DoiteCond_Aura_MyAura", "My Aura", 0, row7_y)
    condFrame.cond_aura_owner_tip = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_owner_tip:SetPoint("LEFT", condFrame.cond_aura_mine.text, "RIGHT", 4, 0)
    condFrame.cond_aura_owner_tip:SetText("(Req. Cursive addon)")
    condFrame.cond_aura_owner_tip:SetTextColor(0.6, 0.6, 0.6)
    condFrame.cond_aura_owner_tip:Hide()
    SetSeparator("aura", 7, "AURA OWNER", true, true)
	
	-- Row 8–9: Time remaining & stacks
	condFrame.cond_aura_remaining_cb   = MakeCheck("DoiteCond_Aura_RemCB", "Remaining", 0, row8_y)
    condFrame.cond_aura_remaining_comp = MakeComparatorDD("DoiteCond_Aura_RemComp", 65, row8_y+3, 50)
    condFrame.cond_aura_remaining_val  = MakeSmallEdit("DoiteCond_Aura_RemVal", 160, row8_y-2, 40)
    condFrame.cond_aura_remaining_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_remaining_val_enter:SetPoint("LEFT", condFrame.cond_aura_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_aura_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_aura_remaining_val_enter:Hide()

	condFrame.cond_aura_stacks_cb   = MakeCheck("DoiteCond_Aura_StacksCB", "Stacks", 0, srow9_y)
    condFrame.cond_aura_stacks_comp = MakeComparatorDD("DoiteCond_Aura_StacksComp", 65, srow9_y+3, 50)
    condFrame.cond_aura_stacks_val  = MakeSmallEdit("DoiteCond_Aura_StacksVal", 160, srow9_y-2, 40)
    condFrame.cond_aura_stacks_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_stacks_val_enter:SetPoint("LEFT", condFrame.cond_aura_stacks_val, "RIGHT", 4, 0)
    condFrame.cond_aura_stacks_val_enter:SetText("(#)")
    condFrame.cond_aura_stacks_val_enter:Hide()

    condFrame.cond_aura_text_time  = MakeCheck("DoiteCond_Aura_TextTime",  "Text: Time remaining",  0,   row9_y-10)
    condFrame.cond_aura_text_stack = MakeCheck("DoiteCond_Aura_TextStack", "Text: Stack counter", 150,   row9_y-10)
	SetSeparator("aura", 8, "TIME REMAINING & STACKS", true, true)
	
    -- Row 10: Class-specific (combo points)
    -- Use an adjusted Y so this block sits tighter with the separator,
    -- mirroring your 8–9 "compressed" aura layout.
    local auraClassRowY = row10_y - 10

    condFrame.cond_aura_cp_cb   = MakeCheck("DoiteCond_Aura_CP_CB", "Combo points", 0, auraClassRowY)
    condFrame.cond_aura_cp_comp = MakeComparatorDD("DoiteCond_Aura_CP_Comp", 85, auraClassRowY+3, 50)
    condFrame.cond_aura_cp_val  = MakeSmallEdit("DoiteCond_Aura_CP_Val", 180, auraClassRowY-2, 40)
    condFrame.cond_aura_cp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_cp_val_enter:SetPoint("LEFT", condFrame.cond_aura_cp_val, "RIGHT", 4, 0)
    condFrame.cond_aura_cp_val_enter:SetText("(#)")
    condFrame.cond_aura_cp_val_enter:Hide()

    -- separator for row 10, shifted down by -10 as well
    local sepAuraClass = SetSeparator("aura", 10, "CLASS-SPECIFIC", true, true)
    if sepAuraClass and srows then
        local newY = (srows[10] or 0) - 10  -- original slot-10 Y minus 10
        sepAuraClass:ClearAllPoints()
        sepAuraClass:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, newY)
        sepAuraClass:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, newY)
    end

    -- Aura: class-specific note for classes without combo points
    condFrame.cond_aura_class_note = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_class_note:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 0, auraClassRowY)
    condFrame.cond_aura_class_note:SetTextColor(1, 0.82, 0)
    condFrame.cond_aura_class_note:SetText("No class-specific option added for your class.")
    condFrame.cond_aura_class_note:Hide()
	
	-- Aura (Buff/Debuff): dynamic Aura Conditions section
    local auraAuraBaseY = row11_y
    SetSeparator("aura", 11, "ABILITY, BUFF & DEBUFF CONDITIONS", true, true)
    condFrame.auraAuraAnchor = CreateFrame("Frame", nil, _Parent())
    condFrame.auraAuraAnchor:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, auraAuraBaseY)
    condFrame.auraAuraAnchor:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, auraAuraBaseY)
    condFrame.auraAuraAnchor:SetHeight(20)

    --------------------------------------------------
    -- Item rows
    --------------------------------------------------
    -- Row 1: WHEREABOUTS / INVENTORY SLOT (special items)
    condFrame.cond_item_where_equipped = MakeCheck("DoiteCond_Item_WhereEquipped", "Equipped", 0, row1_y)
    condFrame.cond_item_where_bag      = MakeCheck("DoiteCond_Item_WhereBag",      "In backpack", 90, row1_y)
    condFrame.cond_item_where_missing  = MakeCheck("DoiteCond_Item_WhereMissing",  "Missing", 190, row1_y)

    -- Special inventory-slot radio groups for synthetic items:
    condFrame.cond_item_inv_trinket1      = MakeCheck("DoiteCond_Item_Inv_Trinket1",     "Trinket 1",          0,   row1_y)
    condFrame.cond_item_inv_trinket2      = MakeCheck("DoiteCond_Item_Inv_Trinket2",     "Trinket 2",          73,  row1_y)
    condFrame.cond_item_inv_trinket_first = MakeCheck("DoiteCond_Item_Inv_TrinketFirst", "First ready",        148, row1_y)
    condFrame.cond_item_inv_trinket_both  = MakeCheck("DoiteCond_Item_Inv_TrinketBoth",  "Both",               230, row1_y)

    condFrame.cond_item_inv_wep_mainhand  = MakeCheck("DoiteCond_Item_Inv_WepMain",      "Main-hand",          0,   row1_y)
    condFrame.cond_item_inv_wep_offhand   = MakeCheck("DoiteCond_Item_Inv_WepOff",       "Off-hand",           87,  row1_y)
    condFrame.cond_item_inv_wep_ranged    = MakeCheck("DoiteCond_Item_Inv_WepRanged",    "Ranged/Idol/Relic", 165,  row1_y)

    -- Default title; changed dynamically in UpdateConditionsUI for special items
    SetSeparator("item", 1, "WHEREABOUTS", true, true)

    -- Row 2: USABILITY & COOLDOWN (no "Usable")
    condFrame.cond_item_notcd = MakeCheck("DoiteCond_Item_NotCD", "Not on cooldown", 0, row2_y)
    condFrame.cond_item_oncd  = MakeCheck("DoiteCond_Item_OnCD",  "On cooldown",     150, row2_y)
    SetSeparator("item", 2, "USABILITY & COOLDOWN", true, true)

    -- Row 3: COMBAT STATE
    condFrame.cond_item_incombat  = MakeCheck("DoiteCond_Item_InCombat",  "In combat",      0, row3_y)
    condFrame.cond_item_outcombat = MakeCheck("DoiteCond_Item_OutCombat", "Out of combat", 80, row3_y)
    SetSeparator("item", 3, "COMBAT STATE", true, true)

    -- Row 4: TARGET CONDITIONS
    condFrame.cond_item_target_help = MakeCheck("DoiteCond_Item_TargetHelp", "Target (help)", 0, row4_y)
    condFrame.cond_item_target_harm = MakeCheck("DoiteCond_Item_TargetHarm", "Target (harm)", 95, row4_y)
    condFrame.cond_item_target_self = MakeCheck("DoiteCond_Item_TargetSelf", "Target (self)", 200, row4_y)
    SetSeparator("item", 4, "TARGET CONDITIONS", true, true)

    -- Row 5: VISUAL EFFECTS
    condFrame.cond_item_glow       = MakeCheck("DoiteCond_Item_Glow",      "Glow", 0,  row5_y)
    condFrame.cond_item_greyscale  = MakeCheck("DoiteCond_Item_Greyscale", "Grey", 70, row5_y)
    condFrame.cond_item_text_time  = MakeCheck("DoiteCond_Item_TextTime",  "Text: Remaining time", 140, row5_y)
    SetSeparator("item", 5, "VISUAL EFFECTS", true, true)

    -- Row 6: RESOURCE (Power)
    condFrame.cond_item_power      = MakeCheck("DoiteCond_Item_PowerCB", "Power", 0, row6_y)
    condFrame.cond_item_power_comp = MakeComparatorDD("DoiteCond_Item_PowerComp", 65, row6_y+3, 50)
    condFrame.cond_item_power_val  = MakeSmallEdit("DoiteCond_Item_PowerVal", 160, row6_y-2, 40)
    condFrame.cond_item_power_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_power_val_enter:SetPoint("LEFT", condFrame.cond_item_power_val, "RIGHT", 4, 0)
    condFrame.cond_item_power_val_enter:SetText("(%)")
    condFrame.cond_item_power_comp:Hide()
    condFrame.cond_item_power_val:Hide()
    condFrame.cond_item_power_val_enter:Hide()
    SetSeparator("item", 6, "RESOURCE", true, true)

    -- Row 7: HEALTH CONDITION
    condFrame.cond_item_hp_my   = MakeCheck("DoiteCond_Item_HP_My",  "My HP",     0, row7_y)
    condFrame.cond_item_hp_tgt  = MakeCheck("DoiteCond_Item_HP_Tgt", "Target HP", 65, row7_y)
    condFrame.cond_item_hp_comp = MakeComparatorDD("DoiteCond_Item_HP_Comp", 130, row7_y+3, 50)
    condFrame.cond_item_hp_val  = MakeSmallEdit("DoiteCond_Item_HP_Val", 225, row7_y-2, 40)
    condFrame.cond_item_hp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_hp_val_enter:SetPoint("LEFT", condFrame.cond_item_hp_val, "RIGHT", 4, 0)
    condFrame.cond_item_hp_val_enter:SetText("(%)")
    condFrame.cond_item_hp_comp:Hide()
    condFrame.cond_item_hp_val:Hide()
    condFrame.cond_item_hp_val_enter:Hide()
    SetSeparator("item", 7, "HEALTH CONDITION", true, true)

    -- Row 8: REMAINING TIME (no slider)
    condFrame.cond_item_remaining_cb   = MakeCheck("DoiteCond_Item_RemCB", "Remaining", 0, row8_y)
    condFrame.cond_item_remaining_comp = MakeComparatorDD("DoiteCond_Item_RemComp", 80, row8_y+3, 50)
    condFrame.cond_item_remaining_val  = MakeSmallEdit("DoiteCond_Item_RemVal", 175, row8_y-2, 40)
    condFrame.cond_item_remaining_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_remaining_val_enter:SetPoint("LEFT", condFrame.cond_item_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_item_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_item_remaining_comp:Hide()
    condFrame.cond_item_remaining_val:Hide()
    condFrame.cond_item_remaining_val_enter:Hide()
    SetSeparator("item", 8, "REMAINING TIME", true, true)

    -- Row 9: CLASS-SPECIFIC (Combo points)
    condFrame.cond_item_cp_cb   = MakeCheck("DoiteCond_Item_CP_CB", "Combo points", 0, row9_y)
    condFrame.cond_item_cp_comp = MakeComparatorDD("DoiteCond_Item_CP_Comp", 85, row9_y+3, 50)
    condFrame.cond_item_cp_val  = MakeSmallEdit("DoiteCond_Item_CP_Val", 180, row9_y-2, 40)
    condFrame.cond_item_cp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_cp_val_enter:SetPoint("LEFT", condFrame.cond_item_cp_val, "RIGHT", 4, 0)
    condFrame.cond_item_cp_val_enter:SetText("(#)")
    condFrame.cond_item_cp_val_enter:Hide()
    SetSeparator("item", 9, "CLASS-SPECIFIC", true, true)

    -- Item: class-specific note for classes without combo points
    condFrame.cond_item_class_note = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_class_note:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 0, row9_y)
    condFrame.cond_item_class_note:SetTextColor(1, 0.82, 0)
    condFrame.cond_item_class_note:SetText("No class-specific option added for your class.")
    condFrame.cond_item_class_note:Hide()
	
	-- Item: dynamic Aura Conditions section
    local itemAuraBaseY = row10_y
    SetSeparator("item", 10, "ABILITY, BUFF & DEBUFF CONDITIONS", true, true)
    condFrame.itemAuraAnchor = CreateFrame("Frame", nil, _Parent())
    condFrame.itemAuraAnchor:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, itemAuraBaseY)
    condFrame.itemAuraAnchor:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, itemAuraBaseY)
    condFrame.itemAuraAnchor:SetHeight(20)

    ----------------------------------------------------------------
    -- 'Form' dropdowns
    ----------------------------------------------------------------
    condFrame.cond_ability_formDD = CreateFrame("Frame", "DoiteCond_Ability_FormDD", _Parent(), "UIDropDownMenuTemplate")
	condFrame.cond_ability_formDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 165, row2_y+3)
	if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_ability_formDD) end
	condFrame.cond_ability_formDD:Hide()
	ClearDropdown(condFrame.cond_ability_formDD)

	condFrame.cond_aura_formDD = CreateFrame("Frame", "DoiteCond_Aura_FormDD", _Parent(), "UIDropDownMenuTemplate")
	condFrame.cond_aura_formDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 165, row2_y+3)
	if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_aura_formDD) end
	condFrame.cond_aura_formDD:Hide()
	ClearDropdown(condFrame.cond_aura_formDD)

    condFrame.cond_item_formDD = CreateFrame("Frame", "DoiteCond_Item_FormDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_item_formDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 165, row3_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_item_formDD) end
    condFrame.cond_item_formDD:Hide()
    ClearDropdown(condFrame.cond_item_formDD)

    ----------------------------------------------------------------
    -- Wiring: enforce exclusivity immediately + save to DB
    ----------------------------------------------------------------

    -- Ability row1 scripts (Usable / NotCD / OnCD)
    if GetNampowerVersion then
		condFrame.cond_ability_usable:SetScript("OnClick", function()
			if this:GetChecked() then
				condFrame.cond_ability_notcd:SetChecked(false)
				condFrame.cond_ability_oncd:SetChecked(false)
				SetExclusiveAbilityMode("usable")
			else
				SetExclusiveAbilityMode(nil)
			end
		end)
	end
	
    condFrame.cond_ability_notcd:SetScript("OnClick", function()
        if this:GetChecked() then
			if GetNampowerVersion then
				condFrame.cond_ability_usable:SetChecked(false)
			end
            condFrame.cond_ability_oncd:SetChecked(false)
            SetExclusiveAbilityMode("notcd")
        else
            SetExclusiveAbilityMode(nil)
        end
    end)
	
    condFrame.cond_ability_oncd:SetScript("OnClick", function()
        if this:GetChecked() then
			if GetNampowerVersion then
				condFrame.cond_ability_usable:SetChecked(false)
			end
            condFrame.cond_ability_notcd:SetChecked(false)
            SetExclusiveAbilityMode("oncd")
        else
            SetExclusiveAbilityMode(nil)
        end
    end)

    -- Item Usability & Cooldown (NotCD / OnCD only, exclusive)
    condFrame.cond_item_notcd:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then
            condFrame.cond_item_oncd:SetChecked(false)
            SetExclusiveItemMode("notcd")
        else
            -- enforce at least one checked
            if not condFrame.cond_item_oncd:GetChecked() then
                this:SetChecked(true)
            end
        end
    end)

    condFrame.cond_item_oncd:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then
            condFrame.cond_item_notcd:SetChecked(false)
            SetExclusiveItemMode("oncd")
        else
            -- enforce at least one checked
            if not condFrame.cond_item_notcd:GetChecked() then
                this:SetChecked(true)
            end
        end
    end)

    -- Ability combat row 2 - toggles are now independent (not exclusive)
	condFrame.cond_ability_incombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_ability_outcombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("ability", "in", this:GetChecked())
	end)

	condFrame.cond_ability_outcombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_ability_incombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("ability", "out", this:GetChecked())
	end)

    -- Item combat row (independent, at least one)
    condFrame.cond_item_incombat:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if not this:GetChecked() and not condFrame.cond_item_outcombat:GetChecked() then
            this:SetChecked(true)
            return
        end
        SetCombatFlag("item", "in", this:GetChecked())
    end)

    condFrame.cond_item_outcombat:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if not this:GetChecked() and not condFrame.cond_item_incombat:GetChecked() then
            this:SetChecked(true)
            return
        end
        SetCombatFlag("item", "out", this:GetChecked())
    end)

	-- Ability target row (multi-select, enforce at least one)
	local function SaveAbilityTargetsFromUI()
		if not currentKey then return end
		local d = EnsureDBEntry(currentKey)
		d.conditions = d.conditions or {}
		d.conditions.ability = d.conditions.ability or {}
		d.conditions.ability.targetHelp = condFrame.cond_ability_target_help:GetChecked() and true or false
		d.conditions.ability.targetHarm = condFrame.cond_ability_target_harm:GetChecked() and true or false
		d.conditions.ability.targetSelf = condFrame.cond_ability_target_self:GetChecked() and true or false
	end

	condFrame.cond_ability_target_help:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
	end)

	condFrame.cond_ability_target_harm:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
	end)

	condFrame.cond_ability_target_self:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
	end)

    -- Item target row (same logic as abilities)
    local function SaveItemTargetsFromUI()
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.item = d.conditions.item or {}
        d.conditions.item.targetHelp = condFrame.cond_item_target_help:GetChecked() and true or false
        d.conditions.item.targetHarm = condFrame.cond_item_target_harm:GetChecked() and true or false
        d.conditions.item.targetSelf = condFrame.cond_item_target_self:GetChecked() and true or false
    end

    condFrame.cond_item_target_help:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

    condFrame.cond_item_target_harm:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

    condFrame.cond_item_target_self:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

    -- Item WHEREABOUTS row (Equipped / In backpack / Missing)
    local function SaveItemWhereaboutsFromUI()
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.item = d.conditions.item or {}
        local ic = d.conditions.item
        ic.whereEquipped = condFrame.cond_item_where_equipped:GetChecked() and true or false
        ic.whereBag      = condFrame.cond_item_where_bag:GetChecked()      and true or false
        ic.whereMissing  = condFrame.cond_item_where_missing:GetChecked()  and true or false
    end

    local function EnforceItemWhereabouts(clicked)
        local eq = condFrame.cond_item_where_equipped:GetChecked()
        local bg = condFrame.cond_item_where_bag:GetChecked()
        local ms = condFrame.cond_item_where_missing:GetChecked()

        if clicked == condFrame.cond_item_where_missing and ms then
            -- Missing exclusive
            condFrame.cond_item_where_equipped:SetChecked(false)
            condFrame.cond_item_where_bag:SetChecked(false)
        elseif (clicked == condFrame.cond_item_where_equipped or clicked == condFrame.cond_item_where_bag) and clicked:GetChecked() then
            -- Any of the positive whereabouts -> clear Missing
            condFrame.cond_item_where_missing:SetChecked(false)
        end

        eq = condFrame.cond_item_where_equipped:GetChecked()
        bg = condFrame.cond_item_where_bag:GetChecked()
        ms = condFrame.cond_item_where_missing:GetChecked()

        if not eq and not bg and not ms then
            if clicked then clicked:SetChecked(true) end
        end
    end

    condFrame.cond_item_where_equipped:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceItemWhereabouts(this)
        SaveItemWhereaboutsFromUI()
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
    end)

    condFrame.cond_item_where_bag:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceItemWhereabouts(this)
        SaveItemWhereaboutsFromUI()
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
    end)

    condFrame.cond_item_where_missing:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceItemWhereabouts(this)
        SaveItemWhereaboutsFromUI()
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
    end)

    -- Inventory-slot radio rows for synthetic items ("---EQUIPPED TRINKET SLOTS---" / "---EQUIPPED WEAPON SLOTS---")
    local function SaveItemInventoryTrinketFromUI()
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.item = d.conditions.item or {}
        local ic = d.conditions.item

        if condFrame.cond_item_inv_trinket1:GetChecked() then
            ic.inventorySlot = "TRINKET1"
        elseif condFrame.cond_item_inv_trinket2:GetChecked() then
            ic.inventorySlot = "TRINKET2"
        elseif condFrame.cond_item_inv_trinket_both:GetChecked() then
            ic.inventorySlot = "TRINKET_BOTH"
        else
            -- default / fallback
            ic.inventorySlot = "TRINKET_FIRST"
        end
    end

    local function SaveItemInventoryWeaponFromUI()
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.item = d.conditions.item or {}
        local ic = d.conditions.item

        if condFrame.cond_item_inv_wep_mainhand:GetChecked() then
            ic.inventorySlot = "MAINHAND"
        elseif condFrame.cond_item_inv_wep_offhand:GetChecked() then
            ic.inventorySlot = "OFFHAND"
        else
            -- default / fallback
            ic.inventorySlot = "RANGED"
        end
    end

    local function EnforceInventoryRadio(clicked, group)
        if not clicked then return end

        if group == "TRINKET" then
            local c1 = condFrame.cond_item_inv_trinket1
            local c2 = condFrame.cond_item_inv_trinket2
            local c3 = condFrame.cond_item_inv_trinket_first
            local c4 = condFrame.cond_item_inv_trinket_both

            if clicked:GetChecked() then
                if clicked ~= c1 then c1:SetChecked(false) end
                if clicked ~= c2 then c2:SetChecked(false) end
                if clicked ~= c3 then c3:SetChecked(false) end
                if clicked ~= c4 then c4:SetChecked(false) end
            end

            -- ensure at least one checked
            if not c1:GetChecked() and not c2:GetChecked() and not c3:GetChecked() and not c4:GetChecked() then
                clicked:SetChecked(true)
            end

        elseif group == "WEAPON" then
            local c1 = condFrame.cond_item_inv_wep_mainhand
            local c2 = condFrame.cond_item_inv_wep_offhand
            local c3 = condFrame.cond_item_inv_wep_ranged

            if clicked:GetChecked() then
                if clicked ~= c1 then c1:SetChecked(false) end
                if clicked ~= c2 then c2:SetChecked(false) end
                if clicked ~= c3 then c3:SetChecked(false) end
            end

            -- ensure at least one checked
            if not c1:GetChecked() and not c2:GetChecked() and not c3:GetChecked() then
                clicked:SetChecked(true)
            end
        end
    end

    -- Trinket inventory-slot clicks
    condFrame.cond_item_inv_trinket1:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceInventoryRadio(this, "TRINKET")
        SaveItemInventoryTrinketFromUI()
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_item_inv_trinket2:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceInventoryRadio(this, "TRINKET")
        SaveItemInventoryTrinketFromUI()
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_item_inv_trinket_first:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceInventoryRadio(this, "TRINKET")
        SaveItemInventoryTrinketFromUI()
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_item_inv_trinket_both:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceInventoryRadio(this, "TRINKET")
        SaveItemInventoryTrinketFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

    -- Weapon inventory-slot clicks
    condFrame.cond_item_inv_wep_mainhand:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceInventoryRadio(this, "WEAPON")
        SaveItemInventoryWeaponFromUI()
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_item_inv_wep_offhand:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceInventoryRadio(this, "WEAPON")
        SaveItemInventoryWeaponFromUI()
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_item_inv_wep_ranged:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceInventoryRadio(this, "WEAPON")
        SaveItemInventoryWeaponFromUI()
        SafeRefresh(); SafeEvaluate()
    end)


    -- Aura exclusivity (found / missing)
    condFrame.cond_aura_found:SetScript("OnClick", function()
        if this:GetChecked() then
            condFrame.cond_aura_missing:SetChecked(false)
            SetExclusiveAuraFoundMode("found")
        else
            SetExclusiveAuraFoundMode(nil)
        end
    end)
    condFrame.cond_aura_missing:SetScript("OnClick", function()
        if this:GetChecked() then
            condFrame.cond_aura_found:SetChecked(false)
            SetExclusiveAuraFoundMode("missing")
        else
            SetExclusiveAuraFoundMode(nil)
        end
    end)

    -- Aura combat row 2 - toggles (independent)
	condFrame.cond_aura_incombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_aura_outcombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("aura", "in", this:GetChecked())
	end)

	condFrame.cond_aura_outcombat:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end

		if not this:GetChecked() and not condFrame.cond_aura_incombat:GetChecked() then
			this:SetChecked(true)
			return
		end

		SetCombatFlag("aura", "out", this:GetChecked())
	end)

	-- Aura target row (Self is exclusive; Help/Harm can combine; at least one must be checked)
	local function SaveAuraTargets()
		if not currentKey then return end
		local d = EnsureDBEntry(currentKey)
		d.conditions = d.conditions or {}
		d.conditions.aura = d.conditions.aura or {}
		d.conditions.aura.targetHelp = condFrame.cond_aura_target_help:GetChecked() and true or false
		d.conditions.aura.targetHarm = condFrame.cond_aura_target_harm:GetChecked() and true or false
		d.conditions.aura.targetSelf = condFrame.cond_aura_onself:GetChecked()      and true or false
	end

	local function EnforceAuraExclusivity(changedBox)
		local h  = condFrame.cond_aura_target_help:GetChecked()
		local hm = condFrame.cond_aura_target_harm:GetChecked()
		local s  = condFrame.cond_aura_onself:GetChecked()

		-- Self exclusive: if Self checked, uncheck Help/Harm
		if changedBox == condFrame.cond_aura_onself and s then
			condFrame.cond_aura_target_help:SetChecked(false)
			condFrame.cond_aura_target_harm:SetChecked(false)
		end

		-- If Help/Harm gets checked while Self is on, turn Self off
		if (changedBox == condFrame.cond_aura_target_help and condFrame.cond_aura_target_help:GetChecked())
		   or (changedBox == condFrame.cond_aura_target_harm and condFrame.cond_aura_target_harm:GetChecked()) then
			if condFrame.cond_aura_onself:GetChecked() then
				condFrame.cond_aura_onself:SetChecked(false)
			end
		end

		-- At least one must remain checked
		h  = condFrame.cond_aura_target_help:GetChecked()
		hm = condFrame.cond_aura_target_harm:GetChecked()
		s  = condFrame.cond_aura_onself:GetChecked()
		if (not h) and (not hm) and (not s) then
			-- Re-check the one the user just toggled off
			if changedBox then changedBox:SetChecked(true) end
		end
	end

	condFrame.cond_aura_target_help:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		EnforceAuraExclusivity(this)
		SaveAuraTargets()
		SafeRefresh(); SafeEvaluate()
		UpdateCondFrameForKey(currentKey)
	end)

	condFrame.cond_aura_target_harm:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		EnforceAuraExclusivity(this)
		SaveAuraTargets()
		SafeRefresh(); SafeEvaluate()
		UpdateCondFrameForKey(currentKey)
	end)

	condFrame.cond_aura_onself:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		EnforceAuraExclusivity(this)
		SaveAuraTargets()
		SafeRefresh(); SafeEvaluate()
		UpdateCondFrameForKey(currentKey)
	end)

    -- Aura owner flag ("My Aura" only).
    local function SaveAuraOwnerFlags()
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}

        local mine = condFrame.cond_aura_mine:GetChecked() and true or false
        d.conditions.aura.onlyMine = mine or nil
    end

    condFrame.cond_aura_mine:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        SaveAuraOwnerFlags()
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
    end)

    -- Aura remaining toggle
    condFrame.cond_aura_remaining_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.remainingEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Aura stacks toggle
    condFrame.cond_aura_stacks_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.stacksEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Aura glow / greyscale
    condFrame.cond_aura_glow:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.glow = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)
	
    condFrame.cond_aura_greyscale:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.greyscale = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- === Combo points enable toggles ===
    condFrame.cond_ability_cp_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.cpEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_aura_cp_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.cpEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_item_cp_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.cpEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)

    -- === HP selectors (mutually exclusive, same X position widgets) ===
    local function _AbilityHP_Update(which)
        local d = EnsureDBEntry(currentKey); d.conditions.ability = d.conditions.ability or {}
        if which == "my" then
            condFrame.cond_ability_hp_tgt:SetChecked(false)
            d.conditions.ability.hpMode = "my"
        elseif which == "tgt" then
            condFrame.cond_ability_hp_my:SetChecked(false)
            d.conditions.ability.hpMode = "target"
        else
            d.conditions.ability.hpMode = nil
        end
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end
    condFrame.cond_ability_hp_my:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then _AbilityHP_Update("my") else _AbilityHP_Update(nil) end
    end)
    condFrame.cond_ability_hp_tgt:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then _AbilityHP_Update("tgt") else _AbilityHP_Update(nil) end
    end)

    local function _AuraHP_Update(which)
        local d = EnsureDBEntry(currentKey); d.conditions.aura = d.conditions.aura or {}
        if which == "my" then
            condFrame.cond_aura_hp_tgt:SetChecked(false)
            d.conditions.aura.hpMode = "my"
        elseif which == "tgt" then
            condFrame.cond_aura_hp_my:SetChecked(false)
            d.conditions.aura.hpMode = "target"
        else
            d.conditions.aura.hpMode = nil
        end
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end
    condFrame.cond_aura_hp_my:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then _AuraHP_Update("my") else _AuraHP_Update(nil) end
    end)
    condFrame.cond_aura_hp_tgt:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then _AuraHP_Update("tgt") else _AuraHP_Update(nil) end
    end)

    local function _ItemHP_Update(which)
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        if which == "my" then
            condFrame.cond_item_hp_tgt:SetChecked(false)
            d.conditions.item.hpMode = "my"
        elseif which == "tgt" then
            condFrame.cond_item_hp_my:SetChecked(false)
            d.conditions.item.hpMode = "target"
        else
            d.conditions.item.hpMode = nil
        end
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end
    condFrame.cond_item_hp_my:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then _ItemHP_Update("my") else _ItemHP_Update(nil) end
    end)
    condFrame.cond_item_hp_tgt:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then _ItemHP_Update("tgt") else _ItemHP_Update(nil) end
    end)

    -- === Ability slider extras ===
    condFrame.cond_ability_slider_glow:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.sliderGlow = this:GetChecked() and true or false
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_ability_slider_grey:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.sliderGrey = this:GetChecked() and true or false
        SafeRefresh(); SafeEvaluate()
    end)

    -- === Text flags (ability/aura) ===
    condFrame.cond_ability_text_time:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.textTimeRemaining = this:GetChecked() and true or false
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_aura_text_time:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.textTimeRemaining = this:GetChecked() and true or false
        SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_aura_text_stack:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.textStackCounter = this:GetChecked() and true or false
        SafeRefresh(); SafeEvaluate()
    end)

    -- === Aura Power toggle ===
    condFrame.cond_aura_power:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.powerEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)

    -- Item Power toggle
    condFrame.cond_item_power:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.powerEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)

    -- Item Remaining toggle
    condFrame.cond_item_remaining_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.remainingEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)

    -- Item glow/greyscale
    condFrame.cond_item_glow:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.glow = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)
    condFrame.cond_item_greyscale:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.greyscale = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)

    -- Item text: remaining time
    condFrame.cond_item_text_time:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.textTimeRemaining = this:GetChecked() and true or false
        SafeRefresh(); SafeEvaluate()
    end)

    -- dropdown initializers
    local function InitComparatorDD(ddframe, commitFunc)
        UIDropDownMenu_Initialize(ddframe, function(frame, level, menuList)
            local info
            local choices = { ">=", "<=", "==" }
            for _, c in ipairs(choices) do
                local picked = c
                info = {}
                info.text = picked
                info.value = picked
                info.func = function(button)
                    local val = (button and button.value) or picked
                    if commitFunc then pcall(commitFunc, val) end
                    UIDropDownMenu_SetSelectedValue(ddframe, val)
                    UIDropDownMenu_SetText(val, ddframe)
                    CloseDropDownMenus()
                end
                info.checked = (UIDropDownMenu_GetSelectedValue(ddframe) == picked)
                UIDropDownMenu_AddButton(info)
            end
        end)
    end

    -- slider direction dd
    UIDropDownMenu_Initialize(condFrame.cond_ability_slider_dir, function(frame, level, menuList)
        local info
        local choices = { "left", "right", "center", "up", "down" }
        for _, c in ipairs(choices) do
            local picked = c
            info = {}
            info.text = picked
            info.value = picked
            info.func = function(button)
                local val = (button and button.value) or picked
                if not currentKey then return end
                local d = EnsureDBEntry(currentKey)
                d.conditions = d.conditions or {}
                d.conditions.ability = d.conditions.ability or {}
                d.conditions.ability.sliderDir = val
                UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_slider_dir, val)
                UIDropDownMenu_SetText(val, condFrame.cond_ability_slider_dir)
				_GoldifyDD(condFrame.cond_ability_slider_dir)
                CloseDropDownMenus()
                SafeRefresh()
				SafeEvaluate()
            end
            info.checked = (UIDropDownMenu_GetSelectedValue(condFrame.cond_ability_slider_dir) == picked)
            UIDropDownMenu_AddButton(info)
        end
    end)

    -- attach comparator inits with commit functions that write to DB
    InitComparatorDD(condFrame.cond_ability_power_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.powerComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)

    InitComparatorDD(condFrame.cond_ability_remaining_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.remainingComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)

    InitComparatorDD(condFrame.cond_aura_remaining_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.remainingComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)

    InitComparatorDD(condFrame.cond_aura_stacks_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.stacksComp = picked
        SafeRefresh()
		SafeEvaluate()
    end)
	
    InitComparatorDD(condFrame.cond_ability_cp_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.cpComp = picked
        SafeRefresh(); SafeEvaluate()
    end)
    InitComparatorDD(condFrame.cond_aura_cp_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.cpComp = picked
        SafeRefresh(); SafeEvaluate()
    end)
    InitComparatorDD(condFrame.cond_item_cp_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        d.conditions.item.cpComp = picked
        SafeRefresh(); SafeEvaluate()
    end)

    -- HP comparators
    InitComparatorDD(condFrame.cond_ability_hp_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.hpComp = picked
        SafeRefresh(); SafeEvaluate()
    end)
    InitComparatorDD(condFrame.cond_aura_hp_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.hpComp = picked
        SafeRefresh(); SafeEvaluate()
    end)
    InitComparatorDD(condFrame.cond_item_hp_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        d.conditions.item.hpComp = picked
        SafeRefresh(); SafeEvaluate()
    end)

    -- Aura Power comparator
    InitComparatorDD(condFrame.cond_aura_power_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.powerComp = picked
        SafeRefresh(); SafeEvaluate()
    end)

    -- Item Power comparator
    InitComparatorDD(condFrame.cond_item_power_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        d.conditions.item.powerComp = picked
        SafeRefresh(); SafeEvaluate()
    end)

    -- Item Remaining comparator
    InitComparatorDD(condFrame.cond_item_remaining_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        d.conditions.item.remainingComp = picked
        SafeRefresh(); SafeEvaluate()
    end)

    -- editbox commit handlers (enter / focus lost)
	    -- Ability CP value
    condFrame.cond_ability_cp_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions.ability and d.conditions.ability.cpVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.cpVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _guard=false
        condFrame.cond_ability_cp_val:SetScript("OnEditFocusLost", function()
            if _guard then return end; _guard=true
            this:GetScript("OnEnterPressed")()
            _guard=false
        end)
    end

    -- Aura CP value
    condFrame.cond_aura_cp_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions.aura and d.conditions.aura.cpVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.cpVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _guard=false
        condFrame.cond_aura_cp_val:SetScript("OnEditFocusLost", function()
            if _guard then return end; _guard=true
            this:GetScript("OnEnterPressed")()
            _guard=false
        end)
    end

    -- Ability HP value (%)
    condFrame.cond_ability_hp_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions.ability and d.conditions.ability.hpVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        if v > 100 then v = 100 end
        local d = EnsureDBEntry(currentKey)
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.hpVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _guard=false
        condFrame.cond_ability_hp_val:SetScript("OnEditFocusLost", function()
            if _guard then return end; _guard=true
            this:GetScript("OnEnterPressed")()
            _guard=false
        end)
    end

    -- Aura HP value (%)
    condFrame.cond_aura_hp_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions.aura and d.conditions.aura.hpVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        if v > 100 then v = 100 end
        local d = EnsureDBEntry(currentKey)
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.hpVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _guard=false
        condFrame.cond_aura_hp_val:SetScript("OnEditFocusLost", function()
            if _guard then return end; _guard=true
            this:GetScript("OnEnterPressed")()
            _guard=false
        end)
    end

    -- Aura Power value (%)
    condFrame.cond_aura_power_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions.aura and d.conditions.aura.powerVal) or 0))
            return
        end
        local d = EnsureDBEntry(currentKey)
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.powerVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _guard=false
        condFrame.cond_aura_power_val:SetScript("OnEditFocusLost", function()
            if _guard then return end; _guard=true
            this:GetScript("OnEnterPressed")()
            _guard=false
        end)
    end
	
    condFrame.cond_ability_power_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        local minv, maxv = -999999, 999999
        if not v then
            local d = EnsureDBEntry(currentKey)
            d.conditions = d.conditions or {}
            d.conditions.ability = d.conditions.ability or {}
            this:SetText(tostring(d.conditions.ability.powerVal or 0))
            return
        end
        if v < minv then v = minv end
        if v > maxv then v = maxv end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.powerVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_power = false
        condFrame.cond_ability_power_val:SetScript("OnEditFocusLost", function()
            if handling_power then return end
            handling_power = true
            this:GetScript("OnEnterPressed")()
            handling_power = false
        end)
    end

    condFrame.cond_ability_remaining_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions and d.conditions.ability and d.conditions.ability.remainingVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.remainingVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_ability_remaining = false
        condFrame.cond_ability_remaining_val:SetScript("OnEditFocusLost", function()
            if handling_ability_remaining then return end
            handling_ability_remaining = true
            this:GetScript("OnEnterPressed")()
            handling_ability_remaining = false
        end)
    end

    condFrame.cond_aura_remaining_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions and d.conditions.aura and d.conditions.aura.remainingVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.remainingVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_aura_remaining = false
        condFrame.cond_aura_remaining_val:SetScript("OnEditFocusLost", function()
            if handling_aura_remaining then return end
            handling_aura_remaining = true
            this:GetScript("OnEnterPressed")()
            handling_aura_remaining = false
        end)
    end

    condFrame.cond_aura_stacks_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        if not v then
            local d = EnsureDBEntry(currentKey)
            this:SetText(tostring((d.conditions and d.conditions.aura and d.conditions.aura.stacksVal) or 0))
            return
        end
        if v < 0 then v = 0 end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.aura = d.conditions.aura or {}
        d.conditions.aura.stacksVal = v
        SafeRefresh()
		SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local handling_aura_stacks = false
        condFrame.cond_aura_stacks_val:SetScript("OnEditFocusLost", function()
            if handling_aura_stacks then return end
            handling_aura_stacks = true
            this:GetScript("OnEnterPressed")()
            handling_aura_stacks = false
        end)
    end

    -- Item CP value
    condFrame.cond_item_cp_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        if not v then
            this:SetText(tostring(d.conditions.item.cpVal or 0))
            return
        end
        if v < 0 then v = 0 end
        d.conditions.item.cpVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _g = false
        condFrame.cond_item_cp_val:SetScript("OnEditFocusLost", function()
            if _g then return end; _g = true
            this:GetScript("OnEnterPressed")()
            _g = false
        end)
    end

    -- Item HP value (%)
    condFrame.cond_item_hp_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        if not v then
            this:SetText(tostring(d.conditions.item.hpVal or 0))
            return
        end
        if v < 0 then v = 0 end
        if v > 100 then v = 100 end
        d.conditions.item.hpVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _g = false
        condFrame.cond_item_hp_val:SetScript("OnEditFocusLost", function()
            if _g then return end; _g = true
            this:GetScript("OnEnterPressed")()
            _g = false
        end)
    end

    -- Item Power value
    condFrame.cond_item_power_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        if not v then
            this:SetText(tostring(d.conditions.item.powerVal or 0))
            return
        end
        d.conditions.item.powerVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _g = false
        condFrame.cond_item_power_val:SetScript("OnEditFocusLost", function()
            if _g then return end; _g = true
            this:GetScript("OnEnterPressed")()
            _g = false
        end)
    end

    -- Item Remaining value (seconds)
    condFrame.cond_item_remaining_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        if not v then
            this:SetText(tostring(d.conditions.item.remainingVal or 0))
            return
        end
        if v < 0 then v = 0 end
        d.conditions.item.remainingVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _g = false
        condFrame.cond_item_remaining_val:SetScript("OnEditFocusLost", function()
            if _g then return end; _g = true
            this:GetScript("OnEnterPressed")()
            _g = false
        end)
    end

    -- Ability power toggle
    condFrame.cond_ability_power:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.powerEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Ability slider toggle
    condFrame.cond_ability_slider:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.slider = this:GetChecked() and true or false
        if d.conditions.ability.slider and not d.conditions.ability.sliderDir then
            d.conditions.ability.sliderDir = "center"
        end
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Ability remaining toggle
    condFrame.cond_ability_remaining_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.remainingEnabled = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Ability glow/greyscale (separate checkboxes)
    condFrame.cond_ability_glow:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.glow = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)
    condFrame.cond_ability_greyscale:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}
        d.conditions.ability.greyscale = this:GetChecked() and true or false
        UpdateCondFrameForKey(currentKey)
        SafeRefresh()
		SafeEvaluate()
    end)

    -- Form dropdowns are initialized/updated from UpdateConditionsUI
    condFrame.cond_ability_formDD:Hide()
    condFrame.cond_aura_formDD:Hide()
    condFrame.cond_item_formDD:Hide()
    ClearDropdown(condFrame.cond_ability_formDD)
    ClearDropdown(condFrame.cond_aura_formDD)
    ClearDropdown(condFrame.cond_item_formDD)

    -- hide all controls by default
    condFrame.cond_ability_usable:Hide()
    condFrame.cond_ability_notcd:Hide()
    condFrame.cond_ability_oncd:Hide()
    condFrame.cond_ability_incombat:Hide()
    condFrame.cond_ability_outcombat:Hide()
    condFrame.cond_ability_target_help:Hide()
    condFrame.cond_ability_target_harm:Hide()
    condFrame.cond_ability_target_self:Hide()
    condFrame.cond_ability_power:Hide()
    condFrame.cond_ability_power_comp:Hide()
    condFrame.cond_ability_power_val:Hide()
    condFrame.cond_ability_power_val_enter:Hide()
    condFrame.cond_ability_glow:Hide()
    condFrame.cond_ability_slider:Hide()
    condFrame.cond_ability_slider_dir:Hide()
    condFrame.cond_ability_remaining_cb:Hide()
    condFrame.cond_ability_remaining_comp:Hide()
    condFrame.cond_ability_remaining_val:Hide()
    condFrame.cond_ability_remaining_val_enter:Hide()
    condFrame.cond_ability_greyscale:Hide()
    condFrame.cond_ability_cp_cb:Hide()
    condFrame.cond_ability_cp_comp:Hide()
    condFrame.cond_ability_cp_val:Hide()
    condFrame.cond_ability_cp_val_enter:Hide()
    condFrame.cond_ability_hp_my:Hide()
    condFrame.cond_ability_hp_tgt:Hide()
    condFrame.cond_ability_hp_comp:Hide()
    condFrame.cond_ability_hp_val:Hide()
    condFrame.cond_ability_hp_val_enter:Hide()
    condFrame.cond_ability_slider_glow:Hide()
    condFrame.cond_ability_slider_grey:Hide()
    condFrame.cond_ability_text_time:Hide()

    condFrame.cond_aura_cp_cb:Hide()
    condFrame.cond_aura_cp_comp:Hide()
    condFrame.cond_aura_cp_val:Hide()
    condFrame.cond_aura_cp_val_enter:Hide()
    condFrame.cond_aura_hp_my:Hide()
    condFrame.cond_aura_hp_tgt:Hide()
    condFrame.cond_aura_hp_comp:Hide()
    condFrame.cond_aura_hp_val:Hide()
    condFrame.cond_aura_hp_val_enter:Hide()
    condFrame.cond_aura_text_time:Hide()
    condFrame.cond_aura_text_stack:Hide()
    condFrame.cond_aura_power:Hide()
    condFrame.cond_aura_power_comp:Hide()
    condFrame.cond_aura_power_val:Hide()
    condFrame.cond_aura_power_val_enter:Hide()
    condFrame.cond_aura_found:Hide()
    condFrame.cond_aura_missing:Hide()
    condFrame.cond_aura_incombat:Hide()
    condFrame.cond_aura_outcombat:Hide()
	condFrame.cond_aura_target_help:Hide()
	condFrame.cond_aura_target_harm:Hide()
	condFrame.cond_aura_onself:Hide()
    condFrame.cond_aura_glow:Hide()
    condFrame.cond_aura_remaining_cb:Hide()
    condFrame.cond_aura_remaining_comp:Hide()
    condFrame.cond_aura_remaining_val:Hide()
    condFrame.cond_aura_remaining_val_enter:Hide()
    condFrame.cond_aura_stacks_cb:Hide()
    condFrame.cond_aura_stacks_comp:Hide()
    condFrame.cond_aura_stacks_val:Hide()
    condFrame.cond_aura_stacks_val_enter:Hide()
    condFrame.cond_aura_greyscale:Hide()
    condFrame.cond_aura_mine:Hide()
    if condFrame.cond_aura_owner_tip then condFrame.cond_aura_owner_tip:Hide() end

    condFrame.cond_item_where_equipped:Hide()
    condFrame.cond_item_where_bag:Hide()
    condFrame.cond_item_where_missing:Hide()
    condFrame.cond_item_notcd:Hide()
    condFrame.cond_item_oncd:Hide()
    condFrame.cond_item_incombat:Hide()
    condFrame.cond_item_outcombat:Hide()
    condFrame.cond_item_target_help:Hide()
    condFrame.cond_item_target_harm:Hide()
    condFrame.cond_item_target_self:Hide()
    condFrame.cond_item_glow:Hide()
    condFrame.cond_item_greyscale:Hide()
    condFrame.cond_item_text_time:Hide()
    condFrame.cond_item_power:Hide()
    condFrame.cond_item_power_comp:Hide()
    condFrame.cond_item_power_val:Hide()
    condFrame.cond_item_power_val_enter:Hide()
    condFrame.cond_item_hp_my:Hide()
    condFrame.cond_item_hp_tgt:Hide()
    condFrame.cond_item_hp_comp:Hide()
    condFrame.cond_item_hp_val:Hide()
    condFrame.cond_item_hp_val_enter:Hide()
    condFrame.cond_item_remaining_cb:Hide()
    condFrame.cond_item_remaining_comp:Hide()
    condFrame.cond_item_remaining_val:Hide()
    condFrame.cond_item_remaining_val_enter:Hide()
    condFrame.cond_item_cp_cb:Hide()
    condFrame.cond_item_cp_comp:Hide()
    condFrame.cond_item_cp_val:Hide()
    condFrame.cond_item_cp_val_enter:Hide()
	condFrame.cond_item_inv_trinket1:Hide()
    condFrame.cond_item_inv_trinket2:Hide()
    condFrame.cond_item_inv_trinket_first:Hide()
    condFrame.cond_item_inv_trinket_both:Hide()
    condFrame.cond_item_inv_wep_mainhand:Hide()
    condFrame.cond_item_inv_wep_offhand:Hide()
    condFrame.cond_item_inv_wep_ranged:Hide()
	if condFrame.cond_item_class_note then condFrame.cond_item_class_note:Hide() end
    -- Register the three per-type Aura Conditions managers
    if AuraCond_RegisterManager then
        if condFrame.abilityAuraAnchor then
            AuraCond_RegisterManager("ability", condFrame.abilityAuraAnchor)
        end
        if condFrame.auraAuraAnchor then
            AuraCond_RegisterManager("aura", condFrame.auraAuraAnchor)
        end
        if condFrame.itemAuraAnchor then
            AuraCond_RegisterManager("item", condFrame.itemAuraAnchor)
        end
    end

    -- start hidden; visibility controlled from UpdateConditionsUI
    if condFrame.abilityAuraAnchor then condFrame.abilityAuraAnchor:Hide() end
    if condFrame.auraAuraAnchor    then condFrame.auraAuraAnchor:Hide()    end
    if condFrame.itemAuraAnchor    then condFrame.itemAuraAnchor:Hide()    end
end

-- Dynamically resize the scroll/content area to fit the last visible row (+20px buffer)
local function _ReflowCondAreaHeight()
    if not condFrame then return end

    -- Try both "_condArea" and "condArea" as the scroll child/content parent.
    -- Fallback to the frame itself if no explicit content frame exists.
    local parent = condFrame._condArea or condFrame.condArea or condFrame
    if not parent or not parent.GetChildren then return end

    local children = { parent:GetChildren() }
    if not children or not children[1] then return end

    -- We want the *bottom* of the lowest visible child: bottom = y - height
    local minBottom = nil

    local i = 1
    while children[i] do
        local f = children[i]
        if f and f.IsShown and f:IsShown() and f.GetPoint and f.GetHeight then
            local _, _, _, _, y = f:GetPoint(1)
            if y then
                local h = f:GetHeight() or 0
                local bottom = y - h
                if not minBottom or bottom < minBottom then
                    minBottom = bottom
                end
            end
        end
        i = i + 1
    end

    if not minBottom then
        return
    end

    -- minBottom is negative (rows go downward), so -minBottom is the content depth.
    local height = -minBottom + 20

    -- Don't collapse too far; small entries (few rows) still get a sane min height.
    if height < 200 then
        height = 200
    end

    parent:SetHeight(height)

    -- Make sure the scrollframe actually uses this content frame as its scroll child
    -- Try both "_scrollFrame" and "scrollFrame" to match your actual field names.
    local sf = condFrame._scrollFrame or condFrame.scrollFrame
    if sf then
        if sf.SetScrollChild then
            sf:SetScrollChild(parent)
        end
        if sf.UpdateScrollChildRect then
            sf:UpdateScrollChildRect()
        end
    end
end

----------------------------------------------------------------
-- Dynamic "Aura Conditions" manager (Ability / Aura / Item)
-- UI behaviour:
--   - Separator caption: "AURA CONDITIONS"
--   - Yellow explainer text:
--       "Add conditions for found or missing Auras:"
--   - Always 1 editing row at the bottom that walks through:
--       Buff/Debuff -> Found/Missing -> On player/On target -> spell name + Add
--   - Saved rows show:
--       "Buff | Found | On player: Battle Shout" (small white text) + [X] to delete
----------------------------------------------------------------
do
    -- Small helper to reopen the dropdown a frame later (like the item version),
    -- so clicking Prev/Next does not cause the menu to close.
    local _ddReopenFrame = CreateFrame("Frame")
    local _ddReopenRow   = nil

    _ddReopenFrame:Hide()
    _ddReopenFrame:SetScript("OnUpdate", function()
        _ddReopenFrame:Hide()
        if not _ddReopenRow or not _ddReopenRow.abilityDD then
            _ddReopenRow = nil
            return
        end
        -- reopen anchored on the dropdown itself, offset x=0
        ToggleDropDownMenu(nil, nil, _ddReopenRow.abilityDD, _ddReopenRow.abilityDD, 0, 0)
        _ddReopenRow = nil
    end)

    local function AuraCond_ReopenDDNextFrame(row)
        _ddReopenRow = row
        _ddReopenFrame:Show()
    end

    local function AuraCond_Len(t)
        if not t then return 0 end
        local n = 0
        while t[n+1] ~= nil do
            n = n + 1
        end
        return n
    end

    local function AuraCond_GetListForType(typeKey)
        if not currentKey or not DoiteAurasDB or not DoiteAurasDB.spells then return nil end
        local d = EnsureDBEntry(currentKey)
        if not d or not d.conditions then return nil end

        if typeKey == "ability" then
            d.conditions.ability = d.conditions.ability or {}
            d.conditions.ability.auraConditions = d.conditions.ability.auraConditions or {}
            return d.conditions.ability.auraConditions
        elseif typeKey == "aura" then
            d.conditions.aura = d.conditions.aura or {}
            d.conditions.aura.auraConditions = d.conditions.aura.auraConditions or {}
            return d.conditions.aura.auraConditions
        elseif typeKey == "item" then
            d.conditions.item = d.conditions.item or {}
            d.conditions.item.auraConditions = d.conditions.item.auraConditions or {}
            return d.conditions.item.auraConditions
        end
        return nil
    end

    -- Build a sorted list of non-passive abilities from the spellbook
    local function AuraCond_BuildAbilitySpellList()
        local spells = {}
        local i = 1
        while true do
            local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
            if not name then
                break
            end

            local isPassive = false
            if IsPassiveSpell then
                -- best-effort: use IsPassiveSpell if available (signature differs by client)
                local ok, passive = pcall(IsPassiveSpell, i, BOOKTYPE_SPELL)
                if ok and passive then
                    isPassive = true
                end
            end
            if (not isPassive) and rank and string.find(rank, "Passive") then
                isPassive = true
            end

            if not isPassive then
                table.insert(spells, name)
            end
            i = i + 1
        end

        table.sort(spells, function(a, b)
            a = string.lower(a or "")
            b = string.lower(b or "")
            return a < b
        end)

        return spells
    end

    -- Initialize / refresh the Ability dropdown for a given editing row
    local function AuraCond_InitAbilityDropdown(row)
        if not row or not row.abilityDD then return end

        local spells = AuraCond_BuildAbilitySpellList()
        row._abilitySpells = spells

        local total = table.getn(spells)
        local perPage = 10

        if total == 0 then
            UIDropDownMenu_Initialize(row.abilityDD, function() end)
            if UIDropDownMenu_SetText then
                pcall(UIDropDownMenu_SetText, "No abilities found", row.abilityDD)
            end
            return
        end

        local maxPage = math.max(1, math.ceil(total / perPage))
        local page = row._abilityPage or 1
        if page < 1 then page = 1 end
        if page > maxPage then page = maxPage end
        row._abilityPage = page

        local startIndex = (page - 1) * perPage + 1
        local endIndex   = math.min(startIndex + perPage - 1, total)

        UIDropDownMenu_Initialize(row.abilityDD, function(frame, level, menuList)
            local info

            -- Previous page (at the TOP, yellow text)
            if page > 1 then
                info = {}
                info.text = "|cffffd000<< Previous|r"
                info.value = "PREV"
                info.notCheckable = true
                info.func = function()
                    row._abilityPage = page - 1
                    AuraCond_InitAbilityDropdown(row)
                    AuraCond_ReopenDDNextFrame(row)
                end
                UIDropDownMenu_AddButton(info)
            end

            -- Ability entries
            local idx = startIndex
            while idx <= endIndex do
                local name = spells[idx]
                info = {}
                info.text = name
                info.value = name
                local pickedName = name
                info.func = function(button)
                    local val = (button and button.value) or pickedName
                    row._spellName = val
                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, row.abilityDD, val)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, val, row.abilityDD)
                    end
                    if _GoldifyDD then
                        _GoldifyDD(row.abilityDD)
                    end
                end
                info.checked = (row._spellName == name)
                UIDropDownMenu_AddButton(info)
                idx = idx + 1
            end

            -- Next page (at the BOTTOM, yellow text)
            if page < maxPage then
                info = {}
                info.text = "|cffffd000Next >>|r"
                info.value = "NEXT"
                info.notCheckable = true
                info.func = function()
                    row._abilityPage = page + 1
                    AuraCond_InitAbilityDropdown(row)
                    AuraCond_ReopenDDNextFrame(row)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)

        local label = row._spellName or "Select ability"
        if UIDropDownMenu_SetText then
            pcall(UIDropDownMenu_SetText, label, row.abilityDD)
        end
        if _GoldifyDD then
            _GoldifyDD(row.abilityDD)
        end
    end


    local function AuraCond_BuildDescription(buffType, mode, unit, name)
        local niceName = AuraCond_TitleCase(name or "")

        local yellow = "|cffffd000"
        local white  = "|cffffffff"
        local sep    = "|cffffffff | |r"  -- white " | "

        -- Special case: Ability rows
        if buffType == "ABILITY" then
            local typeColor = "|cff4da6ff" -- ability blue
            local typePart  = typeColor .. "Ability" .. "|r"

            local modeWord
            if mode == "oncd" then
                modeWord = "On cooldown"
            else
                modeWord = "Not on cooldown"
            end
            local modePart = yellow .. modeWord .. "|r"
            local namePart = white  .. (niceName or "") .. "|r"

            -- Example: [blue]Ability|r | [yellow]Not on cooldown|r: [white]Sinister Strike|r
            return typePart .. " " .. sep .. modePart .. ": " .. namePart
        end

        -- Default: Buff / Debuff aura rows
        local typeWord = (buffType == "DEBUFF") and "Debuff" or "Buff"
        local modeWord = (mode == "missing") and "Missing" or "Found"
        local unitWord
        if unit == "target" then
            unitWord = "On target"
        else
            unitWord = "On player"
        end

        -- colors:
        --  Buff    -> green
        --  Debuff  -> red
        --  "Found"/"Missing" and "On player"/"On target" -> yellow
        --  "|" separators and the aura name -> white
        local typeColor  = (buffType == "DEBUFF") and "|cffff0000" or "|cff00ff00"

        local typePart  = typeColor .. typeWord .. "|r"
        local modePart  = yellow    .. modeWord .. "|r"
        local unitPart  = yellow    .. unitWord .. "|r"
        local namePart  = white     .. (niceName or "") .. "|r"

        -- Example final string:
        --   [green/red]Buff|r [white]| |r [yellow]Found|r [white]| |r [yellow]On player|r: [white]Battle Shout|r
        return typePart .. " " .. sep .. modePart .. " " .. sep .. unitPart .. ": " .. namePart
    end

    local function AuraCond_SetRowState(row, state)
        row._state = state

        -- hide everything by default
        row.btn1:Hide()
        row.btn2:Hide()
        row.closeBtn:Show() -- always visible
        row.editBox:Hide()
        row.addButton:Hide()
        row.labelFS:Hide()
        if row.abilityDD then
            row.abilityDD:Hide()
        end

        -- cached layout helpers
        local spacing     = row._spacing     or 4
        local parentWidth = row._parentWidth or 260
        local closeWidth  = row._closeWidth  or 20

        if state == "STEP1" then
            -- First step: three choices (Ability / Buff / Debuff)
            row._branch = nil

            -- Equal-width layout for: Ability | Buff | Debuff
            local spacing     = row._spacing     or 4
            local parentWidth = row._parentWidth or 260
            local closeWidth  = row._closeWidth  or 20

            -- Space available for the three buttons (leave room for [X] and some padding)
            local available = parentWidth - closeWidth - spacing*4
            if available < 60 then
                available = 60
            end
            local w = math.floor(available / 3)

            row.btn1:SetWidth(w)
            row.btn2:SetWidth(w)
            row.addButton:SetWidth(w)

            row.btn1:ClearAllPoints()
            row.btn2:ClearAllPoints()
            row.addButton:ClearAllPoints()

            row.btn1:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.btn2:SetPoint("LEFT", row.btn1, "RIGHT", spacing, 0)
            row.addButton:SetPoint("LEFT", row.btn2, "RIGHT", spacing, 0)

            row.btn1:SetText("Ability")
            row.btn2:SetText("Buff")
            row.addButton:SetText("Debuff")

            row.btn1:Show()
            row.btn2:Show()
            row.addButton:Show()

        elseif state == "STEP2" then
            -- Second step: depends on branch
            row.btn1:ClearAllPoints()
            row.btn2:ClearAllPoints()
            row.btn1:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.btn2:SetPoint("LEFT", row.btn1, "RIGHT", spacing, 0)

            if row._branch == "ABILITY" then
                -- Ability: cooldown mode
                row.btn1:SetText("Not on CD")
                row.btn2:SetText("On CD")
            else
                -- Aura (Buff/Debuff): Found / Missing
                row.btn1:SetText("Found")
                row.btn2:SetText("Missing")
            end

            row.btn1:Show()
            row.btn2:Show()

        elseif state == "STEP3" then
            -- Aura only: unit selection
            row.btn1:ClearAllPoints()
            row.btn2:ClearAllPoints()
            row.btn1:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.btn2:SetPoint("LEFT", row.btn1, "RIGHT", spacing, 0)

            row.btn1:SetText("On player")
            row.btn2:SetText("On target")
            row.btn1:Show()
            row.btn2:Show()

        elseif state == "INPUT" then
            -- In INPUT mode, layout is:
            --   [editbox or dropdown] ................................ [Add][X]
            -- so the Add button sits closer to the X on the right side.
            local addWidth  = row.addButton:GetWidth() or 40
            local rightGap  = 2
            local totalRight = closeWidth + spacing + addWidth + rightGap

            local editWidth = parentWidth - spacing - totalRight
            if editWidth < 60 then editWidth = 60 end

            row.editBox:ClearAllPoints()
            row.addButton:ClearAllPoints()
            if row.abilityDD then
                row.abilityDD:ClearAllPoints()
            end

            -- edit/input area starts at x=0
            row.editBox:SetWidth(editWidth)
            row.editBox:SetPoint("LEFT", row, "LEFT", 10, 0)

            -- Add button sits just to the left of the close "X"
            row.addButton:SetPoint("RIGHT", row.closeBtn, "LEFT", -rightGap, 0)
            row.addButton:SetText("Add")

            if row._branch == "ABILITY" then
                -- Ability branch: dropdown (starting at x=0) + Add
                if row.abilityDD then
                    row.editBox:Hide()
                    row.abilityDD:SetPoint("LEFT", row, "LEFT", -15, -4)
                    if UIDropDownMenu_SetWidth then
                        pcall(UIDropDownMenu_SetWidth, editWidth, row.abilityDD)
                    end
                    AuraCond_InitAbilityDropdown(row)
                    row.abilityDD:Show()
                end
                row.addButton:Show()
            else
                -- Aura branch: manual spell-name input + Add
                row.editBox:Show()
                row.addButton:Show()
            end

        elseif state == "SAVED" then
            row.labelFS:SetText(row._desc or "")
            row.labelFS:Show()
        end
    end

    local function AuraCond_OnCancelEditing(row)
        -- Reset the single editing row back to the first step
        row._branch         = nil
        row._choiceBuffType = nil
        row._choiceMode     = nil
        row._choiceUnit     = nil
        row._spellName      = nil
        row._abilityPage    = 1

        if row.editBox and row.editBox.SetText then
            row.editBox:SetText("")
        end

        if row.abilityDD then
            if UIDropDownMenu_ClearAll then
                pcall(UIDropDownMenu_ClearAll, row.abilityDD)
            end
            if UIDropDownMenu_SetText then
                pcall(UIDropDownMenu_SetText, "Select ability", row.abilityDD)
            end
        end

        AuraCond_SetRowState(row, "STEP1")
    end

    local function AuraCond_RebuildFromDB_Internal(typeKey)

        local mgr = AuraCond_Managers[typeKey]
        if not mgr or not mgr.anchor then return end

        local list = AuraCond_GetListForType(typeKey) or {}
        local count = AuraCond_Len(list)

        if not mgr.savedRows then mgr.savedRows = {} end

        -- build / update saved rows from DB
        local i
        for i = 1, count do
            local entry = list[i]
            local row = mgr.savedRows[i]
            if not row then
                row = mgr._createRow(mgr, false)
                mgr.savedRows[i] = row
            end
            row._entryIndex      = i
            row._choiceBuffType  = (entry and entry.buffType) or "BUFF"
            row._choiceMode      = (entry and entry.mode)     or "found"
            row._choiceUnit      = (entry and entry.unit)     or "player"
            row._spellName       = (entry and entry.name)     or ""
            row._desc            = AuraCond_BuildDescription(
                                        row._choiceBuffType,
                                        row._choiceMode,
                                        row._choiceUnit,
                                        row._spellName
                                   )
            AuraCond_SetRowState(row, "SAVED")
            row:Show()
        end

        -- hide any extra savedRows beyond DB length
        local nRows = AuraCond_Len(mgr.savedRows)
        for i = count + 1, nRows do
            if mgr.savedRows[i] then
                mgr.savedRows[i]:Hide()
                mgr.savedRows[i]._entryIndex = nil
            end
        end

        -- ensure a single editing row at the bottom
        if not mgr.editRow then
            mgr.editRow = mgr._createRow(mgr, true)
        end
        AuraCond_OnCancelEditing(mgr.editRow)
        mgr.editRow:Show()

        -- layout: label at 0, then rows going down
        local y = -14

        i = 1
        while mgr.savedRows and mgr.savedRows[i] do
            local row = mgr.savedRows[i]
            if row:IsShown() then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", mgr.anchor, "TOPLEFT", 0, y)
                row:SetPoint("TOPRIGHT", mgr.anchor, "TOPRIGHT", 0, y)
                y = y - 18
            end
            i = i + 1
        end

        if mgr.editRow and mgr.editRow:IsShown() then
            mgr.editRow:ClearAllPoints()
            mgr.editRow:SetPoint("TOPLEFT", mgr.anchor, "TOPLEFT", 0, y)
            mgr.editRow:SetPoint("TOPRIGHT", mgr.anchor, "TOPRIGHT", 0, y)
            y = y - 18
        end

        mgr.anchor:SetHeight(-y + 4)
		_ReflowCondAreaHeight()
    end

     local function AuraCond_OnAdd(row)
        if not currentKey then return end
        local mgr = row._manager
        if not mgr then return end

        local text
        if row._branch == "ABILITY" then
            text = row._spellName or ""
        else
            text = row.editBox and row.editBox:GetText() or ""
        end
        text = string.gsub(text or "", "^%s*(.-)%s*$", "%1")
        if text == "" then
            return
        end

        local buffType = row._choiceBuffType or "BUFF"
        local mode     = row._choiceMode     or "found"
        local unit
        if row._branch == "ABILITY" then
            unit = nil
            buffType = "ABILITY"
        else
            unit = row._choiceUnit or "player"
        end

        local list = AuraCond_GetListForType(mgr.typeKey)
        if not list then return end

        local entry = {
            buffType = buffType,
            mode     = mode,
            unit     = unit,
            name     = AuraCond_TitleCase(text),
        }

        local n = AuraCond_Len(list)
        list[n+1] = entry

        -- rebuild so we get a fresh saved row and a new clean editing row
        AuraCond_RebuildFromDB_Internal(mgr.typeKey)
        _ReflowCondAreaHeight()
    end

    local function AuraCond_OnDeleteSaved(row)
        if not currentKey then return end
        local mgr = row._manager
        if not mgr then return end

        local list = AuraCond_GetListForType(mgr.typeKey)
        if not list then return end

        local idx = row._entryIndex or 0
        local n = AuraCond_Len(list)
        if idx < 1 or idx > n then return end

        -- compact the array: shift down all elements after idx
        local i
        for i = idx, n-1 do
            list[i] = list[i+1]
        end
        list[n] = nil

        AuraCond_RebuildFromDB_Internal(mgr.typeKey)
        _ReflowCondAreaHeight()
    end

    -- simple counter so each dropdown gets a real (unique) frame name
    local AuraCond_RowCounter = (AuraCond_RowCounter or 0)

    local function AuraCond_CreateRow(mgr, isEditing)
        AuraCond_RowCounter = AuraCond_RowCounter + 1

        local parent = mgr.anchor
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(18)

        row._manager = mgr
        row._abilityPage = 1

        -- cache layout parameters on the row so SetRowState can reuse them
        local parentWidth = (parent and parent.GetWidth and parent:GetWidth()) or 0
        if parentWidth <= 0 then
            parentWidth = 260
        end
        local closeWidth  = 20
        local spacing     = 4
        local mainWidth   = math.floor((parentWidth - closeWidth - spacing*3) / 2)

        row._parentWidth = parentWidth
        row._closeWidth  = closeWidth
        row._spacing     = spacing
        row._mainWidth   = mainWidth

        -- main 2 buttons
        row.btn1 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.btn2 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.closeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.addButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.labelFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

        local ddName = "DoiteAuraCond_AbilityDD_" .. tostring(mgr.typeKey or "X") .. "_" .. tostring(AuraCond_RowCounter)
        row.abilityDD = CreateFrame("Frame", ddName, row, "UIDropDownMenuTemplate")

        row.btn1:SetWidth(mainWidth)
        row.btn2:SetWidth(mainWidth)
        row.btn1:SetHeight(18)
        row.btn2:SetHeight(18)

        row.closeBtn:SetWidth(closeWidth)
        row.closeBtn:SetHeight(18)

        -- initial editbox width; will be recomputed in INPUT state
        local editWidth = parentWidth - closeWidth - spacing*3 - 40
        if editWidth < 60 then editWidth = 60 end

        row.editBox:SetWidth(editWidth)
        row.editBox:SetHeight(18)
        row.editBox:SetAutoFocus(false)
        row.editBox:SetFontObject("GameFontNormalSmall")

        row.addButton:SetWidth(40)
        row.addButton:SetHeight(18)

        -- default positions (used for STEP2/STEP3/SAVED); STEP1/INPUT will override layout
        row.btn1:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.btn2:SetPoint("LEFT", row.btn1, "RIGHT", spacing, 0)
        row.closeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

        row.editBox:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.addButton:SetPoint("LEFT", row.editBox, "RIGHT", spacing, 0)

        -- Ability dropdown sits where the editBox does (INPUT state swaps between them)
        row.abilityDD:SetPoint("LEFT", row, "LEFT", 0, -2)
        if UIDropDownMenu_SetWidth then
            pcall(UIDropDownMenu_SetWidth, parentWidth - closeWidth - spacing*3 - 40, row.abilityDD)
        end

        row.labelFS:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.labelFS:SetTextColor(1, 1, 1)
        -- no fixed width: long descriptions stay on a single line, may be clipped on the right
        row.labelFS:SetNonSpaceWrap(false)

        row.closeBtn:SetText("X")

        local function YellowifyButton(btn)
            if not btn then return end
            if btn.SetNormalFontObject then
                btn:SetNormalFontObject("GameFontNormalSmall")
            end
            local fs = btn:GetFontString()
            if fs and fs.SetTextColor then
                fs:SetTextColor(1, 0.82, 0)
            end
        end

        YellowifyButton(row.btn1)
        YellowifyButton(row.btn2)
        YellowifyButton(row.addButton)
        YellowifyButton(row.closeBtn)

        -- progression buttons:
        -- STEP1: Ability / Buff / Debuff
        -- STEP2: (Ability) Not on cooldown / On cooldown
        --         (Aura)   Found / Missing
        -- STEP3: (Aura only) On player / On target
        row.btn1:SetScript("OnClick", function()
            if not currentKey then return end
            local state = row._state

            if state == "STEP1" then
                -- Ability
                row._branch         = "ABILITY"
                row._choiceBuffType = "ABILITY"
                row._choiceMode     = nil
                row._choiceUnit     = nil
                AuraCond_SetRowState(row, "STEP2")

            elseif state == "STEP2" then
                if row._branch == "ABILITY" then
                    -- Ability: Not on cooldown
                    row._choiceMode = "notcd"
                    AuraCond_SetRowState(row, "INPUT")
                else
                    -- Aura: Found
                    row._choiceMode = "found"
                    AuraCond_SetRowState(row, "STEP3")
                end

            elseif state == "STEP3" then
                -- Aura: On player
                row._choiceUnit = "player"
                AuraCond_SetRowState(row, "INPUT")
            end
        end)

        row.btn2:SetScript("OnClick", function()
            if not currentKey then return end
            local state = row._state

            if state == "STEP1" then
                -- Buff (Aura)
                row._branch         = "AURA"
                row._choiceBuffType = "BUFF"
                row._choiceMode     = nil
                row._choiceUnit     = nil
                AuraCond_SetRowState(row, "STEP2")

            elseif state == "STEP2" then
                if row._branch == "ABILITY" then
                    -- Ability: On cooldown
                    row._choiceMode = "oncd"
                    AuraCond_SetRowState(row, "INPUT")
                else
                    -- Aura: Missing
                    row._choiceMode = "missing"
                    AuraCond_SetRowState(row, "STEP3")
                end

            elseif state == "STEP3" then
                -- Aura: On target
                row._choiceUnit = "target"
                AuraCond_SetRowState(row, "INPUT")
            end
        end)

        row.addButton:SetText("Add")
        row.addButton:SetScript("OnClick", function()
            if not currentKey then return end
            local state = row._state

            if state == "STEP1" then
                -- Debuff (Aura) third option
                row._branch         = "AURA"
                row._choiceBuffType = "DEBUFF"
                row._choiceMode     = nil
                row._choiceUnit     = nil
                AuraCond_SetRowState(row, "STEP2")
                return
            end

            if state == "INPUT" then
                AuraCond_OnAdd(row)
            end
        end)

        row.editBox:SetScript("OnEnterPressed", function()
            if not currentKey then return end
            AuraCond_OnAdd(row)
            if this and this.ClearFocus then this:ClearFocus() end
        end)

        row.closeBtn:SetScript("OnClick", function()
            if row._state == "SAVED" then
                AuraCond_OnDeleteSaved(row)
            else
                -- editing row; always reset to the first step
                AuraCond_OnCancelEditing(row)
                _ReflowCondAreaHeight()
            end
        end)

        if isEditing then
            AuraCond_OnCancelEditing(row)
        else
            row._state = "SAVED"
            AuraCond_SetRowState(row, "SAVED")
        end

        row:Hide()
        return row
    end

    AuraCond_RegisterManager = function(typeKey, anchorFrame)
        if not anchorFrame then return end

        local mgr = AuraCond_Managers[typeKey] or {}
        mgr.typeKey = typeKey
        mgr.anchor  = anchorFrame
        mgr.savedRows = mgr.savedRows or {}
        mgr.editRow   = mgr.editRow or nil
        mgr._createRow = AuraCond_CreateRow

        if not mgr.label then
            mgr.label = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            mgr.label:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", 0, 0)
            mgr.label:SetJustifyH("LEFT")
            mgr.label:SetTextColor(1, 0.82, 0)
            mgr.label:SetText("Add conditions for found or missing Auras:")
        end

        AuraCond_Managers[typeKey] = mgr
        anchorFrame:SetHeight(20)
        anchorFrame:Hide()
    end

    AuraCond_RefreshFromDB = function(typeKey)
        local tk, mgr
        for tk, mgr in pairs(AuraCond_Managers) do
            if mgr.anchor then
                if tk == typeKey then
                    mgr.anchor:Show()
                else
                    mgr.anchor:Hide()
                end
            end
        end

        if typeKey then
            AuraCond_RebuildFromDB_Internal(typeKey)
        end
        _ReflowCondAreaHeight()
    end

    AuraCond_ResetEditing = function()
        -- no-op for now; all editing state is rebuilt from DB in AuraCond_RefreshFromDB
    end
end

-- Update conditions UI to reflect DB for the currentKey/data
local function UpdateConditionsUI(data)
    if not condFrame then return end
    if not data then return end
    if not data.conditions then data.conditions = {} end
    local c = data.conditions

    -- ABILITY
    if data.type == "Ability" then
        -- show rows
        ShowSeparatorsForType("ability")
        -- ensure aura-only tip is hidden when not editing an aura
        if condFrame.cond_aura_tip then
            condFrame.cond_aura_tip:Hide()
        end
		if AuraCond_RefreshFromDB then
            AuraCond_RefreshFromDB("ability")
        end

        condFrame.cond_ability_usable:Show()
        condFrame.cond_ability_notcd:Show()
        condFrame.cond_ability_oncd:Show()
        condFrame.cond_ability_incombat:Show()
        condFrame.cond_ability_outcombat:Show()
        condFrame.cond_ability_target_help:Show()
        condFrame.cond_ability_target_harm:Show()
        condFrame.cond_ability_target_self:Show()
        condFrame.cond_ability_power:Show()
        condFrame.cond_ability_glow:Show()
        condFrame.cond_ability_greyscale:Show()
        condFrame.cond_ability_slider:Show()
        condFrame.cond_ability_remaining_cb:Show()

        -- exclusives
        local mode = (c.ability and c.ability.mode) or nil
        condFrame.cond_ability_usable:SetChecked(mode == "usable")
        condFrame.cond_ability_notcd:SetChecked(mode == "notcd")
        condFrame.cond_ability_oncd:SetChecked(mode == "oncd")

        -- combat -> now independent booleans, with fallback to legacy string 'combat'
        local inC, outC
        if c.ability and (c.ability.inCombat ~= nil or c.ability.outCombat ~= nil) then
            inC = c.ability.inCombat and true or false
            outC = c.ability.outCombat and true or false
        else
            -- legacy handling
            local cm = c.ability and c.ability.combat or nil
            if cm == "in" then inC, outC = true, false
            elseif cm == "out" then inC, outC = false, true
            else inC, outC = true, true -- default both
            end
        end
        condFrame.cond_ability_incombat:SetChecked(inC)
        condFrame.cond_ability_outcombat:SetChecked(outC)

		-- multi-select booleans
		local ah = (c.ability and c.ability.targetHelp) == true
		local ar = (c.ability and c.ability.targetHarm) == true
		local as = (c.ability and c.ability.targetSelf) == true
		condFrame.cond_ability_target_help:SetChecked(ah)
		condFrame.cond_ability_target_harm:SetChecked(ar)
		condFrame.cond_ability_target_self:SetChecked(as)


        -- power controls
        local pEnabled = (c.ability and c.ability.powerEnabled) and true or false
        condFrame.cond_ability_power:SetChecked(pEnabled)
        if pEnabled then
            condFrame.cond_ability_power_comp:Show()
            condFrame.cond_ability_power_val:Show()
            condFrame.cond_ability_power_val_enter:Show()
            local comp = (c.ability and c.ability.powerComp) or ""
            UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_power_comp, comp)
            UIDropDownMenu_SetText(comp, condFrame.cond_ability_power_comp)
			_GoldifyDD(condFrame.cond_ability_power_comp)
            condFrame.cond_ability_power_val:SetText(tostring((c.ability and c.ability.powerVal) or 0))
        else
            condFrame.cond_ability_power_comp:Hide()
            condFrame.cond_ability_power_val:Hide()
            condFrame.cond_ability_power_val_enter:Hide()
        end

        -- glow & greyscale states
        condFrame.cond_ability_glow:SetChecked((c.ability and c.ability.glow) or false)
        condFrame.cond_ability_greyscale:SetChecked((c.ability and c.ability.greyscale) or false)

        -- slider vs remaining
        local slidEnabled = (c.ability and c.ability.slider) and true or false
        condFrame.cond_ability_slider:SetChecked(slidEnabled)
        local remEnabled = (c.ability and c.ability.remainingEnabled) and true or false
        condFrame.cond_ability_remaining_cb:SetChecked(remEnabled)

        if mode == "oncd" then
            condFrame.cond_ability_slider:Disable()
            condFrame.cond_ability_slider:Hide()
            condFrame.cond_ability_slider_dir:Hide()
            if remEnabled then
                condFrame.cond_ability_remaining_comp:Show()
                condFrame.cond_ability_remaining_val:Show()
                condFrame.cond_ability_remaining_val_enter:Show()
                local comp = (c.ability and c.ability.remainingComp) or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_remaining_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_ability_remaining_comp)
				_GoldifyDD(condFrame.cond_ability_remaining_comp)
                condFrame.cond_ability_remaining_val:SetText(tostring((c.ability and c.ability.remainingVal) or 0))
            else
                condFrame.cond_ability_remaining_comp:Hide()
                condFrame.cond_ability_remaining_val:Hide()
                condFrame.cond_ability_remaining_val_enter:Hide()
            end
        else
            condFrame.cond_ability_slider:Enable()
            condFrame.cond_ability_slider:Show()
            if slidEnabled then
                condFrame.cond_ability_slider_dir:Show()
                local dir = (c.ability and c.ability.sliderDir) or "center"
                UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_slider_dir, dir)
                UIDropDownMenu_SetText(dir, condFrame.cond_ability_slider_dir)
				_GoldifyDD(condFrame.cond_ability_slider_dir)
            else
                condFrame.cond_ability_slider_dir:Hide()
            end
            condFrame.cond_ability_remaining_cb:SetChecked(false)
            condFrame.cond_ability_remaining_comp:Hide()
            condFrame.cond_ability_remaining_val:Hide()
            condFrame.cond_ability_remaining_val_enter:Hide()
            condFrame.cond_ability_remaining_cb:Hide()
        end

        -- Row 7: Combo points / class-specific note
        if _IsRogueOrDruid() then
            condFrame.cond_ability_cp_cb:Show()
            if condFrame.cond_ability_class_note then
                condFrame.cond_ability_class_note:Hide()
            end

            local cpOn = (c.ability and c.ability.cpEnabled) and true or false
            condFrame.cond_ability_cp_cb:SetChecked(cpOn)
            if cpOn then
                condFrame.cond_ability_cp_comp:Show()
                condFrame.cond_ability_cp_val:Show()
                condFrame.cond_ability_cp_val_enter:Show()
                local comp = (c.ability and c.ability.cpComp) or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_cp_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_ability_cp_comp)
                _GoldifyDD(condFrame.cond_ability_cp_comp)
                condFrame.cond_ability_cp_val:SetText(tostring((c.ability and c.ability.cpVal) or 0))
            else
                condFrame.cond_ability_cp_comp:Hide()
                condFrame.cond_ability_cp_val:Hide()
                condFrame.cond_ability_cp_val_enter:Hide()
            end
        else
            condFrame.cond_ability_cp_cb:Hide()
            condFrame.cond_ability_cp_comp:Hide()
            condFrame.cond_ability_cp_val:Hide()
            condFrame.cond_ability_cp_val_enter:Hide()
            if condFrame.cond_ability_class_note then
                condFrame.cond_ability_class_note:Show()
            end
        end

        -- Row 8: HP selector (mutually exclusive)
        condFrame.cond_ability_hp_my:Show()
        condFrame.cond_ability_hp_tgt:Show()
        local hpMode = c.ability and c.ability.hpMode or nil
        condFrame.cond_ability_hp_my:SetChecked(hpMode == "my")
        condFrame.cond_ability_hp_tgt:SetChecked(hpMode == "target")
        if hpMode == "my" or hpMode == "target" then
            condFrame.cond_ability_hp_comp:Show()
            condFrame.cond_ability_hp_val:Show()
            condFrame.cond_ability_hp_val_enter:Show()
            local comp = (c.ability and c.ability.hpComp) or ""
            UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_hp_comp, comp)
            UIDropDownMenu_SetText(comp, condFrame.cond_ability_hp_comp)
			_GoldifyDD(condFrame.cond_ability_hp_comp)
            condFrame.cond_ability_hp_val:SetText(tostring((c.ability and c.ability.hpVal) or 0))
        else
            condFrame.cond_ability_hp_comp:Hide()
            condFrame.cond_ability_hp_val:Hide()
            condFrame.cond_ability_hp_val_enter:Hide()
        end

        -- Row 9: Slider extras (only when slider is enabled AND mode is usable/notcd)
        local mode = (c.ability and c.ability.mode) or nil
        local slidEnabled = (c.ability and c.ability.slider) and true or false
        if slidEnabled and (mode == "usable" or mode == "notcd") then
            condFrame.cond_ability_slider_glow:Show()
            condFrame.cond_ability_slider_grey:Show()
            condFrame.cond_ability_slider_glow:SetChecked((c.ability and c.ability.sliderGlow) or false)
            condFrame.cond_ability_slider_grey:SetChecked((c.ability and c.ability.sliderGrey) or false)
        else
            condFrame.cond_ability_slider_glow:Hide()
            condFrame.cond_ability_slider_grey:Hide()
        end

        -- Row 10: Text flag (time remaining only; abilities never have a stack text)
        local function _enableCheck(cb)
            cb:Enable()
            if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(1, 0.82, 0) end
        end
        local function _disableCheck(cb)
            cb:Disable()
            if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(0.6, 0.6, 0.6) end
        end

        if mode == "oncd" then
            condFrame.cond_ability_text_time:Show()
            _enableCheck(condFrame.cond_ability_text_time)
            condFrame.cond_ability_text_time:SetChecked((c.ability and c.ability.textTimeRemaining) or false)

        elseif mode == "usable" or mode == "notcd" then
            condFrame.cond_ability_text_time:Show()
            if slidEnabled then
                _enableCheck(condFrame.cond_ability_text_time)
                condFrame.cond_ability_text_time:SetChecked((c.ability and c.ability.textTimeRemaining) or false)
            else
                if c.ability and c.ability.textTimeRemaining then
                    c.ability.textTimeRemaining = false
                end
                condFrame.cond_ability_text_time:SetChecked(false)
                _disableCheck(condFrame.cond_ability_text_time)
            end
        else
            condFrame.cond_ability_text_time:Hide()
        end

		-- Time remaining behaves as before (gated by slider when mode is usable/notcd; shown on 'oncd')
		if mode == "oncd" then
			condFrame.cond_ability_text_time:Show()
			_enableCheck(condFrame.cond_ability_text_time)
			condFrame.cond_ability_text_time:SetChecked((c.ability and c.ability.textTimeRemaining) or false)

		elseif mode == "usable" or mode == "notcd" then
			condFrame.cond_ability_text_time:Show()
			if slidEnabled then
				_enableCheck(condFrame.cond_ability_text_time)
				condFrame.cond_ability_text_time:SetChecked((c.ability and c.ability.textTimeRemaining) or false)
			else
				if c.ability and c.ability.textTimeRemaining then
					c.ability.textTimeRemaining = false
				end
				condFrame.cond_ability_text_time:SetChecked(false)
				_disableCheck(condFrame.cond_ability_text_time)
			end
		else
			condFrame.cond_ability_text_time:Hide()
		end


        -- initialize and show/hide Form dropdown based on player class availability
        local choices = (function()
            local _, cls = UnitClass("player")
            cls = cls and string.upper(cls) or ""
            return (cls == "WARRIOR" or cls == "ROGUE" or cls == "DRUID" or cls == "PRIEST" or cls == "PALADIN")
        end)()

		-- hide the aura dropdown if it exists
		if condFrame.cond_aura_formDD then
			condFrame.cond_aura_formDD:Hide()
		end

		if choices and condFrame.cond_ability_formDD then
			condFrame.cond_ability_formDD:Show()
			ClearDropdown(condFrame.cond_ability_formDD)
			InitFormDropdown(condFrame.cond_ability_formDD, data, "ability")
			local v = c.ability and c.ability.form
			if v and v ~= "All" and v ~= "" then
				UIDropDownMenu_SetSelectedValue(condFrame.cond_ability_formDD, v)
				UIDropDownMenu_SetText(v, condFrame.cond_ability_formDD)
				_GoldifyDD(condFrame.cond_ability_formDD)
			else
				UIDropDownMenu_SetText("Select form", condFrame.cond_ability_formDD)
				_GoldifyDD(condFrame.cond_ability_formDD)
			end
		elseif condFrame.cond_ability_formDD then
			condFrame.cond_ability_formDD:Hide()
			ClearDropdown(condFrame.cond_ability_formDD)
		end

        -- hide aura controls
        condFrame.cond_aura_found:Hide()
        condFrame.cond_aura_missing:Hide()
        condFrame.cond_aura_incombat:Hide()
        condFrame.cond_aura_outcombat:Hide()
		condFrame.cond_aura_target_help:Hide()
		condFrame.cond_aura_target_harm:Hide()
		condFrame.cond_aura_onself:Hide()
        condFrame.cond_aura_glow:Hide()
        condFrame.cond_aura_greyscale:Hide()
        condFrame.cond_aura_remaining_cb:Hide()
        condFrame.cond_aura_remaining_comp:Hide()
        condFrame.cond_aura_remaining_val:Hide()
        condFrame.cond_aura_remaining_val_enter:Hide()
        condFrame.cond_aura_stacks_cb:Hide()
        condFrame.cond_aura_stacks_comp:Hide()
        condFrame.cond_aura_stacks_val:Hide()
        condFrame.cond_aura_stacks_val_enter:Hide()
		condFrame.cond_aura_tip:Hide()
		if condFrame.cond_aura_text_time then condFrame.cond_aura_text_time:Hide() end
		if condFrame.cond_aura_text_stack then condFrame.cond_aura_text_stack:Hide() end

		if condFrame.cond_aura_power then condFrame.cond_aura_power:Hide() end
		if condFrame.cond_aura_power_comp then condFrame.cond_aura_power_comp:Hide() end
		if condFrame.cond_aura_power_val then condFrame.cond_aura_power_val:Hide() end
		if condFrame.cond_aura_power_val_enter then condFrame.cond_aura_power_val_enter:Hide() end

		if condFrame.cond_aura_hp_my then condFrame.cond_aura_hp_my:Hide() end
		if condFrame.cond_aura_hp_tgt then condFrame.cond_aura_hp_tgt:Hide() end
		if condFrame.cond_aura_hp_comp then condFrame.cond_aura_hp_comp:Hide() end
		if condFrame.cond_aura_hp_val then condFrame.cond_aura_hp_val:Hide() end
		if condFrame.cond_aura_hp_val_enter then condFrame.cond_aura_hp_val_enter:Hide() end

		if condFrame.cond_aura_cp_cb then condFrame.cond_aura_cp_cb:Hide() end
		if condFrame.cond_aura_cp_comp then condFrame.cond_aura_cp_comp:Hide() end
		if condFrame.cond_aura_cp_val then condFrame.cond_aura_cp_val:Hide() end
		if condFrame.cond_aura_cp_val_enter then condFrame.cond_aura_cp_val_enter:Hide() end
		if condFrame.cond_aura_class_note then condFrame.cond_aura_class_note:Hide() end
		
		if condFrame.cond_aura_mine then condFrame.cond_aura_mine:Hide() end
		if condFrame.cond_aura_owner_tip then condFrame.cond_aura_owner_tip:Hide() end
        if condFrame.cond_item_where_equipped then condFrame.cond_item_where_equipped:Hide() end
        if condFrame.cond_item_where_bag then condFrame.cond_item_where_bag:Hide() end
        if condFrame.cond_item_where_missing then condFrame.cond_item_where_missing:Hide() end
        if condFrame.cond_item_notcd then condFrame.cond_item_notcd:Hide() end
        if condFrame.cond_item_oncd then condFrame.cond_item_oncd:Hide() end
        if condFrame.cond_item_incombat then condFrame.cond_item_incombat:Hide() end
        if condFrame.cond_item_outcombat then condFrame.cond_item_outcombat:Hide() end
        if condFrame.cond_item_target_help then condFrame.cond_item_target_help:Hide() end
        if condFrame.cond_item_target_harm then condFrame.cond_item_target_harm:Hide() end
        if condFrame.cond_item_target_self then condFrame.cond_item_target_self:Hide() end
        if condFrame.cond_item_glow then condFrame.cond_item_glow:Hide() end
        if condFrame.cond_item_greyscale then condFrame.cond_item_greyscale:Hide() end
        if condFrame.cond_item_text_time then condFrame.cond_item_text_time:Hide() end
        if condFrame.cond_item_power then condFrame.cond_item_power:Hide() end
        if condFrame.cond_item_power_comp then condFrame.cond_item_power_comp:Hide() end
        if condFrame.cond_item_power_val then condFrame.cond_item_power_val:Hide() end
        if condFrame.cond_item_power_val_enter then condFrame.cond_item_power_val_enter:Hide() end
        if condFrame.cond_item_hp_my then condFrame.cond_item_hp_my:Hide() end
        if condFrame.cond_item_hp_tgt then condFrame.cond_item_hp_tgt:Hide() end
        if condFrame.cond_item_hp_comp then condFrame.cond_item_hp_comp:Hide() end
        if condFrame.cond_item_hp_val then condFrame.cond_item_hp_val:Hide() end
        if condFrame.cond_item_hp_val_enter then condFrame.cond_item_hp_val_enter:Hide() end
        if condFrame.cond_item_remaining_cb then condFrame.cond_item_remaining_cb:Hide() end
        if condFrame.cond_item_remaining_comp then condFrame.cond_item_remaining_comp:Hide() end
        if condFrame.cond_item_remaining_val then condFrame.cond_item_remaining_val:Hide() end
        if condFrame.cond_item_remaining_val_enter then condFrame.cond_item_remaining_val_enter:Hide() end
        if condFrame.cond_item_cp_cb then condFrame.cond_item_cp_cb:Hide() end
        if condFrame.cond_item_cp_comp then condFrame.cond_item_cp_comp:Hide() end
        if condFrame.cond_item_cp_val then condFrame.cond_item_cp_val:Hide() end
        if condFrame.cond_item_cp_val_enter then condFrame.cond_item_cp_val_enter:Hide() end
        if condFrame.cond_item_formDD then condFrame.cond_item_formDD:Hide() end
		if condFrame.cond_item_inv_trinket1 then condFrame.cond_item_inv_trinket1:Hide() end
        if condFrame.cond_item_inv_trinket2 then condFrame.cond_item_inv_trinket2:Hide() end
        if condFrame.cond_item_inv_trinket_first then condFrame.cond_item_inv_trinket_first:Hide() end
        if condFrame.cond_item_inv_trinket_both then condFrame.cond_item_inv_trinket_both:Hide() end
        if condFrame.cond_item_inv_wep_mainhand then condFrame.cond_item_inv_wep_mainhand:Hide() end
        if condFrame.cond_item_inv_wep_offhand then condFrame.cond_item_inv_wep_offhand:Hide() end
        if condFrame.cond_item_inv_wep_ranged then condFrame.cond_item_inv_wep_ranged:Hide() end
		if condFrame.cond_item_class_note then condFrame.cond_item_class_note:Hide() end

    -- ITEM
    elseif data.type == "Item" then
        ShowSeparatorsForType("item")
        -- ensure aura-only tip is hidden when not editing an aura
        if condFrame.cond_aura_tip then
            condFrame.cond_aura_tip:Hide()
        end
		if AuraCond_RefreshFromDB then
            AuraCond_RefreshFromDB("item")
        end

        local ic = c.item or {}

        local function _enCheck(cb)
            if not cb then return end
            cb:Enable()
            if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(1, 0.82, 0) end
        end
        local function _disCheck(cb)
            if not cb then return end
            cb:Disable()
            if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(0.6, 0.6, 0.6) end
        end
        local function _enDD(dd)
            if not dd then return end
            local btn = _G[dd:GetName().."Button"]
            local txt = _G[dd:GetName().."Text"]
            if btn and btn.Enable then btn:Enable() end
            if txt and txt.SetTextColor then txt:SetTextColor(1, 0.82, 0) end
        end
        local function _disDD(dd)
            if not dd then return end
            local btn = _G[dd:GetName().."Button"]
            local txt = _G[dd:GetName().."Text"]
            if btn and btn.Disable then btn:Disable() end
            if txt and txt.SetTextColor then txt:SetTextColor(0.6, 0.6, 0.6) end
        end

        -- WHEREABOUTS / INVENTORY SLOT (special items)
        local dispName       = data.displayName or currentKey or ""
        local isTrinketSlots = (dispName == "---EQUIPPED TRINKET SLOTS---")
        local isWeaponSlots  = (dispName == "---EQUIPPED WEAPON SLOTS---")

        local isMissing = false

        if isTrinketSlots or isWeaponSlots then
            -- Special synthetic entries: use "INVENTORY SLOT" row, never drive missing-logic
            SetSeparator("item", 1, "INVENTORY SLOT", true, true)

            -- Hide normal whereabouts
            condFrame.cond_item_where_equipped:Hide()
            condFrame.cond_item_where_bag:Hide()
            condFrame.cond_item_where_missing:Hide()

            if isTrinketSlots then
                -- Hide weapon radios
                if condFrame.cond_item_inv_wep_mainhand then
                    condFrame.cond_item_inv_wep_mainhand:Hide()
                    condFrame.cond_item_inv_wep_offhand:Hide()
                    condFrame.cond_item_inv_wep_ranged:Hide()
                end

                -- Show trinket radios
                condFrame.cond_item_inv_trinket1:Show()
                condFrame.cond_item_inv_trinket2:Show()
                condFrame.cond_item_inv_trinket_first:Show()
                condFrame.cond_item_inv_trinket_both:Show()

                local slot = ic.inventorySlot
                if slot ~= "TRINKET1" and slot ~= "TRINKET2" and slot ~= "TRINKET_FIRST" and slot ~= "TRINKET_BOTH" then
                    -- default: First ready
                    slot = "TRINKET_FIRST"
                    ic.inventorySlot = slot
                end

                condFrame.cond_item_inv_trinket1:SetChecked(slot == "TRINKET1")
                condFrame.cond_item_inv_trinket2:SetChecked(slot == "TRINKET2")
                condFrame.cond_item_inv_trinket_first:SetChecked(slot == "TRINKET_FIRST")
                condFrame.cond_item_inv_trinket_both:SetChecked(slot == "TRINKET_BOTH")

            else
                -- Hide trinket radios
                if condFrame.cond_item_inv_trinket1 then
                    condFrame.cond_item_inv_trinket1:Hide()
                    condFrame.cond_item_inv_trinket2:Hide()
                    condFrame.cond_item_inv_trinket_first:Hide()
                    condFrame.cond_item_inv_trinket_both:Hide()
                end

                -- Show weapon radios
                condFrame.cond_item_inv_wep_mainhand:Show()
                condFrame.cond_item_inv_wep_offhand:Show()
                condFrame.cond_item_inv_wep_ranged:Show()

                local slot = ic.inventorySlot
                if slot ~= "MAINHAND" and slot ~= "OFFHAND" and slot ~= "RANGED" then
                    -- default: Main hand
                    slot = "MAINHAND"
                    ic.inventorySlot = slot
                end

                condFrame.cond_item_inv_wep_mainhand:SetChecked(slot == "MAINHAND")
                condFrame.cond_item_inv_wep_offhand:SetChecked(slot == "OFFHAND")
                condFrame.cond_item_inv_wep_ranged:SetChecked(slot == "RANGED")
            end

            -- isMissing stays false here -> never greys out other rows

        else
            -- Normal items: original WHEREABOUTS behavior
            SetSeparator("item", 1, "WHEREABOUTS", true, true)

            -- Hide any inventory-slot radios if they exist
            if condFrame.cond_item_inv_trinket1 then
                condFrame.cond_item_inv_trinket1:Hide()
                condFrame.cond_item_inv_trinket2:Hide()
                condFrame.cond_item_inv_trinket_first:Hide()
                condFrame.cond_item_inv_trinket_both:Hide()
            end
            if condFrame.cond_item_inv_wep_mainhand then
                condFrame.cond_item_inv_wep_mainhand:Hide()
                condFrame.cond_item_inv_wep_offhand:Hide()
                condFrame.cond_item_inv_wep_ranged:Hide()
            end

            condFrame.cond_item_where_equipped:Show()
            condFrame.cond_item_where_bag:Show()
            condFrame.cond_item_where_missing:Show()

            local eq = (ic.whereEquipped ~= false)
            local bg = (ic.whereBag      ~= false)
            local ms = (ic.whereMissing  == true)

            if not eq and not bg and not ms then
                eq = true
            end

            condFrame.cond_item_where_equipped:SetChecked(eq)
            condFrame.cond_item_where_bag:SetChecked(bg)
            condFrame.cond_item_where_missing:SetChecked(ms)

            isMissing = ms
        end

        -- USABILITY & COOLDOWN
        condFrame.cond_item_notcd:Show()
        condFrame.cond_item_oncd:Show()
        _enCheck(condFrame.cond_item_notcd)
        _enCheck(condFrame.cond_item_oncd)

        local mode = ic.mode or "notcd"
        if mode ~= "notcd" and mode ~= "oncd" then mode = "notcd" end

        condFrame.cond_item_notcd:SetChecked(mode == "notcd")
        condFrame.cond_item_oncd:SetChecked(mode == "oncd")

        if isMissing then
            condFrame.cond_item_notcd:SetChecked(false)
            condFrame.cond_item_oncd:SetChecked(false)
            _disCheck(condFrame.cond_item_notcd)
            _disCheck(condFrame.cond_item_oncd)
        end

        -- COMBAT STATE
        condFrame.cond_item_incombat:Show()
        condFrame.cond_item_outcombat:Show()
        local inC, outC
        if ic.inCombat ~= nil or ic.outCombat ~= nil then
            inC  = ic.inCombat and true or false
            outC = ic.outCombat and true or false
        else
            inC, outC = true, true
        end
        condFrame.cond_item_incombat:SetChecked(inC)
        condFrame.cond_item_outcombat:SetChecked(outC)
        _enCheck(condFrame.cond_item_incombat)
        _enCheck(condFrame.cond_item_outcombat)

        -- TARGET CONDITIONS
        condFrame.cond_item_target_help:Show()
        condFrame.cond_item_target_harm:Show()
        condFrame.cond_item_target_self:Show()
        condFrame.cond_item_target_help:SetChecked(ic.targetHelp == true)
        condFrame.cond_item_target_harm:SetChecked(ic.targetHarm == true)
        condFrame.cond_item_target_self:SetChecked(ic.targetSelf == true)

        -- VISUAL EFFECTS
        condFrame.cond_item_glow:Show()
        condFrame.cond_item_greyscale:Show()
        condFrame.cond_item_text_time:Show()
        condFrame.cond_item_glow:SetChecked(ic.glow == true)
        condFrame.cond_item_greyscale:SetChecked(ic.greyscale == true)

        if mode == "oncd" and not isMissing then
            _enCheck(condFrame.cond_item_text_time)
            condFrame.cond_item_text_time:SetChecked(ic.textTimeRemaining == true)
        else
            if ic.textTimeRemaining then ic.textTimeRemaining = false end
            condFrame.cond_item_text_time:SetChecked(false)
            _disCheck(condFrame.cond_item_text_time)
        end

        -- RESOURCE
        condFrame.cond_item_power:Show()
        local pOn = (ic.powerEnabled == true)
        condFrame.cond_item_power:SetChecked(pOn)

        if isMissing then
            condFrame.cond_item_power:SetChecked(false)
            _disCheck(condFrame.cond_item_power)
            condFrame.cond_item_power_comp:Hide()
            condFrame.cond_item_power_val:Hide()
            condFrame.cond_item_power_val_enter:Hide()
        else
            _enCheck(condFrame.cond_item_power)
            if pOn then
                condFrame.cond_item_power_comp:Show()
                condFrame.cond_item_power_val:Show()
                condFrame.cond_item_power_val_enter:Show()
                local comp = ic.powerComp or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_item_power_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_item_power_comp)
                _GoldifyDD(condFrame.cond_item_power_comp)
                condFrame.cond_item_power_val:SetText(tostring(ic.powerVal or 0))
            else
                condFrame.cond_item_power_comp:Hide()
                condFrame.cond_item_power_val:Hide()
                condFrame.cond_item_power_val_enter:Hide()
            end
        end

        -- HEALTH CONDITION
        condFrame.cond_item_hp_my:Show()
        condFrame.cond_item_hp_tgt:Show()
        local hpMode = ic.hpMode
        condFrame.cond_item_hp_my:SetChecked(hpMode == "my")
        condFrame.cond_item_hp_tgt:SetChecked(hpMode == "target")

        if isMissing then
            condFrame.cond_item_hp_my:SetChecked(false)
            condFrame.cond_item_hp_tgt:SetChecked(false)
            _disCheck(condFrame.cond_item_hp_my)
            _disCheck(condFrame.cond_item_hp_tgt)
            condFrame.cond_item_hp_comp:Hide()
            condFrame.cond_item_hp_val:Hide()
            condFrame.cond_item_hp_val_enter:Hide()
        else
            _enCheck(condFrame.cond_item_hp_my)
            _enCheck(condFrame.cond_item_hp_tgt)
            if hpMode == "my" or hpMode == "target" then
                condFrame.cond_item_hp_comp:Show()
                condFrame.cond_item_hp_val:Show()
                condFrame.cond_item_hp_val_enter:Show()
                local comp = ic.hpComp or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_item_hp_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_item_hp_comp)
                _GoldifyDD(condFrame.cond_item_hp_comp)
                condFrame.cond_item_hp_val:SetText(tostring(ic.hpVal or 0))
            else
                condFrame.cond_item_hp_comp:Hide()
                condFrame.cond_item_hp_val:Hide()
                condFrame.cond_item_hp_val_enter:Hide()
            end
        end

        -- REMAINING TIME
        condFrame.cond_item_remaining_cb:Show()
        if mode == "oncd" and not isMissing then
            _enCheck(condFrame.cond_item_remaining_cb)
            local remOn = (ic.remainingEnabled == true)
            condFrame.cond_item_remaining_cb:SetChecked(remOn)
            if remOn then
                condFrame.cond_item_remaining_comp:Show()
                condFrame.cond_item_remaining_val:Show()
                condFrame.cond_item_remaining_val_enter:Show()
                local comp = ic.remainingComp or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_item_remaining_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_item_remaining_comp)
                _GoldifyDD(condFrame.cond_item_remaining_comp)
                condFrame.cond_item_remaining_val:SetText(tostring(ic.remainingVal or 0))
            else
                condFrame.cond_item_remaining_comp:Hide()
                condFrame.cond_item_remaining_val:Hide()
                condFrame.cond_item_remaining_val_enter:Hide()
            end
        else
            if ic.remainingEnabled then ic.remainingEnabled = false end
            condFrame.cond_item_remaining_cb:SetChecked(false)
            _disCheck(condFrame.cond_item_remaining_cb)
            condFrame.cond_item_remaining_comp:Hide()
            condFrame.cond_item_remaining_val:Hide()
            condFrame.cond_item_remaining_val_enter:Hide()
        end

        -- CLASS-SPECIFIC (combo points / note)
        if _IsRogueOrDruid() then
            condFrame.cond_item_cp_cb:Show()
            if condFrame.cond_item_class_note then
                condFrame.cond_item_class_note:Hide()
            end

            if isMissing then
                -- Item marked as Missing: keep CP row visible but forced off and greyed
                if ic.cpEnabled then ic.cpEnabled = false end
                condFrame.cond_item_cp_cb:SetChecked(false)
                _disCheck(condFrame.cond_item_cp_cb)
                condFrame.cond_item_cp_comp:Hide()
                condFrame.cond_item_cp_val:Hide()
                condFrame.cond_item_cp_val_enter:Hide()
            else
                _enCheck(condFrame.cond_item_cp_cb)
                local cpOn = (ic.cpEnabled == true)
                condFrame.cond_item_cp_cb:SetChecked(cpOn)
                if cpOn then
                    condFrame.cond_item_cp_comp:Show()
                    condFrame.cond_item_cp_val:Show()
                    condFrame.cond_item_cp_val_enter:Show()
                    local comp = ic.cpComp or ""
                    UIDropDownMenu_SetSelectedValue(condFrame.cond_item_cp_comp, comp)
                    UIDropDownMenu_SetText(comp, condFrame.cond_item_cp_comp)
                    _GoldifyDD(condFrame.cond_item_cp_comp)
                    condFrame.cond_item_cp_val:SetText(tostring(ic.cpVal or 0))
                else
                    condFrame.cond_item_cp_comp:Hide()
                    condFrame.cond_item_cp_val:Hide()
                    condFrame.cond_item_cp_val_enter:Hide()
                end
            end
        else
            condFrame.cond_item_cp_cb:Hide()
            condFrame.cond_item_cp_comp:Hide()
            condFrame.cond_item_cp_val:Hide()
            condFrame.cond_item_cp_val_enter:Hide()
            if condFrame.cond_item_class_note then
                condFrame.cond_item_class_note:Show()
            end
        end

        -- Form dropdown (item)
        if condFrame.cond_ability_formDD then condFrame.cond_ability_formDD:Hide() end
        if condFrame.cond_aura_formDD    then condFrame.cond_aura_formDD:Hide()    end

        local choices = (function()
            local _, cls = UnitClass("player")
            cls = cls and string.upper(cls) or ""
            return (cls == "WARRIOR" or cls == "ROGUE" or cls == "DRUID" or cls == "PRIEST" or cls == "PALADIN")
        end)()
        if choices and condFrame.cond_item_formDD then
            condFrame.cond_item_formDD:Show()
            ClearDropdown(condFrame.cond_item_formDD)
            InitFormDropdown(condFrame.cond_item_formDD, data, "item")
            local v = ic.form
            if v and v ~= "All" and v ~= "" then
                UIDropDownMenu_SetSelectedValue(condFrame.cond_item_formDD, v)
                UIDropDownMenu_SetText(v, condFrame.cond_item_formDD)
                _GoldifyDD(condFrame.cond_item_formDD)
            else
                UIDropDownMenu_SetText("Select form", condFrame.cond_item_formDD)
                _GoldifyDD(condFrame.cond_item_formDD)
            end
        elseif condFrame.cond_item_formDD then
            condFrame.cond_item_formDD:Hide()
            ClearDropdown(condFrame.cond_item_formDD)
        end

        -- hide ability controls
        condFrame.cond_ability_usable:Hide()
        condFrame.cond_ability_notcd:Hide()
        condFrame.cond_ability_oncd:Hide()
        condFrame.cond_ability_incombat:Hide()
        condFrame.cond_ability_outcombat:Hide()
        condFrame.cond_ability_target_help:Hide()
        condFrame.cond_ability_target_harm:Hide()
        condFrame.cond_ability_target_self:Hide()
        condFrame.cond_ability_power:Hide()
        condFrame.cond_ability_power_comp:Hide()
        condFrame.cond_ability_power_val:Hide()
        condFrame.cond_ability_power_val_enter:Hide()
        condFrame.cond_ability_glow:Hide()
        condFrame.cond_ability_greyscale:Hide()
        condFrame.cond_ability_slider:Hide()
        condFrame.cond_ability_slider_dir:Hide()
        condFrame.cond_ability_remaining_cb:Hide()
        condFrame.cond_ability_remaining_comp:Hide()
        condFrame.cond_ability_remaining_val:Hide()
        condFrame.cond_ability_remaining_val_enter:Hide()
        condFrame.cond_ability_text_time:Hide()
        condFrame.cond_ability_slider_glow:Hide()
        condFrame.cond_ability_slider_grey:Hide()
        condFrame.cond_ability_hp_my:Hide()
        condFrame.cond_ability_hp_tgt:Hide()
        condFrame.cond_ability_hp_comp:Hide()
        condFrame.cond_ability_hp_val:Hide()
        condFrame.cond_ability_hp_val_enter:Hide()
        condFrame.cond_ability_cp_cb:Hide()
        condFrame.cond_ability_cp_comp:Hide()
        condFrame.cond_ability_cp_val:Hide()
        condFrame.cond_ability_cp_val_enter:Hide()
		if condFrame.cond_ability_class_note then condFrame.cond_ability_class_note:Hide() end
        if condFrame.cond_ability_formDD then condFrame.cond_ability_formDD:Hide() end

        -- hide aura controls
        condFrame.cond_aura_found:Hide()
        condFrame.cond_aura_missing:Hide()
        condFrame.cond_aura_incombat:Hide()
        condFrame.cond_aura_outcombat:Hide()
        condFrame.cond_aura_target_help:Hide()
        condFrame.cond_aura_target_harm:Hide()
        condFrame.cond_aura_onself:Hide()
        condFrame.cond_aura_glow:Hide()
        condFrame.cond_aura_greyscale:Hide()
        condFrame.cond_aura_power:Hide()
        condFrame.cond_aura_power_comp:Hide()
        condFrame.cond_aura_power_val:Hide()
        condFrame.cond_aura_power_val_enter:Hide()
        condFrame.cond_aura_hp_my:Hide()
        condFrame.cond_aura_hp_tgt:Hide()
        condFrame.cond_aura_hp_comp:Hide()
        condFrame.cond_aura_hp_val:Hide()
        condFrame.cond_aura_hp_val_enter:Hide()
        condFrame.cond_aura_remaining_cb:Hide()
        condFrame.cond_aura_remaining_comp:Hide()
        condFrame.cond_aura_remaining_val:Hide()
        condFrame.cond_aura_remaining_val_enter:Hide()
        condFrame.cond_aura_stacks_cb:Hide()
        condFrame.cond_aura_stacks_comp:Hide()
        condFrame.cond_aura_stacks_val:Hide()
        condFrame.cond_aura_stacks_val_enter:Hide()
        condFrame.cond_aura_text_time:Hide()
        condFrame.cond_aura_text_stack:Hide()
        condFrame.cond_aura_cp_cb:Hide()
        condFrame.cond_aura_cp_comp:Hide()
        condFrame.cond_aura_cp_val:Hide()
		condFrame.cond_aura_cp_val_enter:Hide()
		condFrame.cond_aura_mine:Hide()
		if condFrame.cond_aura_owner_tip then condFrame.cond_aura_owner_tip:Hide() end
		if condFrame.cond_aura_tip then condFrame.cond_aura_tip:Hide() end
        if condFrame.cond_aura_formDD then condFrame.cond_aura_formDD:Hide() end
		if condFrame.cond_aura_class_note then condFrame.cond_aura_class_note:Hide() end

    -- AURA (Buff/Debuff)
    else	
        ShowSeparatorsForType("aura")

        if AuraCond_RefreshFromDB then
            AuraCond_RefreshFromDB("aura")
        end

        -- small helpers used in this branch only
        local function _enableCheck(cb)
            cb:Enable()
            if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(1, 0.82, 0) end
        end
        local function _disableCheck(cb)
            cb:Disable()
            if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(0.6, 0.6, 0.6) end
        end
        local function _enableDD(dd)
            if not dd then return end
            local btn = _G[dd:GetName().."Button"]
            local txt = _G[dd:GetName().."Text"]
            if btn and btn.Enable then btn:Enable() end
            if txt and txt.SetTextColor then txt:SetTextColor(1, 0.82, 0) end
        end
        local function _disableDD(dd)
            if not dd then return end
            local btn = _G[dd:GetName().."Button"]
            local txt = _G[dd:GetName().."Text"]
            if btn and btn.Disable then btn:Disable() end
            if txt and txt.SetTextColor then txt:SetTextColor(0.6, 0.6, 0.6) end
        end
        local function _hideRemInputs()
            condFrame.cond_aura_remaining_comp:Hide()
            condFrame.cond_aura_remaining_val:Hide()
            condFrame.cond_aura_remaining_val_enter:Hide()
        end

        condFrame.cond_aura_found:Show()
        condFrame.cond_aura_missing:Show()
        if condFrame.cond_aura_tip then condFrame.cond_aura_tip:Show() end
        condFrame.cond_aura_incombat:Show()
        condFrame.cond_aura_outcombat:Show()
        condFrame.cond_aura_target_help:Show()
        condFrame.cond_aura_target_harm:Show()
        condFrame.cond_aura_onself:Show()
        condFrame.cond_aura_glow:Show()
        condFrame.cond_aura_greyscale:Show()

        -- mode
        local amode = (c.aura and c.aura.mode) or nil
        condFrame.cond_aura_found:SetChecked(amode == "found")
        condFrame.cond_aura_missing:SetChecked(amode == "missing")

        -- combat flags (independent)
        local aIn, aOut
        if c.aura and (c.aura.inCombat ~= nil or c.aura.outCombat ~= nil) then
            aIn = c.aura.inCombat and true or false
            aOut = c.aura.outCombat and true or false
        else
            local cm = c.aura and c.aura.combat or nil
            if cm == "in" then aIn, aOut = true, false
            elseif cm == "out" then aIn, aOut = false, true
            else aIn, aOut = true, true
            end
        end
        condFrame.cond_aura_incombat:SetChecked(aIn)
        condFrame.cond_aura_outcombat:SetChecked(aOut)

        -- target read
        local th = (c.aura and c.aura.targetHelp) and true or false
        local tm = (c.aura and c.aura.targetHarm) and true or false
        local ts = (c.aura and c.aura.targetSelf) and true or false

        -- Normalize: Self is exclusive vs Help/Harm
        if ts then th, tm = false, false end

        -- If somehow all false (old state), default to Self-only
        if (not th) and (not tm) and (not ts) then
            ts = true
            if c.aura then
                c.aura.targetSelf = true
                c.aura.targetHelp = false
                c.aura.targetHarm = false
            end
        end

        -- derived target state
        local isSelfOnly   = ts and (not th) and (not tm)
        local isHelpOrHarm = (th or tm) and (not ts)

        -- reflect target
        condFrame.cond_aura_target_help:SetChecked(th)
        condFrame.cond_aura_target_harm:SetChecked(tm)
        condFrame.cond_aura_onself:SetChecked(ts)

        condFrame.cond_aura_glow:SetChecked((c.aura and c.aura.glow) or false)
        condFrame.cond_aura_greyscale:SetChecked((c.aura and c.aura.greyscale) or false)

        local hasCursive = _HasCursive()
        local isBuff     = (data.type == "Buff")

        -- Row 11: Combo points / class-specific note
        if _IsRogueOrDruid() then
            condFrame.cond_aura_cp_cb:Show()
            if condFrame.cond_aura_class_note then
                condFrame.cond_aura_class_note:Hide()
            end

            local cpOn = (c.aura and c.aura.cpEnabled) and true or false
            condFrame.cond_aura_cp_cb:SetChecked(cpOn)
            if cpOn then
                condFrame.cond_aura_cp_comp:Show()
                condFrame.cond_aura_cp_val:Show()
                condFrame.cond_aura_cp_val_enter:Show()
                local comp = (c.aura and c.aura.cpComp) or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_cp_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_aura_cp_comp)
                _GoldifyDD(condFrame.cond_aura_cp_comp)
                condFrame.cond_aura_cp_val:SetText(tostring((c.aura and c.aura.cpVal) or 0))
            else
                condFrame.cond_aura_cp_comp:Hide()
                condFrame.cond_aura_cp_val:Hide()
                condFrame.cond_aura_cp_val_enter:Hide()
            end
        else
            condFrame.cond_aura_cp_cb:Hide()
            condFrame.cond_aura_cp_comp:Hide()
            condFrame.cond_aura_cp_val:Hide()
            condFrame.cond_aura_cp_val_enter:Hide()
            if condFrame.cond_aura_class_note then
                condFrame.cond_aura_class_note:Show()
            end
        end

        -- Row 8: HP selector (mutually exclusive)
        condFrame.cond_aura_hp_my:Show()
        condFrame.cond_aura_hp_tgt:Show()
        local hpModeA = c.aura and c.aura.hpMode or nil
        condFrame.cond_aura_hp_my:SetChecked(hpModeA == "my")
        condFrame.cond_aura_hp_tgt:SetChecked(hpModeA == "target")
        if hpModeA == "my" or hpModeA == "target" then
            condFrame.cond_aura_hp_comp:Show()
            condFrame.cond_aura_hp_val:Show()
            condFrame.cond_aura_hp_val_enter:Show()
            local comp = (c.aura and c.aura.hpComp) or ""
            UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_hp_comp, comp)
            UIDropDownMenu_SetText(comp, condFrame.cond_aura_hp_comp)
            _GoldifyDD(condFrame.cond_aura_hp_comp)
            condFrame.cond_aura_hp_val:SetText(tostring((c.aura and c.aura.hpVal) or 0))
        else
            condFrame.cond_aura_hp_comp:Hide()
            condFrame.cond_aura_hp_val:Hide()
            condFrame.cond_aura_hp_val_enter:Hide()
        end

        -- Row 7: Aura owner flag ("My Aura" only)
        local onlyMine = (c.aura and c.aura.onlyMine) and true or false

        if amode == "found" then
            condFrame.cond_aura_mine:Show()

            if isBuff then
                -- BUFF: cannot reliably track “My Aura” → always off + grey, new hint
                condFrame.cond_aura_mine:SetChecked(false)
                _disableCheck(condFrame.cond_aura_mine)
                if c.aura then c.aura.onlyMine = nil end

                if condFrame.cond_aura_owner_tip then
                    condFrame.cond_aura_owner_tip:SetText("(not able to track for buffs)")
                    condFrame.cond_aura_owner_tip:Show()
                end

            elseif isSelfOnly then
                -- On Player (self): caster filter is meaningless -> always off & grey.
                condFrame.cond_aura_mine:SetChecked(false)
                _disableCheck(condFrame.cond_aura_mine)
                if c.aura then c.aura.onlyMine = nil end

                if condFrame.cond_aura_owner_tip then
                    condFrame.cond_aura_owner_tip:SetText("(not used for On Player (self) as target)")
                    condFrame.cond_aura_owner_tip:Show()
                end

            else
                -- Help/Harm targets: need Cursive to know who cast the aura
                if hasCursive then
                    _enableCheck(condFrame.cond_aura_mine)
                    condFrame.cond_aura_mine:SetChecked(onlyMine)

                    if condFrame.cond_aura_owner_tip then
                        condFrame.cond_aura_owner_tip:SetText("(require Cursive addon)")
                        condFrame.cond_aura_owner_tip:Hide()
                    end
                else
                    _disableCheck(condFrame.cond_aura_mine)
                    condFrame.cond_aura_mine:SetChecked(false)
                    if c.aura then c.aura.onlyMine = nil end

                    if condFrame.cond_aura_owner_tip then
                        condFrame.cond_aura_owner_tip:SetText("(require Cursive addon)")
                        condFrame.cond_aura_owner_tip:Show()
                    end
                end
            end

        elseif amode == "missing" then
            -- Aura missing: keep row visible but force it off and greyed
            condFrame.cond_aura_mine:Show()
            _disableCheck(condFrame.cond_aura_mine)
            condFrame.cond_aura_mine:SetChecked(false)
            if c.aura then c.aura.onlyMine = nil end
            if condFrame.cond_aura_owner_tip then
                condFrame.cond_aura_owner_tip:Hide()
            end
        else
            condFrame.cond_aura_mine:Hide()
            if condFrame.cond_aura_owner_tip then
                condFrame.cond_aura_owner_tip:Hide()
            end
        end

        -- Row 10: Text flags (Text: stack + Text: remaining)
        if amode == "found" then
            -- === Text: Stack counter ===
            -- Always allowed for any aura we can scan (buff or debuff, any target).
            condFrame.cond_aura_text_stack:Show()
            _enableCheck(condFrame.cond_aura_text_stack)
            condFrame.cond_aura_text_stack:SetChecked((c.aura and c.aura.textStackCounter) or false)

            -- === Text: Time remaining (same rules as before) ===
            condFrame.cond_aura_text_time:Show()

            if isSelfOnly then
                -- On Player (self): user may freely toggle Text: Remaining
                _enableCheck(condFrame.cond_aura_text_time)
                condFrame.cond_aura_text_time:SetChecked((c.aura and c.aura.textTimeRemaining) or false)

            elseif isHelpOrHarm then
                if not hasCursive then
                    -- No Cursive: cannot show a reliable timer
                    _disableCheck(condFrame.cond_aura_text_time)
                    condFrame.cond_aura_text_time:SetChecked(false)
                    if c.aura and c.aura.textTimeRemaining then
                        c.aura.textTimeRemaining = false
                    end
                else
                    if onlyMine then
                        -- My Aura checked -> user controls Text: Remaining
                        _enableCheck(condFrame.cond_aura_text_time)
                        condFrame.cond_aura_text_time:SetChecked((c.aura and c.aura.textTimeRemaining) or false)
                    else
                        -- My Aura NOT checked -> Text: Remaining forced OFF and greyed
                        if c.aura and c.aura.textTimeRemaining then
                            c.aura.textTimeRemaining = false
                        end
                        condFrame.cond_aura_text_time:SetChecked(false)
                        _disableCheck(condFrame.cond_aura_text_time)
                    end
                end
            else
                -- Fallback: disable
                _disableCheck(condFrame.cond_aura_text_time)
                condFrame.cond_aura_text_time:SetChecked(false)
                if c.aura and c.aura.textTimeRemaining then
                    c.aura.textTimeRemaining = false
                end
            end

        elseif amode == "missing" then
            -- Aura missing: keep text options visible but disabled and cleared
            condFrame.cond_aura_text_stack:Show()
            condFrame.cond_aura_text_time:Show()

            _disableCheck(condFrame.cond_aura_text_stack)
            _disableCheck(condFrame.cond_aura_text_time)

            condFrame.cond_aura_text_stack:SetChecked(false)
            condFrame.cond_aura_text_time:SetChecked(false)

            if c.aura then
                c.aura.textStackCounter   = false
                c.aura.textTimeRemaining  = false
            end
        else
            condFrame.cond_aura_text_time:Hide()
            condFrame.cond_aura_text_stack:Hide()
        end

        -- Row 11: Aura Power (like ability)
        condFrame.cond_aura_power:Show()
        local pOn = (c.aura and c.aura.powerEnabled) and true or false
        condFrame.cond_aura_power:SetChecked(pOn)
        if pOn then
            condFrame.cond_aura_power_comp:Show()
            condFrame.cond_aura_power_val:Show()
            condFrame.cond_aura_power_val_enter:Show()
            local comp = (c.aura and c.aura.powerComp) or ""
            UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_power_comp, comp)
            UIDropDownMenu_SetText(comp, condFrame.cond_aura_power_comp)
            _GoldifyDD(condFrame.cond_aura_power_comp)
            condFrame.cond_aura_power_val:SetText(tostring((c.aura and c.aura.powerVal) or 0))
        else
            condFrame.cond_aura_power_comp:Hide()
            condFrame.cond_aura_power_val:Hide()
            condFrame.cond_aura_power_val_enter:Hide()
        end

        -- Form dropdown for aura
        local choices = (function()
            local _, cls = UnitClass("player")
            cls = cls and string.upper(cls) or ""
            return (cls == "WARRIOR" or cls == "ROGUE" or cls == "DRUID" or cls == "PRIEST" or cls == "PALADIN")
        end)()

        if condFrame.cond_ability_formDD then
            condFrame.cond_ability_formDD:Hide()
        end

        if choices and condFrame.cond_aura_formDD then
            condFrame.cond_aura_formDD:Show()
            ClearDropdown(condFrame.cond_aura_formDD)
            InitFormDropdown(condFrame.cond_aura_formDD, data, "aura")
            local v = c.aura and c.aura.form
            if v and v ~= "All" and v ~= "" then
                UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_formDD, v)
                UIDropDownMenu_SetText(v, condFrame.cond_aura_formDD)
                _GoldifyDD(condFrame.cond_aura_formDD)
            else
                UIDropDownMenu_SetText("Select form", condFrame.cond_aura_formDD)
                _GoldifyDD(condFrame.cond_aura_formDD)
            end
        elseif condFrame.cond_aura_formDD then
            condFrame.cond_aura_formDD:Hide()
            ClearDropdown(condFrame.cond_aura_formDD)
        end

        -- Remaining (Row 8): behavior depends on target + "My Aura"
        local aRemEnabled = (c.aura and c.aura.remainingEnabled) and true or false

        if amode == "found" then
            condFrame.cond_aura_remaining_cb:Show()
            if condFrame.cond_aura_remaining_cb.text then
                condFrame.cond_aura_remaining_cb.text:SetText("Remaining")
            end

            if isSelfOnly then
                -- On Player (self): user can freely toggle Remaining, no Cursive required
                _enableCheck(condFrame.cond_aura_remaining_cb)
                condFrame.cond_aura_remaining_cb:SetChecked(aRemEnabled)

            elseif isHelpOrHarm then
                -- Help/Harm target
                if not hasCursive then
                    -- No Cursive: cannot actually time remote auras
                    _disableCheck(condFrame.cond_aura_remaining_cb)
                    condFrame.cond_aura_remaining_cb:SetChecked(false)
                    if c.aura then c.aura.remainingEnabled = false end
                    if condFrame.cond_aura_remaining_cb.text then
                        condFrame.cond_aura_remaining_cb.text:SetText("Remaining (Requires Cursive addon + SuperWoW)")
                    end
                    _hideRemInputs()
                else
                    -- We have Cursive; apply My Aura rules
                    if onlyMine then
                        -- My Aura checked -> user controls Remaining
                        _enableCheck(condFrame.cond_aura_remaining_cb)
                        condFrame.cond_aura_remaining_cb:SetChecked(aRemEnabled)
                    else
                        -- My Aura NOT checked -> Remaining disabled and cleared
                        if c.aura and c.aura.remainingEnabled then
                            c.aura.remainingEnabled = false
                        end
                        aRemEnabled = false
                        condFrame.cond_aura_remaining_cb:SetChecked(false)
                        _disableCheck(condFrame.cond_aura_remaining_cb)
                    end
                end
            else
                -- Fallback: disable
                _disableCheck(condFrame.cond_aura_remaining_cb)
                condFrame.cond_aura_remaining_cb:SetChecked(false)
                if c.aura then c.aura.remainingEnabled = false end
            end

            -- Inputs follow the *final* enabled flag
            local remOn = (c.aura and c.aura.remainingEnabled) and true or false
            if remOn then
                condFrame.cond_aura_remaining_comp:Show()
                condFrame.cond_aura_remaining_val:Show()
                condFrame.cond_aura_remaining_val_enter:Show()
                _enableDD(condFrame.cond_aura_remaining_comp)

                local comp = (c.aura and c.aura.remainingComp) or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_remaining_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_aura_remaining_comp)
                _GoldifyDD(condFrame.cond_aura_remaining_comp)
                condFrame.cond_aura_remaining_val:SetText(tostring((c.aura and c.aura.remainingVal) or 0))
            else
                _hideRemInputs()
            end

        elseif amode == "missing" then
            -- Aura missing: keep Remaining visible but disabled and cleared
            condFrame.cond_aura_remaining_cb:Show()
            if condFrame.cond_aura_remaining_cb.text then
                condFrame.cond_aura_remaining_cb.text:SetText("Remaining")
            end

            _disableCheck(condFrame.cond_aura_remaining_cb)
            condFrame.cond_aura_remaining_cb:SetChecked(false)
            if c.aura then c.aura.remainingEnabled = false end
            _hideRemInputs()
        else
            condFrame.cond_aura_remaining_cb:Hide()
            _hideRemInputs()
        end

        -- Stacks row: enabled only when FOUND, greyed when MISSING
        local aStacksEnabled = (c.aura and c.aura.stacksEnabled) and true or false
        condFrame.cond_aura_stacks_cb:SetChecked(aStacksEnabled)
        if amode == "found" then
            condFrame.cond_aura_stacks_cb:Show()
            _enableCheck(condFrame.cond_aura_stacks_cb)
            if aStacksEnabled then
                condFrame.cond_aura_stacks_comp:Show()
                condFrame.cond_aura_stacks_val:Show()
                condFrame.cond_aura_stacks_val_enter:Show()
                local comp = (c.aura and c.aura.stacksComp) or ""
                UIDropDownMenu_SetSelectedValue(condFrame.cond_aura_stacks_comp, comp)
                UIDropDownMenu_SetText(comp, condFrame.cond_aura_stacks_comp)
                _GoldifyDD(condFrame.cond_aura_stacks_comp)
                condFrame.cond_aura_stacks_val:SetText(tostring((c.aura and c.aura.stacksVal) or 0))
            else
                condFrame.cond_aura_stacks_comp:Hide()
                condFrame.cond_aura_stacks_val:Hide()
                condFrame.cond_aura_stacks_val_enter:Hide()
            end
        else
            -- Aura missing or no mode: show but disabled/cleared for MISSING, hide for nil-mode
            if amode == "missing" then
                condFrame.cond_aura_stacks_cb:Show()
                _disableCheck(condFrame.cond_aura_stacks_cb)
                condFrame.cond_aura_stacks_cb:SetChecked(false)
                if c.aura then
                    c.aura.stacksEnabled = false
                end
            else
                condFrame.cond_aura_stacks_cb:Hide()
            end
            condFrame.cond_aura_stacks_comp:Hide()
            condFrame.cond_aura_stacks_val:Hide()
            condFrame.cond_aura_stacks_val_enter:Hide()
        end

        -- Hide all ability & item controls (unchanged)
        condFrame.cond_ability_usable:Hide()
        condFrame.cond_ability_notcd:Hide()
        condFrame.cond_ability_oncd:Hide()
        condFrame.cond_ability_incombat:Hide()
        condFrame.cond_ability_outcombat:Hide()
        condFrame.cond_ability_target_help:Hide()
        condFrame.cond_ability_target_harm:Hide()
        condFrame.cond_ability_target_self:Hide()
        condFrame.cond_ability_power:Hide()
        condFrame.cond_ability_power_comp:Hide()
        condFrame.cond_ability_power_val:Hide()
        condFrame.cond_ability_power_val_enter:Hide()
        condFrame.cond_ability_glow:Hide()
        condFrame.cond_ability_greyscale:Hide()
        condFrame.cond_ability_slider:Hide()
        condFrame.cond_ability_slider_dir:Hide()
        condFrame.cond_ability_remaining_cb:Hide()
        condFrame.cond_ability_remaining_comp:Hide()
        condFrame.cond_ability_remaining_val:Hide()
        condFrame.cond_ability_remaining_val_enter:Hide()
        if condFrame.cond_ability_text_time then condFrame.cond_ability_text_time:Hide() end

        if condFrame.cond_ability_hp_my then condFrame.cond_ability_hp_my:Hide() end
        if condFrame.cond_ability_hp_tgt then condFrame.cond_ability_hp_tgt:Hide() end
        if condFrame.cond_ability_hp_comp then condFrame.cond_ability_hp_comp:Hide() end
        if condFrame.cond_ability_hp_val then condFrame.cond_ability_hp_val:Hide() end
        if condFrame.cond_ability_hp_val_enter then condFrame.cond_ability_hp_val_enter:Hide() end

        if condFrame.cond_ability_cp_cb then condFrame.cond_ability_cp_cb:Hide() end
        if condFrame.cond_ability_cp_comp then condFrame.cond_ability_cp_comp:Hide() end
        if condFrame.cond_ability_cp_val then condFrame.cond_ability_cp_val:Hide() end
        if condFrame.cond_ability_cp_val_enter then condFrame.cond_ability_cp_val_enter:Hide() end
        if condFrame.cond_ability_class_note then condFrame.cond_ability_class_note:Hide() end

        if condFrame.cond_ability_slider_glow then condFrame.cond_ability_slider_glow:Hide() end
        if condFrame.cond_ability_slider_grey then condFrame.cond_ability_slider_grey:Hide() end

        if condFrame.cond_item_where_equipped then condFrame.cond_item_where_equipped:Hide() end
        if condFrame.cond_item_where_bag then condFrame.cond_item_where_bag:Hide() end
        if condFrame.cond_item_where_missing then condFrame.cond_item_where_missing:Hide() end
        if condFrame.cond_item_notcd then condFrame.cond_item_notcd:Hide() end
        if condFrame.cond_item_oncd then condFrame.cond_item_oncd:Hide() end
        if condFrame.cond_item_incombat then condFrame.cond_item_incombat:Hide() end
        if condFrame.cond_item_outcombat then condFrame.cond_item_outcombat:Hide() end
        if condFrame.cond_item_target_help then condFrame.cond_item_target_help:Hide() end
        if condFrame.cond_item_target_harm then condFrame.cond_item_target_harm:Hide() end
        if condFrame.cond_item_target_self then condFrame.cond_item_target_self:Hide() end
        if condFrame.cond_item_glow then condFrame.cond_item_glow:Hide() end
        if condFrame.cond_item_greyscale then condFrame.cond_item_greyscale:Hide() end
        if condFrame.cond_item_text_time then condFrame.cond_item_text_time:Hide() end
        if condFrame.cond_item_power then condFrame.cond_item_power:Hide() end
        if condFrame.cond_item_power_comp then condFrame.cond_item_power_comp:Hide() end
        if condFrame.cond_item_power_val then condFrame.cond_item_power_val:Hide() end
        if condFrame.cond_item_power_val_enter then condFrame.cond_item_power_val_enter:Hide() end
        if condFrame.cond_item_hp_my then condFrame.cond_item_hp_my:Hide() end
        if condFrame.cond_item_hp_tgt then condFrame.cond_item_hp_tgt:Hide() end
        if condFrame.cond_item_hp_comp then condFrame.cond_item_hp_comp:Hide() end
        if condFrame.cond_item_hp_val then condFrame.cond_item_hp_val:Hide() end
        if condFrame.cond_item_hp_val_enter then condFrame.cond_item_hp_val_enter:Hide() end
        if condFrame.cond_item_remaining_cb then condFrame.cond_item_remaining_cb:Hide() end
        if condFrame.cond_item_remaining_comp then condFrame.cond_item_remaining_comp:Hide() end
        if condFrame.cond_item_remaining_val then condFrame.cond_item_remaining_val:Hide() end
        if condFrame.cond_item_remaining_val_enter then condFrame.cond_item_remaining_val_enter:Hide() end
        if condFrame.cond_item_cp_cb then condFrame.cond_item_cp_cb:Hide() end
        if condFrame.cond_item_cp_comp then condFrame.cond_item_cp_comp:Hide() end
        if condFrame.cond_item_cp_val then condFrame.cond_item_cp_val:Hide() end
        if condFrame.cond_item_cp_val_enter then condFrame.cond_item_cp_val_enter:Hide() end
        if condFrame.cond_item_formDD then condFrame.cond_item_formDD:Hide() end
        if condFrame.cond_item_inv_trinket1 then condFrame.cond_item_inv_trinket1:Hide() end
        if condFrame.cond_item_inv_trinket2 then condFrame.cond_item_inv_trinket2:Hide() end
        if condFrame.cond_item_inv_trinket_first then condFrame.cond_item_inv_trinket_first:Hide() end
        if condFrame.cond_item_inv_trinket_both then condFrame.cond_item_inv_trinket_both:Hide() end
        if condFrame.cond_item_inv_wep_mainhand then condFrame.cond_item_inv_wep_mainhand:Hide() end
        if condFrame.cond_item_inv_wep_offhand then condFrame.cond_item_inv_wep_offhand:Hide() end
        if condFrame.cond_item_inv_wep_ranged then condFrame.cond_item_inv_wep_ranged:Hide() end
        if condFrame.cond_item_class_note then condFrame.cond_item_class_note:Hide() end
    end
	_ReflowCondAreaHeight()
end

----------------------------------------------------------------
-- End Conditions UI section
----------------------------------------------------------------

-- Update frame controls to reflect db for `key`
function UpdateCondFrameForKey(key)
    if not condFrame or not key then return end
    currentKey = key
	_G["DoiteEdit_CurrentKey"] = key
    local data = EnsureDBEntry(key)

    -- hard-separate condition tables every time the editor opens this entry
    if data and data.conditions then
        if data.type == "Ability" then
            data.conditions.ability = data.conditions.ability or {}
            data.conditions.aura    = nil
            data.conditions.item    = nil
        elseif data.type == "Item" then
            data.conditions.item    = data.conditions.item or {}
            data.conditions.ability = nil
            data.conditions.aura    = nil
        else
            data.conditions.aura    = data.conditions.aura or {}
            data.conditions.ability = nil
            data.conditions.item    = nil
        end
    end

    -- Header: colored by type
    local typeColor = "|cffffffff"
    if data.type == "Ability" then
        typeColor = "|cff4da6ff"
    elseif data.type == "Buff" then
        typeColor = "|cff22ff22"
    elseif data.type == "Debuff" then
        typeColor = "|cffff4d4d"
    elseif data.type == "Item" then
        typeColor = "|cffffd000"
    end
    condFrame.header:SetText("Edit: " .. (data.displayName or key) .. " " .. typeColor .. "(" .. (data.type or "") .. ")|r")

    -- Initialize group dropdown contents (pass current data to get 'checked' right)
    if condFrame.groupDD then
        InitGroupDropdown(condFrame.groupDD, data)
        local sel = data.group or "No"
        UIDropDownMenu_SetSelectedValue(condFrame.groupDD, sel)
        UIDropDownMenu_SetText(sel, condFrame.groupDD)
    end

    -- Leader checkbox logic & leader-only controls
    if condFrame.leaderCB then
        if not data.group then
            condFrame.leaderCB:Hide()
            if condFrame.growthDD then condFrame.growthDD:Hide() end
            if condFrame.numAurasLabel then condFrame.numAurasLabel:Hide() end
            if condFrame.numAurasDD then condFrame.numAurasDD:Hide() end
        else
            condFrame.leaderCB:Show()
            local leaders = BuildGroupLeaders()
            local leaderKey = leaders[data.group]
            if not leaderKey then
                data.isLeader = true
                condFrame.leaderCB:SetChecked(true)
                condFrame.leaderCB:Disable()
                if condFrame.growthDD then
                    condFrame.growthDD:Show()
                    InitGrowthDropdown(condFrame.growthDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.growthDD, data.growth or "Horizontal Right")
                    UIDropDownMenu_SetText(data.growth or "Horizontal Right", condFrame.growthDD)
                end
                if condFrame.numAurasLabel and condFrame.numAurasDD then
                    condFrame.numAurasLabel:Show()
                    condFrame.numAurasDD:Show()
                    InitNumAurasDropdown(condFrame.numAurasDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.numAurasDD, data.numAuras or 5)
                    UIDropDownMenu_SetText(tostring(data.numAuras or 5), condFrame.numAurasDD)
                end
            else
                if leaderKey == key then
                    condFrame.leaderCB:SetChecked(true)
                    condFrame.leaderCB:Disable()
                    if condFrame.growthDD then
                        condFrame.growthDD:Show()
                        InitGrowthDropdown(condFrame.growthDD, data)
                        UIDropDownMenu_SetSelectedValue(condFrame.growthDD, data.growth or "Horizontal Right")
                        UIDropDownMenu_SetText(data.growth or "Horizontal Right", condFrame.growthDD)
                    end
                    if condFrame.numAurasLabel and condFrame.numAurasDD then
                        condFrame.numAurasLabel:Show()
                        condFrame.numAurasDD:Show()
                        InitNumAurasDropdown(condFrame.numAurasDD, data)
                        UIDropDownMenu_SetSelectedValue(condFrame.numAurasDD, data.numAuras or 5)
                        UIDropDownMenu_SetText(tostring(data.numAuras or 5), condFrame.numAurasDD)
                    end
                else
                    condFrame.leaderCB:SetChecked(false)
                    condFrame.leaderCB:Enable()
                    if condFrame.growthDD then condFrame.growthDD:Hide() end
                    if condFrame.numAurasLabel then condFrame.numAurasLabel:Hide() end
                    if condFrame.numAurasDD then condFrame.numAurasDD:Hide() end
                end
            end
        end
    end

    -- Update Conditions UI (always visible area between top and POS & SIZE)
    UpdateConditionsUI(data)

    -- Show/hide Position & Size section (only when no group OR leader)
    if (not data.group) or data.isLeader then
        if condFrame.groupTitle3 then condFrame.groupTitle3:Show() end
        if condFrame.sep3 then condFrame.sep3:Show() end
        if condFrame.sliderX then condFrame.sliderX:Show() end
        if condFrame.sliderY then condFrame.sliderY:Show() end
        if condFrame.sliderSize then condFrame.sliderSize:Show() end
        if condFrame.sliderXBox then condFrame.sliderXBox:Show() end
        if condFrame.sliderYBox then condFrame.sliderYBox:Show() end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:Show() end

        -- update slider positions/values (guarded)
        if condFrame.sliderX then condFrame.sliderX:SetValue(data.offsetX or 0) end
        if condFrame.sliderY then condFrame.sliderY:SetValue(data.offsetY or 0) end
        if condFrame.sliderSize then condFrame.sliderSize:SetValue(data.iconSize or 40) end
		_DA_ApplySliderRanges()

        -- update numeric editboxes if present
        if condFrame.sliderXBox then condFrame.sliderXBox:SetText(tostring(math.floor((data.offsetX or 0) + 0.5))) end
        if condFrame.sliderYBox then condFrame.sliderYBox:SetText(tostring(math.floor((data.offsetY or 0) + 0.5))) end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:SetText(tostring(math.floor((data.iconSize or 40) + 0.5))) end
    else
        if condFrame.groupTitle3 then condFrame.groupTitle3:Hide() end
        if condFrame.sep3 then condFrame.sep3:Hide() end
        if condFrame.sliderX then condFrame.sliderX:Hide() end
        if condFrame.sliderY then condFrame.sliderY:Hide() end
        if condFrame.sliderSize then condFrame.sliderSize:Hide() end
        if condFrame.sliderXBox then condFrame.sliderXBox:Hide() end
        if condFrame.sliderYBox then condFrame.sliderYBox:Hide() end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:Hide() end
    end
end

-- show/hide entry point
function DoiteConditions_Show(key)
    -- toggle: if same key and shown -> hide
    if condFrame and condFrame:IsShown() and currentKey == key then
        condFrame:Hide()
        currentKey = nil
        _G["DoiteEdit_CurrentKey"] = nil   -- clear the edit override
        return
    end

    -- create the frame if needed
    if not condFrame then
        condFrame = CreateFrame("Frame", "DoiteConditionsFrame", UIParent)
        condFrame:SetWidth(355)
        condFrame:SetHeight(450)
        if DoiteAurasFrame and DoiteAurasFrame:GetName() then
            condFrame:SetPoint("TOPLEFT", DoiteAurasFrame, "TOPRIGHT", 5, 0)
        else
            condFrame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
        end

        condFrame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 32,
            insets = { left=11, right=12, top=12, bottom=11 }
        })
        condFrame:SetBackdropColor(0,0,0,1)
        condFrame:SetBackdropBorderColor(1,1,1,1)
        condFrame:SetFrameStrata("FULLSCREEN_DIALOG")
		-- When the conditions editor hides by any means, drop the edit override
		condFrame:SetScript("OnHide", function()
			_G["DoiteEdit_CurrentKey"] = nil
			-- kick a repaint so the formerly-forced icon can hide if conditions say so
			if DoiteConditions_RequestEvaluate then
				DoiteConditions_RequestEvaluate()
			end
		end)


		-- === Suspend heavy work while dragging the main DoiteAuras frame; flush on release ===
		if DoiteAurasFrame then
			local _oldDown = DoiteAurasFrame:GetScript("OnMouseDown")
			DoiteAurasFrame:SetScript("OnMouseDown", function(self)
				_G["DoiteUI_Dragging"] = true
				if _oldDown then _oldDown(self) end
			end)

			local _oldUp = DoiteAurasFrame:GetScript("OnMouseUp")
			DoiteAurasFrame:SetScript("OnMouseUp", function(self)
				_G["DoiteUI_Dragging"] = false
				-- ensure one final repaint after dropping the frame
				DoiteEdit_FlushHeavy()
				if _oldUp then _oldUp(self) end
			end)
		end

        condFrame.header = condFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        condFrame.header:SetPoint("TOP", condFrame, "TOP", 0, -15)
        condFrame.header:SetText("Edit:")

        condFrame.groupTitle = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        condFrame.groupTitle:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -40)
        condFrame.groupTitle:SetText("|cff6FA8DCGROUP & LEADER|r")

        local sep = condFrame:CreateTexture(nil, "ARTWORK")
        sep:SetHeight(1)
        sep:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 16, -55)
        sep:SetPoint("TOPRIGHT", condFrame, "TOPRIGHT", -16, -55)
        sep:SetTexture(1,1,1)
        if sep.SetVertexColor then sep:SetVertexColor(1,1,1,0.25) end

        condFrame.groupLabel = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.groupLabel:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -68)
        condFrame.groupLabel:SetText("Group this Aura?")

        condFrame.groupDD = CreateFrame("Frame", "DoiteConditions_GroupDD", condFrame, "UIDropDownMenuTemplate")
        condFrame.groupDD:SetPoint("LEFT", condFrame.groupLabel, "RIGHT", -10, -2)
        if UIDropDownMenu_SetWidth then
            pcall(UIDropDownMenu_SetWidth, 75, condFrame.groupDD)
        end

        condFrame.leaderCB = CreateFrame("CheckButton", nil, condFrame, "UICheckButtonTemplate")
        condFrame.leaderCB:SetWidth(20); condFrame.leaderCB:SetHeight(20)
        condFrame.leaderCB:SetPoint("Left", condFrame.groupDD, "Right", -10, 0)
        condFrame.leaderCB.text = condFrame.leaderCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.leaderCB.text:SetPoint("LEFT", condFrame.leaderCB, "RIGHT", 2, 0)
        condFrame.leaderCB.text:SetText("Aura group leader")
        condFrame.leaderCB:Hide()

        condFrame.growthDD = CreateFrame("Frame", "DoiteConditions_GrowthDD", condFrame, "UIDropDownMenuTemplate")
        condFrame.growthDD:SetPoint("BOTTOMLEFT", condFrame.groupLabel, "BOTTOMLEFT", -18, -43)
        if UIDropDownMenu_SetWidth then
            pcall(UIDropDownMenu_SetWidth, 110, condFrame.growthDD)
        end
        condFrame.growthDD:Hide()

        -- Number of Auras label + dropdown
        condFrame.numAurasLabel = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        condFrame.numAurasLabel:SetPoint("LEFT", condFrame.growthDD, "RIGHT", -5, 2)
        condFrame.numAurasLabel:SetText("Limit of Auras?")
        condFrame.numAurasLabel:Hide()

        condFrame.numAurasDD = CreateFrame("Frame", "DoiteConditions_NumAurasDD", condFrame, "UIDropDownMenuTemplate")
        condFrame.numAurasDD:SetPoint("LEFT", condFrame.numAurasLabel, "RIGHT", -10, -2)
        if UIDropDownMenu_SetWidth then
            pcall(UIDropDownMenu_SetWidth, 75, condFrame.numAurasDD)
        end
        condFrame.numAurasDD:Hide()

        -- leaderCB click behavior
        condFrame.leaderCB:SetScript("OnClick", function(self)
            local cb = self or (condFrame and condFrame.leaderCB)
            if not currentKey then
                if cb then cb:SetChecked(false) end
                return
            end
            local data = DoiteAurasDB.spells[currentKey]
            if not data or not data.group then
                if cb then
                    cb:SetChecked(false)
                    cb:Hide()
                end
                return
            end

            if cb and cb:GetChecked() then
                local leaders = BuildGroupLeaders()
                local prev = leaders[data.group]
                if prev and prev ~= currentKey and DoiteAurasDB.spells[prev] then
                    DoiteAurasDB.spells[prev].isLeader = false
                end
                data.isLeader = true
                cb:SetChecked(true)
                cb:Disable()

                if condFrame.growthDD then
                    condFrame.growthDD:Show()
                    InitGrowthDropdown(condFrame.growthDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.growthDD, data.growth or "Horizontal Right")
                    UIDropDownMenu_SetText(data.growth or "Horizontal Right", condFrame.growthDD)
                end
                if condFrame.numAurasLabel and condFrame.numAurasDD then
                    condFrame.numAurasLabel:Show()
                    condFrame.numAurasDD:Show()
                    InitNumAurasDropdown(condFrame.numAurasDD, data)
                    UIDropDownMenu_SetSelectedValue(condFrame.numAurasDD, data.numAuras or 5)
                    UIDropDownMenu_SetText(tostring(data.numAuras or 5), condFrame.numAurasDD)
                end
            end

            SafeRefresh()
			SafeEvaluate()
            UpdateCondFrameForKey(currentKey)
        end)

        condFrame.groupTitle2 = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        condFrame.groupTitle2:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -125)
        condFrame.groupTitle2:SetText("|cff6FA8DCCONDITIONS & RULES|r")

        local sep2 = condFrame:CreateTexture(nil, "ARTWORK")
        sep2:SetHeight(1)
        sep2:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 16, -140)
        sep2:SetPoint("TOPRIGHT", condFrame, "TOPRIGHT", -16, -140)
        sep2:SetTexture(1,1,1)
        if sep2.SetVertexColor then sep2:SetVertexColor(1,1,1,0.25) end

		-- === Scrollable container for CONDITIONS & RULES (no size/pos changes elsewhere) ===
		-- Create once and reuse; anchors live between the "CONDITIONS & RULES" line and before "POSITION & SIZE"
		if not condFrame.condListContainer then
			local cW = condFrame:GetWidth() - 43  -- leave the same left/right padding as lines
			local cH = 210                         -- fits the current space; contents will scroll as it grows

			local listContainer = CreateFrame("Frame", nil, condFrame)
			listContainer:SetWidth(cW)
			listContainer:SetHeight(cH)
			listContainer:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 14, -143)  -- just below sep2 line
			listContainer:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				tile = true, tileSize = 16, edgeSize = 16
			})
			listContainer:SetBackdropColor(0,0,0,0.7)
			condFrame.condListContainer = listContainer

			local scrollFrame = CreateFrame("ScrollFrame", "DoiteConditionsScroll", listContainer, "UIPanelScrollFrameTemplate")
			scrollFrame:SetWidth(cW - 20)
			scrollFrame:SetHeight(cH - 9)
			scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 12, -5)
			condFrame.condScrollFrame = scrollFrame
			condFrame._scrollFrame    = scrollFrame

			local listContent = CreateFrame("Frame", "DoiteConditionsListContent", scrollFrame)
			listContent:SetWidth(cW - 20)
			listContent:SetHeight(cH - 10)  -- will be increased by controls; scrollFrame will handle overflow
			scrollFrame:SetScrollChild(listContent)
			condFrame._condArea = listContent  -- parent for all condition controls
			
			listContent:SetHeight(900)  -- big enough to cover all rows; tweak if you add more

			-- 2) Make absolutely sure the visual stacking (levels) keeps the backdrop under the controls.
			--    (WoW 1.12 supports FrameLevel; parent/child constraints still apply, but this bumps things correctly.)
			local baseLevel = condFrame:GetFrameLevel() or 1
			listContainer:SetFrameLevel(baseLevel + 0)   -- backdrop holder
			scrollFrame:SetFrameLevel(baseLevel + 1)     -- the scroller itself
			listContent:SetFrameLevel(baseLevel + 2)     -- the actual area where controls live

			-- Optional (helps click/scroll behavior feel solid)
			if scrollFrame.EnableMouseWheel then
				scrollFrame:EnableMouseWheel(true)
			end
		end

        -- Create the Conditions UI section (self-contained)
        CreateConditionsUI()

        condFrame.groupTitle3 = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        condFrame.groupTitle3:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 20, -355)
        condFrame.groupTitle3:SetText("|cff6FA8DCPOSITION & SIZE|r")

        condFrame.sep3 = condFrame:CreateTexture(nil, "ARTWORK")
        condFrame.sep3:SetHeight(1)
        condFrame.sep3:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 16, -370)
        condFrame.sep3:SetPoint("TOPRIGHT", condFrame, "TOPRIGHT", -16, -370)
        condFrame.sep3:SetTexture(1,1,1)
        if condFrame.sep3.SetVertexColor then condFrame.sep3:SetVertexColor(1,1,1,0.25) end

        -- Sliders helper (makes a slider + small EditBox beneath it)
        local function MakeSlider(name, text, x, y, width, minVal, maxVal, step)
            local s = CreateFrame("Slider", name, condFrame, "OptionsSliderTemplate")
            s:SetWidth(width)
            s:SetHeight(16)
            s:SetMinMaxValues(minVal, maxVal)
            s:SetValueStep(step)
            s:SetPoint("TOPLEFT", condFrame, "TOPLEFT", x, y)

            local txt = _G[s:GetName() .. 'Text']
            local low = _G[s:GetName() .. 'Low']
            local high = _G[s:GetName() .. 'High']
            if txt then txt:SetText(text); txt:SetFontObject("GameFontNormalSmall") end
            if low then low:SetText(tostring(minVal)); low:SetFontObject("GameFontNormalSmall") end
            if high then high:SetText(tostring(maxVal)); high:SetFontObject("GameFontNormalSmall") end

            -- tiny EditBox below slider
            local eb = CreateFrame("EditBox", name .. "_EditBox", condFrame, "InputBoxTemplate")
            eb:SetWidth(33); eb:SetHeight(18)
            eb:SetPoint("TOP", s, "BOTTOM", 3, -8)
            eb:SetAutoFocus(false)
            eb:SetText("0")
            eb:SetJustifyH("CENTER")
            eb:SetFontObject("GameFontNormalSmall")
            eb.slider = s
            eb._updating = false

            -- slider -> editbox (robust, avoids recursion)
            s:SetScript("OnValueChanged", function(self, value)
                local frame = self or s
                local v = tonumber(value)
                if not v and frame and frame.GetValue then
                    v = frame:GetValue()
                end
                if not v then return end
                v = math.floor(v + 0.5)
                if eb and eb.SetText and not eb._updating then
                    eb._updating = true
                    eb:SetText(tostring(v))
                    eb._updating = false
                end
                if frame and frame.updateFunc then frame.updateFunc(v) end
            end)

			-- mark “dragging” while the slider is held
			s:SetScript("OnMouseDown", function()
				_G["DoiteUI_Dragging"] = true
			end)

			-- on release: stop pausing and do a single heavy repaint
			s:SetScript("OnMouseUp", function()
				_G["DoiteUI_Dragging"] = false
				DoiteEdit_FlushHeavy()  -- single combined refresh/evaluate
			end)

            -- editbox commit helper (clamp + set slider)
            local function CommitEditBox(box)
                if not box or not box.slider then return end
                local sref = box.slider
                local txt = box:GetText()
                local val = tonumber(txt)
                if not val then
                    -- revert to slider's current rounded value
                    local cur = math.floor((sref:GetValue() or 0) + 0.5)
                    box:SetText(tostring(cur))
                else
                    if val < minVal then val = minVal end
                    if val > maxVal then val = maxVal end
                    -- set value on slider; OnValueChanged will handle DB update via updateFunc
                    box._updating = true
                    sref:SetValue(val)
                    box._updating = false
                end
            end

            -- editbox -> slider while typing (WoW 1.12 has no userInput arg)
			eb:SetScript("OnTextChanged", function()
				if this._updating then return end
				local txt = this:GetText()
				local num = tonumber(txt)
				if not num then return end

				-- clamp to slider bounds captured in MakeSlider
				if num < minVal then num = minVal end
				if num > maxVal then num = maxVal end

				-- drive the slider; its OnValueChanged will push to DB via updateFunc(...)
				this._updating = true
				this.slider:SetValue(num)
				this._updating = false
			end)

            eb:SetScript("OnEnterPressed", function(self)
                CommitEditBox(self)
                if self and self.ClearFocus then self:ClearFocus() end
            end)
			
			eb:SetScript("OnEscapePressed", function()
				if this.ClearFocus then this:ClearFocus() end
				-- also restore the current slider value visually
				local cur = math.floor((this.slider:GetValue() or 0) + 0.5)
				this._updating = true
				this:SetText(tostring(cur))
				this._updating = false
			end)

            eb:SetScript("OnEditFocusLost", function()
                CommitEditBox(this)
            end)

            return s, eb
        end

        -- slider widths (leave left margin + spacing)
        local totalAvailable = condFrame:GetWidth() - 60
        local sliderWidth = math.floor((totalAvailable - 20) / 3)
        if sliderWidth < 100 then sliderWidth = 100 end

        local baseX = 20
        local baseY = -390
        local gap = 8

        do
			local minX, maxX, minY, maxY, minSize, maxSize = _DA_ComputePosSizeRanges()

			condFrame.sliderX,   condFrame.sliderXBox    = MakeSlider("DoiteConditions_SliderX",   "Horizontal Position", baseX,                        baseY, sliderWidth, minX,   maxX,   1)
			condFrame.sliderY,   condFrame.sliderYBox    = MakeSlider("DoiteConditions_SliderY",   "Vertical Position",   baseX + sliderWidth + gap,   baseY, sliderWidth, minY,   maxY,   1)
			condFrame.sliderSize,condFrame.sliderSizeBox = MakeSlider("DoiteConditions_SliderSize","Icon Size",           baseX + 2*(sliderWidth+gap), baseY, sliderWidth, minSize, maxSize, 1)
		end


        -- update functions that the slider will call when changed
        condFrame.sliderX.updateFunc = function(value)
			if not currentKey then return end
			local d = EnsureDBEntry(currentKey)
			d.offsetX = value
			DoiteEdit_QueueHeavy()
		end
		condFrame.sliderY.updateFunc = function(value)
			if not currentKey then return end
			local d = EnsureDBEntry(currentKey)
			d.offsetY = value
			DoiteEdit_QueueHeavy()
		end
		condFrame.sliderSize.updateFunc = function(value)
			if not currentKey then return end
			local d = EnsureDBEntry(currentKey)
			d.iconSize = value
			DoiteEdit_QueueHeavy()
		end
		
		-- Keep slider ranges in sync with current resolution/UI scale every time the panel shows
        condFrame:SetScript("OnShow", function(self)
            _DA_ApplySliderRanges()
        end)

        -- Initially hidden position section
        if condFrame.groupTitle3 then condFrame.groupTitle3:Hide() end
        if condFrame.sep3 then condFrame.sep3:Hide() end
        if condFrame.sliderX then condFrame.sliderX:Hide() end
        if condFrame.sliderY then condFrame.sliderY:Hide() end
        if condFrame.sliderSize then condFrame.sliderSize:Hide() end
        if condFrame.sliderXBox then condFrame.sliderXBox:Hide() end
        if condFrame.sliderYBox then condFrame.sliderYBox:Hide() end
        if condFrame.sliderSizeBox then condFrame.sliderSizeBox:Hide() end

        -- When the main DoiteAuras frame hides, hide the cond frame too
        if DoiteAurasFrame then
            local oldHide = DoiteAurasFrame:GetScript("OnHide")
            DoiteAurasFrame:SetScript("OnHide", function(self)
                if condFrame then condFrame:Hide() end
                if oldHide then oldHide(self) end
            end)
        end
    end

    condFrame:Show()
    UpdateCondFrameForKey(key)
end
