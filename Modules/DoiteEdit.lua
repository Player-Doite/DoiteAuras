---------------------------------------------------------------
-- DoiteEdit.lua
-- Secondary frame for editing Aura conditions / edit UI
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

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

-- Icon-level category UI helpers (assigned later from CreateConditionsUI)
local Category_RefreshDropdown = nil
local Category_UpdateButtonState = nil
local Category_AddFromUI = nil
local Category_RemoveSelected = nil


local AuraCond_Managers = {}
local AuraCond_RegisterManager
local AuraCond_RefreshFromDB
local AuraCond_ResetEditing

-- class gate used by UpdateConditionsUI and others
local function _IsRogueOrDruid()
    local _, c = UnitClass("player")
    c = c and string.upper(c) or ""
    return (c == "ROGUE" or c == "DRUID")
end

----------------------------------------------------------------
-- Nampower version guard (needed for Aura owner tracking) Requires Nampower 2.15.1+
----------------------------------------------------------------
local _NP_REQ_MAJOR, _NP_REQ_MINOR, _NP_REQ_PATCH = 2, 15, 1

local function _NP_GetVersion()
    if type(GetNampowerVersion) == "function" then
        local a, b, c = GetNampowerVersion()
        return (tonumber(a) or 0), (tonumber(b) or 0), (tonumber(c) or 0), true
    end
    return 0, 0, 0, false
end

local function _NP_VersionString(maj, min, pat, hasFn)
    if not hasFn then
        return "unknown"
    end
    return tostring(maj) .. "." .. tostring(min) .. "." .. tostring(pat)
end

-- returns: ok(bool), verStr(string), maj, min, pat
local function _NP_AtLeast(reqMaj, reqMin, reqPat)
    local maj, min, pat, hasFn = _NP_GetVersion()
    local verStr = _NP_VersionString(maj, min, pat, hasFn)

    if not hasFn then
        return false, verStr, maj, min, pat
    end

    if maj > reqMaj then return true, verStr, maj, min, pat end
    if maj < reqMaj then return false, verStr, maj, min, pat end

    -- maj equal
    if min > reqMin then return true, verStr, maj, min, pat end
    if min < reqMin then return false, verStr, maj, min, pat end

    -- min equal
    if pat >= reqPat then return true, verStr, maj, min, pat end
    return false, verStr, maj, min, pat
end

-- === Lightweight throttle for heavy UI work (prevents lag while dragging sliders) ===
local _DoiteEdit_PendingHeavy = false
local _DoiteEdit_Accum = 0
local _DoiteEdit_Throttle = CreateFrame("Frame", "DoiteEditThrottle")

-- Global flag toggled while the main Edit or Main frames are being dragged
_G["DoiteUI_Dragging"] = _G["DoiteUI_Dragging"] or false

-- Internal immediate heavy helpers (never called directly from UI; only from the throttle)
local function _DoiteEdit_ImmediateRefresh()
    if DoiteAuras_RefreshList then DoiteAuras_RefreshList() end
    if DoiteAuras_RefreshIcons then DoiteAuras_RefreshIcons() end
end

local function _DoiteEdit_ImmediateEvaluate()
    if DoiteConditions_RequestEvaluate then
        DoiteConditions_RequestEvaluate()
    elseif DoiteConditions and DoiteConditions.EvaluateAll then
        DoiteConditions:EvaluateAll()
    end
end

local function DoiteEdit_QueueHeavy()
    _DoiteEdit_PendingHeavy = true
end

local function DoiteEdit_FlushHeavy()
    if not _DoiteEdit_PendingHeavy then return end
    _DoiteEdit_PendingHeavy = false
    _DoiteEdit_Accum = 0

    -- One combined heavy pass, batched behind the throttle
    _DoiteEdit_ImmediateRefresh()
    _DoiteEdit_ImmediateEvaluate()
end

_DoiteEdit_Throttle:SetScript("OnUpdate", function()
    if not _DoiteEdit_PendingHeavy then return end
    if _G["DoiteUI_Dragging"] then return end  -- defer while the user is dragging frames
    _DoiteEdit_Accum = _DoiteEdit_Accum + (arg1 or 0)
    if _DoiteEdit_Accum >= 0.05 then           -- ~20 fps cap for heavy work while sliding
        DoiteEdit_FlushHeavy()
    end
end)

local function EnsureDBEntry(key)
    -- Ensure global categories table exists (shared across all icons)
    if DoiteAurasDB and not DoiteAurasDB.categories then
        DoiteAurasDB.categories = {}
    end

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

        if d.conditions.ability.targetDistance == nil then d.conditions.ability.targetDistance = nil end
        if d.conditions.ability.targetUnitType  == nil then d.conditions.ability.targetUnitType  = nil end
		if d.conditions.ability.weaponFilter == nil then d.conditions.ability.weaponFilter = nil end

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

        if ic.targetDistance == nil then ic.targetDistance = nil end
        if ic.targetUnitType  == nil then ic.targetUnitType  = nil end
		if ic.weaponFilter == nil then ic.weaponFilter = nil end

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
        if d.conditions.aura.targetSelf  == nil then d.conditions.aura.targetSelf  = true    end
        if d.conditions.aura.targetHelp  == nil then d.conditions.aura.targetHelp  = false   end
        if d.conditions.aura.targetHarm  == nil then d.conditions.aura.targetHarm  = false   end
        if d.conditions.aura.form        == nil then d.conditions.aura.form        = "All"   end

        if d.conditions.aura.targetDistance == nil then d.conditions.aura.targetDistance = nil end
        if d.conditions.aura.targetUnitType  == nil then d.conditions.aura.targetUnitType  = nil end
		if d.conditions.aura.weaponFilter == nil then d.conditions.aura.weaponFilter = nil end

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
    DoiteEdit_QueueHeavy()
end

SafeRefresh = function()
    DoiteEdit_QueueHeavy()
end

-- === Dynamic bounds for Position & Size sliders (based on UIParent) ===
local function _DA_GetParentDims()
    local w = (UIParent and UIParent.GetWidth and UIParent:GetWidth()) or (GetScreenWidth and GetScreenWidth()) or 1024
    local h = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or (GetScreenHeight and GetScreenHeight()) or 768
    return w, h
end

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

                -- Queue the normal batched refresh/evaluate
                SafeRefresh()
				SafeEvaluate()

                -- if /da is open, force an immediate list refresh so the icon visibly moves to the selected group right away (no reopen needed).
                if DoiteAurasFrame and DoiteAurasFrame.IsShown and DoiteAurasFrame:IsShown() then
                    if DoiteAuras_RefreshList then
                        pcall(DoiteAuras_RefreshList)
                    end
                end
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

-- Unified Weapon/Fighting-style dropdown (class-specific: Warrior / Paladin / Shaman)
local function InitWeaponDropdown(dd, data, condType)
    if not dd then return end
    condType = condType or "ability"

    local thisKey = currentKey
    if not thisKey then
        ClearDropdown(dd)
        return
    end

    -- Detect player class
    local _, class = UnitClass("player")
    class = class and string.upper(class) or ""

    -- Options by class
    local choices
    if class == "WARRIOR" then
        choices = { "Any", "Two-Hand", "Shield", "Dual-Wield" }
    elseif class == "PALADIN" or class == "SHAMAN" then
        choices = { "Any", "Two-Hand", "Shield" }
    else
        -- Not supported: just hide the dropdown
        dd:Hide()
        return
    end

    ClearDropdown(dd)

    UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
        for _, val in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text  = val
            info.value = val
            local pickedVal = val

            info.func = function(button)
                local picked = (button and button.value) or pickedVal
                if not currentKey then return end

                -- Update widget
                UIDropDownMenu_SetSelectedValue(dd, picked)
                UIDropDownMenu_SetText(picked, dd)
                _GoldifyDD(dd)

                -- Persist into the correct conditions table
                local d = EnsureDBEntry(currentKey)
                d.conditions = d.conditions or {}

                if condType == "ability" then
                    d.conditions.ability = d.conditions.ability or {}
                    d.conditions.ability.weaponFilter = picked
                elseif condType == "aura" then
                    d.conditions.aura = d.conditions.aura or {}
                    d.conditions.aura.weaponFilter = picked
                elseif condType == "item" then
                    d.conditions.item = d.conditions.item or {}
                    d.conditions.item.weaponFilter = picked
                end

                SafeRefresh(); SafeEvaluate()
                if UpdateCondFrameForKey then
                    UpdateCondFrameForKey(currentKey)
                end
                if CloseDropDownMenus then
                    CloseDropDownMenus()
                end
            end

            local saved
            if data and data.conditions and data.conditions[condType] then
                saved = data.conditions[condType].weaponFilter
            end
            info.checked = (saved == val)

            UIDropDownMenu_AddButton(info)
        end
    end)

    -- Initial visible state: saved value, or neutral "Equipped" placeholder
    local saved
    if data and data.conditions and data.conditions[condType] then
        saved = data.conditions[condType].weaponFilter
    end

    if saved then
        if UIDropDownMenu_SetSelectedValue then
            pcall(UIDropDownMenu_SetSelectedValue, dd, saved)
        end
        if UIDropDownMenu_SetText then
            pcall(UIDropDownMenu_SetText, saved, dd)
        end
        _GoldifyDD(dd)
    else
        if UIDropDownMenu_SetSelectedValue then
            pcall(UIDropDownMenu_SetSelectedValue, dd, nil)
        end
        if UIDropDownMenu_SetText then
            -- "Equipped" = default/neutral state
            pcall(UIDropDownMenu_SetText, "Equipped", dd)
        end
        _GoldifyDD(dd)
    end

    dd._initializedForKey  = thisKey
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
function _GoldifyDD(dd)
    if not dd or not dd.GetName then return end
    local name = dd:GetName()
    if not name then return end
    local txt = _G[name .. "Text"]
    if txt and txt.SetTextColor then txt:SetTextColor(1, 0.82, 0) end
end

function _GreyifyDD(dd)
    if not dd or not dd.GetName then return end
    local name = dd:GetName()
    local txt = _G[name .. "Text"]
    if txt and txt.SetTextColor then txt:SetTextColor(0.6, 0.6, 0.6) end
end

function _WhiteifyDDText(dd)
    if not dd or not dd.GetName then return end
    local name = dd:GetName()
    if not name then return end
    local txt = _G[name .. "Text"]
    if txt and txt.SetTextColor then
        txt:SetTextColor(1, 1, 1)
    end
end

-- Only touch the text / placeholder when DISABLING.
local function _SetDDEnabled(dd, enabled, placeholderText)
	if not dd or not dd.GetName then return end
	local name = dd:GetName()
	local btn  = name and _G[name .. "Button"]

	if enabled then
		-- Enable button and keep whatever text _RestoreDD (or Init*) put there.
		if btn and btn.Enable then btn:Enable() end
		_GoldifyDD(dd)
	else
		-- Disable and show the neutral placeholder.
		if btn and btn.Disable then btn:Disable() end
		if UIDropDownMenu_ClearAll then
			pcall(UIDropDownMenu_ClearAll, dd)
		end
		if placeholderText and UIDropDownMenu_SetText then
			UIDropDownMenu_SetText(placeholderText, dd)
		end
		_GreyifyDD(dd)
	end
end

-- Pretty-print helper: announce when entering edit for an icon
local lastAnnouncedKey = nil

-- Pretty-print helper: announce when entering edit for an icon
local function DoiteEdit_AnnounceEditingIcon(displayName)
    -- Only announce once per icon per edit session
    if currentKey and lastAnnouncedKey == currentKey then
        return
    end
    lastAnnouncedKey = currentKey

    if not displayName or displayName == "" then
        displayName = "Unknown"
    end

    local prefix = "|cff4da6ffDoiteAuras:|r "
    local name   = "|cffffff00" .. tostring(displayName) .. "|r"

    local msg = prefix ..
        "During edit for " .. name ..
        ", this icon will stay visible and be pinned at the top of its dynamic group (if any) for convenience."

    DEFAULT_CHAT_FRAME:AddMessage(msg)
end


-- Local copy of the TitleCase helper used by DoiteAuras (for pretty printing aura names)
-- Special-cases Roman numerals (II, IV, VI, VIII, X, etc.) so they stay fully uppercase.
local function AuraCond_TitleCase(str)
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
        -- Keep it conservative: ranks are usually short
        if string.len(upper) > 4 then
            return false
        end
        return true
    end

    local result, first = "", true
    local word
    for word in string.gfind(str, "%S+") do
        local startsParen = (string.sub(word, 1, 1) == "(")
        local leading     = startsParen and "(" or ""
        local core        = startsParen and string.sub(word, 2) or word

        local lowerCore = string.lower(core or "")
        local upperCore = string.upper(core or "")
        local c         = string.sub(core or "", 1, 1) or ""
        local rest      = string.sub(core or "", 2) or ""

        -- 1) Roman numerals: keep them fully uppercase
        if IsRomanNumeralToken(core) then
            result = result .. leading .. upperCore .. " "
            first = false
        else
            -- 2) Normal title-case rules
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
    end

    result = string.gsub(result, "%s+$", "")
    return result
end

-- Small helper: trim leading/trailing whitespace
local function _TrimCategoryText(str)
    if not str then return "" end
    return (string.gsub(str, "^%s*(.-)%s*$", "%1"))
end

-- Global category list helper (stored in DoiteAurasDB.categories)
local function _GetCategoryList()
    if not DoiteAurasDB then
        return {}
    end
    DoiteAurasDB.categories = DoiteAurasDB.categories or {}
    return DoiteAurasDB.categories
end

----------------------------------------------------------------
-- Conditions UI creation & wiring
----------------------------------------------------------------
local function CreateConditionsUI()
    if not condFrame then return end
    if condFrame._conditionsUIBuilt then return end
    condFrame._conditionsUIBuilt = true

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

    -- Normalize any extended type keys (eg. "item_trinket", "item_weapon") to their base buckets.
    local function _NormalizeSepTypeKey(typeKey)
        if not typeKey then return nil end
        if typeKey == "ability" or typeKey == "aura" or typeKey == "item" then
            return typeKey
        end

        local lower = string.lower(tostring(typeKey))

        -- Map anything that *contains* these substrings back to the base key.
        -- e.g. "item_trinket_slots" -> "item"
        if string.find(lower, "ability", 1, true) then
            return "ability"
        elseif string.find(lower, "aura", 1, true) then
            return "aura"
        elseif string.find(lower, "item", 1, true) then
            return "item"
        end

        return nil
    end

    -- typeKey = "ability" | "aura" | "item" (or extended forms like "item_trinket"); slot = 1..20
    SetSeparator = function(typeKey, slot, title, showLine, isVisible)
        typeKey = _NormalizeSepTypeKey(typeKey)
        if not typeKey then return end
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
        -- Map any extended keys ("item_trinket", "item_weapon", etc.) onto base buckets.
        typeKey = _NormalizeSepTypeKey(typeKey)
        if not typeKey then
            -- Unknown type: don't touch anything
            return
        end

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
	condFrame.cond_ability_usable = MakeCheck("DoiteCond_Ability_Usable", "Usable", 0, row1_y)
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
	
	-- TARGET STATUS
    condFrame.cond_ability_target_alive = MakeCheck("DoiteCond_Ability_TargetAlive", "Alive", 0, row4_y)
    condFrame.cond_ability_target_dead  = MakeCheck("DoiteCond_Ability_TargetDead",  "Dead",  70, row4_y)
	SetSeparator("ability", 4, "TARGET STATUS", true, true)

    condFrame.cond_ability_glow = MakeCheck("DoiteCond_Ability_Glow", "Glow", 0, row5_y)
    condFrame.cond_ability_greyscale = MakeCheck("DoiteCond_Ability_Greyscale", "Grey", 70, row5_y)
    condFrame.cond_ability_slider_glow = MakeCheck("DoiteCond_Ability_SliderGlow", "CD Glow", 140, row5_y)
    condFrame.cond_ability_slider_grey = MakeCheck("DoiteCond_Ability_SliderGrey", "CD Grey", 220, row5_y)
    SetSeparator("ability", 5, "VISUAL EFFECTS", true, true)

    -- ABILITY ROW: TARGET DISTANCE & TYPE
    SetSeparator("ability", 6, "TARGET DISTANCE & TYPE", true, true)

    condFrame.cond_ability_distanceDD = CreateFrame("Frame", "DoiteCond_Ability_DistanceDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_ability_distanceDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", -15, row6_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 100, condFrame.cond_ability_distanceDD) end

    condFrame.cond_ability_unitTypeDD = CreateFrame("Frame", "DoiteCond_Ability_UnitTypeDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_ability_unitTypeDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 120, row6_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 100, condFrame.cond_ability_unitTypeDD) end

    condFrame.cond_ability_slider = MakeCheck("DoiteCond_Ability_Slider", "Soon off CD indicator", 0, row7_y)
    condFrame.cond_ability_slider_dir = CreateFrame("Frame", "DoiteCond_Ability_SliderDir", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_ability_slider_dir:SetPoint("LEFT", condFrame.cond_ability_slider, "RIGHT", 110, -3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 60, condFrame.cond_ability_slider_dir) end
    condFrame.cond_ability_remaining_cb   = MakeCheck("DoiteCond_Ability_RemainingCB", "Remaining", 0, row7_y)
    condFrame.cond_ability_remaining_comp = MakeComparatorDD("DoiteCond_Ability_RemComp", 65, row7_y+3, 50)
    condFrame.cond_ability_remaining_val  = MakeSmallEdit("DoiteCond_Ability_RemVal", 160, row7_y-2, 40)
    condFrame.cond_ability_remaining_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_remaining_val_enter:SetPoint("LEFT", condFrame.cond_ability_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_ability_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_ability_remaining_val_enter:Hide()
    SetSeparator("ability", 7, "REMAINING TIME", true, true)

    condFrame.cond_ability_power = MakeCheck("DoiteCond_Ability_PowerCB", "Power", 0, row8_y)
    condFrame.cond_ability_power_comp = MakeComparatorDD("DoiteCond_Ability_PowerComp", 65, row8_y+3, 50)
    condFrame.cond_ability_power_val  = MakeSmallEdit("DoiteCond_Ability_PowerVal", 160, row8_y-2, 40)
    condFrame.cond_ability_power_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_power_val_enter:SetPoint("LEFT", condFrame.cond_ability_power_val, "RIGHT", 4, 0)
    condFrame.cond_ability_power_val_enter:SetText("(%)")
    condFrame.cond_ability_power_val_enter:Hide()
    SetSeparator("ability", 8, "RESOURCE", true, true)

    condFrame.cond_ability_hp_my   = MakeCheck("DoiteCond_Ability_HP_My", "My HP", 0, row9_y)
    condFrame.cond_ability_hp_tgt  = MakeCheck("DoiteCond_Ability_HP_Tgt", "Target HP", 65, row9_y)
    condFrame.cond_ability_hp_comp = MakeComparatorDD("DoiteCond_Ability_HP_Comp", 130, row9_y+3, 50)
    condFrame.cond_ability_hp_val  = MakeSmallEdit("DoiteCond_Ability_HP_Val", 225, row9_y-2, 40)
    condFrame.cond_ability_hp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_hp_val_enter:SetPoint("LEFT", condFrame.cond_ability_hp_val, "RIGHT", 4, 0)
    condFrame.cond_ability_hp_val_enter:SetText("(%)")
    condFrame.cond_ability_hp_comp:Hide()
    condFrame.cond_ability_hp_val:Hide()
    condFrame.cond_ability_hp_val_enter:Hide()
    SetSeparator("ability", 9, "HEALTH CONDITION", true, true)

    condFrame.cond_ability_text_time = MakeCheck("DoiteCond_Ability_TextTime", "Icon text: Remaining", 0, row10_y)
    SetSeparator("ability", 10, "ICON TEXT", true, true)

	-- Combo points dropdown (class-specific: druid / rogue)
    condFrame.cond_ability_cp_cb   = MakeCheck("DoiteCond_Ability_CP_CB", "Combo points", 0, row11_y)
    condFrame.cond_ability_cp_comp = MakeComparatorDD("DoiteCond_Ability_CP_Comp", 85, row11_y+3, 50)
    condFrame.cond_ability_cp_val  = MakeSmallEdit("DoiteCond_Ability_CP_Val", 180, row11_y-2, 40)
    condFrame.cond_ability_cp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_cp_val_enter:SetPoint("LEFT", condFrame.cond_ability_cp_val, "RIGHT", 4, 0)
    condFrame.cond_ability_cp_val_enter:SetText("(#)")
    condFrame.cond_ability_cp_val_enter:Hide()
    SetSeparator("ability", 11, "CLASS-SPECIFIC", true, true)

    -- Ability: class-specific weapon / fighting-style dropdown (Shaman / Warrior / Paladin)
    condFrame.cond_ability_weaponDD = CreateFrame("Frame", "DoiteCond_Ability_WeaponDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_ability_weaponDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", -15, row11_y+3)
    if UIDropDownMenu_SetWidth then
        pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_ability_weaponDD)
    end
    condFrame.cond_ability_weaponDD:Hide()
    ClearDropdown(condFrame.cond_ability_weaponDD)

    -- Ability: class-specific note for classes without combo points
    condFrame.cond_ability_class_note = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_ability_class_note:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 0, row11_y)
    condFrame.cond_ability_class_note:SetTextColor(1, 0.82, 0)
    condFrame.cond_ability_class_note:SetText("No class-specific option added for your class.")
    condFrame.cond_ability_class_note:Hide()
	
	-- Ability: dynamic Aura Conditions section
    local abilityAuraBaseY = row12_y
    SetSeparator("ability", 12, "ABILITY, BUFF, DEBUFF & TALENT CONDITIONS", true, true)
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
	
	-- TARGET STATUS
    condFrame.cond_aura_target_alive = MakeCheck("DoiteCond_Aura_TargetAlive", "Alive", 0, row4_y)
    condFrame.cond_aura_target_dead  = MakeCheck("DoiteCond_Aura_TargetDead",  "Dead",  70, row4_y)
	SetSeparator("aura", 4, "TARGET STATUS", true, true)

    condFrame.cond_aura_glow = MakeCheck("DoiteCond_Aura_Glow", "Glow", 0, row5_y)
    condFrame.cond_aura_greyscale = MakeCheck("DoiteCond_Aura_Greyscale", "Grey", 70, row5_y)	
    SetSeparator("aura", 5, "VISUAL EFFECTS", true, true)

    -- AURA ROW: TARGET DISTANCE & TYPE
    SetSeparator("aura", 6, "TARGET DISTANCE & TYPE", true, true)

    condFrame.cond_aura_distanceDD = CreateFrame("Frame", "DoiteCond_Aura_DistanceDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_aura_distanceDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", -15, row6_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 100, condFrame.cond_aura_distanceDD) end

    condFrame.cond_aura_unitTypeDD = CreateFrame("Frame", "DoiteCond_Aura_UnitTypeDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_aura_unitTypeDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 120, row6_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 100, condFrame.cond_aura_unitTypeDD) end

    condFrame.cond_aura_power = MakeCheck("DoiteCond_Aura_PowerCB", "Power", 0, row7_y)
    condFrame.cond_aura_power_comp = MakeComparatorDD("DoiteCond_Aura_PowerComp", 65, row7_y+3, 50)
    condFrame.cond_aura_power_val  = MakeSmallEdit("DoiteCond_Aura_PowerVal", 160, row7_y-2, 40)
    condFrame.cond_aura_power_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_power_val_enter:SetPoint("LEFT", condFrame.cond_aura_power_val, "RIGHT", 4, 0)
    condFrame.cond_aura_power_val_enter:SetText("(%)")
    condFrame.cond_aura_power_comp:Hide()
    condFrame.cond_aura_power_val:Hide()
    condFrame.cond_aura_power_val_enter:Hide()
    SetSeparator("aura", 7, "RESOURCE", true, true)
	
    condFrame.cond_aura_hp_my   = MakeCheck("DoiteCond_Aura_HP_My", "My HP", 0, row8_y)
    condFrame.cond_aura_hp_tgt  = MakeCheck("DoiteCond_Aura_HP_Tgt", "Target HP", 65, row8_y)
    condFrame.cond_aura_hp_comp = MakeComparatorDD("DoiteCond_Aura_HP_Comp", 130, row8_y+3, 50)
    condFrame.cond_aura_hp_val  = MakeSmallEdit("DoiteCond_Aura_HP_Val", 225, row8_y-2, 40)
    condFrame.cond_aura_hp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_hp_val_enter:SetPoint("LEFT", condFrame.cond_aura_hp_val, "RIGHT", 4, 0)
    condFrame.cond_aura_hp_val_enter:SetText("(%)")
    condFrame.cond_aura_hp_comp:Hide()
    condFrame.cond_aura_hp_val:Hide()
    condFrame.cond_aura_hp_val_enter:Hide()	
    SetSeparator("aura", 8, "HEALTH CONDITION", true, true)

    -- Aura owner
    condFrame.cond_aura_mine   = MakeCheck("DoiteCond_Aura_MyAura",      "My Aura",     0,  row9_y)
    condFrame.cond_aura_others = MakeCheck("DoiteCond_Aura_OthersAura",  "Others Aura", 75, row9_y)
	condFrame.cond_aura_owner_tip = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_owner_tip:SetPoint("LEFT", condFrame.cond_aura_others, "RIGHT", 70, -3)
    -- Keep the original text as the default; swapped dynamically for old Nampower versions
	condFrame._aura_owner_tip_default = condFrame._aura_owner_tip_default
		or "'Remaining' can only be used for a 'My Aura' on 'Target (Help/Harm)'"
	condFrame.cond_aura_owner_tip:SetText(condFrame._aura_owner_tip_default)
	condFrame.cond_aura_owner_tip:SetWidth(120)
    condFrame.cond_aura_owner_tip:SetTextColor(1, 0.82, 0)
    condFrame.cond_aura_owner_tip:Hide()

    SetSeparator("aura", 9, "AURA OWNER", true, true)
	
	-- Time remaining & stacks
	condFrame.cond_aura_remaining_cb   = MakeCheck("DoiteCond_Aura_RemCB", "Remaining", 0, row10_y)
    condFrame.cond_aura_remaining_comp = MakeComparatorDD("DoiteCond_Aura_RemComp", 65, row10_y+3, 50)
    condFrame.cond_aura_remaining_val  = MakeSmallEdit("DoiteCond_Aura_RemVal", 160, row10_y-2, 40)
    condFrame.cond_aura_remaining_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_remaining_val_enter:SetPoint("LEFT", condFrame.cond_aura_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_aura_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_aura_remaining_val_enter:Hide()

	condFrame.cond_aura_stacks_cb   = MakeCheck("DoiteCond_Aura_StacksCB", "Stacks", 0, srow11_y)
    condFrame.cond_aura_stacks_comp = MakeComparatorDD("DoiteCond_Aura_StacksComp", 65, srow11_y+3, 50)
    condFrame.cond_aura_stacks_val  = MakeSmallEdit("DoiteCond_Aura_StacksVal", 160, srow11_y-2, 40)
    condFrame.cond_aura_stacks_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_stacks_val_enter:SetPoint("LEFT", condFrame.cond_aura_stacks_val, "RIGHT", 4, 0)
    condFrame.cond_aura_stacks_val_enter:SetText("(#)")
    condFrame.cond_aura_stacks_val_enter:Hide()

    condFrame.cond_aura_text_time  = MakeCheck("DoiteCond_Aura_TextTime",  "Icon text: Remaining",  0,   row11_y-11)
    condFrame.cond_aura_text_stack = MakeCheck("DoiteCond_Aura_TextStack", "Icon text: Stacks", 150,   row11_y-11)
	SetSeparator("aura", 10, "TIME REMAINING & STACKS", true, true)
	
    -- Class-specific (combo points)

    local auraClassRowY = row12_y - 10

    condFrame.cond_aura_cp_cb   = MakeCheck("DoiteCond_Aura_CP_CB", "Combo points", 0, auraClassRowY)
    condFrame.cond_aura_cp_comp = MakeComparatorDD("DoiteCond_Aura_CP_Comp", 85, auraClassRowY+3, 50)
    condFrame.cond_aura_cp_val  = MakeSmallEdit("DoiteCond_Aura_CP_Val", 180, auraClassRowY-2, 40)
    condFrame.cond_aura_cp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_cp_val_enter:SetPoint("LEFT", condFrame.cond_aura_cp_val, "RIGHT", 4, 0)
    condFrame.cond_aura_cp_val_enter:SetText("(#)")
    condFrame.cond_aura_cp_val_enter:Hide()

    local sepAuraClass = SetSeparator("aura", 12, "CLASS-SPECIFIC", true, true)
    if sepAuraClass and srows then
        local newY = (srows[12] or 0) - 10  -- original slot-10 Y minus 10
        sepAuraClass:ClearAllPoints()
        sepAuraClass:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, newY)
        sepAuraClass:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, newY)
    end

    -- Aura: class-specific weapon / fighting-style dropdown (Shaman / Warrior / Paladin)
    condFrame.cond_aura_weaponDD = CreateFrame("Frame", "DoiteCond_Aura_WeaponDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_aura_weaponDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", -15, auraClassRowY+3)
    if UIDropDownMenu_SetWidth then
        pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_aura_weaponDD)
    end
    condFrame.cond_aura_weaponDD:Hide()
    ClearDropdown(condFrame.cond_aura_weaponDD)	

    -- Aura: class-specific note for classes without combo points
    condFrame.cond_aura_class_note = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_aura_class_note:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 0, auraClassRowY)
    condFrame.cond_aura_class_note:SetTextColor(1, 0.82, 0)
    condFrame.cond_aura_class_note:SetText("No class-specific option added for your class.")
    condFrame.cond_aura_class_note:Hide()
	
    local sepAuraBuff = SetSeparator("aura", 13, "ABILITY, BUFF, DEBUFF & TALENT CONDITIONS", true, true)
    if sepAuraBuff and srows then
        local newY = (srows[13] or 0) - 10
        sepAuraBuff:ClearAllPoints()
        sepAuraBuff:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, newY)
        sepAuraBuff:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, newY)
    end
	
	-- Aura (Buff/Debuff): dynamic Aura Conditions section
    local auraAuraBaseY = row13_y - 10
    condFrame.auraAuraAnchor = CreateFrame("Frame", nil, _Parent())
    condFrame.auraAuraAnchor:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, auraAuraBaseY)
    condFrame.auraAuraAnchor:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, auraAuraBaseY)
    condFrame.auraAuraAnchor:SetHeight(20)

    --------------------------------------------------
    -- Item rows
    --------------------------------------------------
    -- WHEREABOUTS / INVENTORY SLOT (special items)
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

    -- USABILITY & COOLDOWN (no "Usable")
    condFrame.cond_item_notcd = MakeCheck("DoiteCond_Item_NotCD", "Not on cooldown", 0, row2_y)
    condFrame.cond_item_oncd  = MakeCheck("DoiteCond_Item_OnCD",  "On cooldown",     150, row2_y)
    SetSeparator("item", 2, "USABILITY & COOLDOWN", true, true)

    -- COMBAT STATE
    condFrame.cond_item_incombat  = MakeCheck("DoiteCond_Item_InCombat",  "In combat",      0, row3_y)
    condFrame.cond_item_outcombat = MakeCheck("DoiteCond_Item_OutCombat", "Out of combat", 80, row3_y)
    SetSeparator("item", 3, "COMBAT STATE", true, true)

    -- TARGET CONDITIONS
    condFrame.cond_item_target_help = MakeCheck("DoiteCond_Item_TargetHelp", "Target (help)", 0, row4_y)
    condFrame.cond_item_target_harm = MakeCheck("DoiteCond_Item_TargetHarm", "Target (harm)", 95, row4_y)
    condFrame.cond_item_target_self = MakeCheck("DoiteCond_Item_TargetSelf", "Target (self)", 200, row4_y)
    SetSeparator("item", 4, "TARGET CONDITIONS", true, true)
	
	-- TARGET STATUS (Item) – use row5_y so it sits near Visual Effects row for items
    condFrame.cond_item_target_alive = MakeCheck("DoiteCond_Item_TargetAlive", "Alive", 0, row5_y)
    condFrame.cond_item_target_dead  = MakeCheck("DoiteCond_Item_TargetDead",  "Dead",  70, row5_y)
	SetSeparator("item", 5, "TARGET STATUS", true, true)

    -- VISUAL EFFECTS
    condFrame.cond_item_glow       = MakeCheck("DoiteCond_Item_Glow",      "Glow", 0,  row6_y)
    condFrame.cond_item_greyscale  = MakeCheck("DoiteCond_Item_Greyscale", "Grey", 70, row6_y)
    condFrame.cond_item_text_time  = MakeCheck("DoiteCond_Item_TextTime",  "Icon text: Remaining", 140, row6_y)
    SetSeparator("item", 6, "VISUAL EFFECTS", true, true)

    -- ITEM ROW: TARGET DISTANCE & TYPE
    SetSeparator("item", 7, "TARGET DISTANCE & TYPE", true, true)

    condFrame.cond_item_distanceDD = CreateFrame("Frame", "DoiteCond_Item_DistanceDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_item_distanceDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", -15, row7_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 100, condFrame.cond_item_distanceDD) end

    condFrame.cond_item_unitTypeDD = CreateFrame("Frame", "DoiteCond_Item_UnitTypeDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_item_unitTypeDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 120, row7_y+3)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 100, condFrame.cond_item_unitTypeDD) end

    -- STACKS (Item)
	condFrame.cond_item_text_stack = MakeCheck("DoiteCond_Item_TextStack", "Icon text", 0, row8_y)
    condFrame.cond_item_stacks_cb   = MakeCheck("DoiteCond_Item_StacksCB", "Stacks", 80, row8_y)
    condFrame.cond_item_stacks_comp = MakeComparatorDD("DoiteCond_Item_StacksComp", 130, row8_y+3, 50)
    condFrame.cond_item_stacks_val  = MakeSmallEdit("DoiteCond_Item_StacksVal", 225, row8_y-2, 40)
    condFrame.cond_item_stacks_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_stacks_val_enter:SetPoint("LEFT", condFrame.cond_item_stacks_val, "RIGHT", 4, 0)
    condFrame.cond_item_stacks_val_enter:SetText("(#)")
    condFrame.cond_item_stacks_val_enter:Hide()
    SetSeparator("item", 8, "STACKS", true, true)

    -- RESOURCE (Power)
    condFrame.cond_item_power      = MakeCheck("DoiteCond_Item_PowerCB", "Power", 0, row9_y)
    condFrame.cond_item_power_comp = MakeComparatorDD("DoiteCond_Item_PowerComp", 65, row9_y+3, 50)
    condFrame.cond_item_power_val  = MakeSmallEdit("DoiteCond_Item_PowerVal", 160, row9_y-2, 40)
    condFrame.cond_item_power_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_power_val_enter:SetPoint("LEFT", condFrame.cond_item_power_val, "RIGHT", 4, 0)
    condFrame.cond_item_power_val_enter:SetText("(%)")
    condFrame.cond_item_power_comp:Hide()
    condFrame.cond_item_power_val:Hide()
    condFrame.cond_item_power_val_enter:Hide()
    SetSeparator("item", 9, "RESOURCE", true, true)


    -- HEALTH CONDITION
    condFrame.cond_item_hp_my   = MakeCheck("DoiteCond_Item_HP_My",  "My HP",     0, row10_y)
    condFrame.cond_item_hp_tgt  = MakeCheck("DoiteCond_Item_HP_Tgt", "Target HP", 65, row10_y)
    condFrame.cond_item_hp_comp = MakeComparatorDD("DoiteCond_Item_HP_Comp", 130, row10_y+3, 50)
    condFrame.cond_item_hp_val  = MakeSmallEdit("DoiteCond_Item_HP_Val", 225, row10_y-2, 40)
    condFrame.cond_item_hp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_hp_val_enter:SetPoint("LEFT", condFrame.cond_item_hp_val, "RIGHT", 4, 0)
    condFrame.cond_item_hp_val_enter:SetText("(%)")
    condFrame.cond_item_hp_comp:Hide()
    condFrame.cond_item_hp_val:Hide()
    condFrame.cond_item_hp_val_enter:Hide()
    SetSeparator("item", 10, "HEALTH CONDITION", true, true)

    -- REMAINING TIME (no slider)
    condFrame.cond_item_remaining_cb   = MakeCheck("DoiteCond_Item_RemCB", "Remaining", 0, row11_y)
    condFrame.cond_item_remaining_comp = MakeComparatorDD("DoiteCond_Item_RemComp", 80, row11_y+3, 50)
    condFrame.cond_item_remaining_val  = MakeSmallEdit("DoiteCond_Item_RemVal", 175, row11_y-2, 40)
    condFrame.cond_item_remaining_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_remaining_val_enter:SetPoint("LEFT", condFrame.cond_item_remaining_val, "RIGHT", 4, 0)
    condFrame.cond_item_remaining_val_enter:SetText("(sec.)")
    condFrame.cond_item_remaining_comp:Hide()
    condFrame.cond_item_remaining_val:Hide()
    condFrame.cond_item_remaining_val_enter:Hide()
    SetSeparator("item", 11, "REMAINING TIME", true, true)

    -- CLASS-SPECIFIC (Combo points)
    condFrame.cond_item_cp_cb   = MakeCheck("DoiteCond_Item_CP_CB", "Combo points", 0, row12_y)
    condFrame.cond_item_cp_comp = MakeComparatorDD("DoiteCond_Item_CP_Comp", 85, row12_y+3, 50)
    condFrame.cond_item_cp_val  = MakeSmallEdit("DoiteCond_Item_CP_Val", 180, row12_y-2, 40)
    condFrame.cond_item_cp_val_enter = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_cp_val_enter:SetPoint("LEFT", condFrame.cond_item_cp_val, "RIGHT", 4, 0)
    condFrame.cond_item_cp_val_enter:SetText("(#)")
    condFrame.cond_item_cp_val_enter:Hide()
    SetSeparator("item", 12, "CLASS-SPECIFIC", true, true)

    -- Item: class-specific weapon / fighting-style dropdown (Shaman / Warrior / Paladin)
    condFrame.cond_item_weaponDD = CreateFrame("Frame", "DoiteCond_Item_WeaponDD", _Parent(), "UIDropDownMenuTemplate")
    condFrame.cond_item_weaponDD:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", -15, row12_y+3)
    if UIDropDownMenu_SetWidth then
        pcall(UIDropDownMenu_SetWidth, 90, condFrame.cond_item_weaponDD)
    end
    condFrame.cond_item_weaponDD:Hide()
    ClearDropdown(condFrame.cond_item_weaponDD)

    -- Item: class-specific note for classes without combo points
    condFrame.cond_item_class_note = _Parent():CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.cond_item_class_note:SetPoint("TOPLEFT", _Parent(), "TOPLEFT", 0, row12_y)
    condFrame.cond_item_class_note:SetTextColor(1, 0.82, 0)
    condFrame.cond_item_class_note:SetText("No class-specific option added for your class.")
    condFrame.cond_item_class_note:Hide()
	
	-- Item: dynamic Aura Conditions section
    local itemAuraBaseY = row13_y
    SetSeparator("item", 13, "ABILITY, BUFF, DEBUFF & TALENT CONDITIONS", true, true)
    condFrame.itemAuraAnchor = CreateFrame("Frame", nil, _Parent())
    condFrame.itemAuraAnchor:SetPoint("TOPLEFT",  _Parent(), "TOPLEFT",  0, itemAuraBaseY)
    condFrame.itemAuraAnchor:SetPoint("TOPRIGHT", _Parent(), "TOPRIGHT", 0, itemAuraBaseY)
    condFrame.itemAuraAnchor:SetHeight(20)

    ----------------------------------------------------------------
    -- Icon categories (shared across all types)
    ----------------------------------------------------------------
    -- Checkbox: "Categorize (eg. Boss debuffs)"
    condFrame.categoryCheck = CreateFrame("CheckButton", "DoiteCond_Category_Check", condFrame, "UICheckButtonTemplate")
    condFrame.categoryCheck:SetWidth(20); condFrame.categoryCheck:SetHeight(20)
    condFrame.categoryCheck:SetPoint("Left", condFrame.groupDD, "Right", -10, 0)
    condFrame.categoryCheck.text = condFrame.categoryCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.categoryCheck.text:SetPoint("LEFT", condFrame.categoryCheck, "RIGHT", 4, 0)
    condFrame.categoryCheck.text:SetText("Categorize")
    condFrame.categoryCheck.text:SetTextColor(1, 0.82, 0) -- yellow small text

    condFrame.categoryInput = CreateFrame("EditBox", "DoiteCond_Category_Input", condFrame, "InputBoxTemplate")
    condFrame.categoryInput:SetAutoFocus(false)
    condFrame.categoryInput:SetHeight(18)
    condFrame.categoryInput:SetWidth(75)
    condFrame.categoryInput:SetPoint("BOTTOMLEFT", condFrame.groupLabel, "BOTTOMLEFT", 0, -32)
    condFrame.categoryInput:SetFontObject("GameFontNormalSmall")
    condFrame.categoryInput:SetJustifyH("LEFT")
	if condFrame.categoryInput.SetTextColor then
        condFrame.categoryInput:SetTextColor(1, 1, 1)
    end

    -- Add/Remove button ("<-Add" / "Remove->")
    condFrame.categoryButton = CreateFrame("Button", "DoiteCond_Category_Button", condFrame, "UIPanelButtonTemplate")
    condFrame.categoryButton:SetWidth(70)
    condFrame.categoryButton:SetHeight(18)
    condFrame.categoryButton:SetPoint("LEFT", condFrame.categoryInput, "RIGHT", 4, 0)
    condFrame.categoryButton:SetText("<-Add")

    -- "Categories:" label (yellow small text)
    condFrame.categoryLabel = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.categoryLabel:SetPoint("LEFT", condFrame.categoryButton, "RIGHT", 8, 0)
    condFrame.categoryLabel:SetText("Categories:")
    condFrame.categoryLabel:SetTextColor(1, 0.82, 0)

    -- Dropdown listing all global categories
    condFrame.categoryDD = CreateFrame("Frame", "DoiteCond_Category_Dropdown", condFrame, "UIDropDownMenuTemplate")
    condFrame.categoryDD:SetPoint("LEFT", condFrame.categoryLabel, "RIGHT", -10, -4)
    if UIDropDownMenu_SetWidth then pcall(UIDropDownMenu_SetWidth, 75, condFrame.categoryDD) end

    -- Helpers for button text & dropdown refresh (assigned to upvalues so UpdateConditionsUI can call them)
    Category_UpdateButtonState = function()
        if not condFrame or not condFrame.categoryButton or not condFrame.categoryInput or not condFrame.categoryDD then return end
        local txt = _TrimCategoryText(condFrame.categoryInput:GetText() or "")
        local hasText = (txt ~= "")

        local selected = nil
        if UIDropDownMenu_GetSelectedValue and condFrame.categoryDD then
            selected = UIDropDownMenu_GetSelectedValue(condFrame.categoryDD)
        end

        -- If there is text, always offer "<-Add".
        -- If no text but a category is selected, offer "Remove->".
        if hasText or not selected then
            condFrame.categoryButton:SetText("<-Add")
        else
            condFrame.categoryButton:SetText("Remove->")
        end
    end

    Category_RefreshDropdown = function(selectedName)
        if not condFrame or not condFrame.categoryDD then return end
        local dd   = condFrame.categoryDD
        local list = _GetCategoryList()

        ClearDropdown(dd)

        -- Robust "any entries?" check that doesn't rely on table.getn semantics
        local hasAny = false
        if list then
            local i = 1
            while list[i] ~= nil do
                hasAny = true
                break
            end
        end

        if not hasAny then
            -- No categories yet: show "(Empty)" and grey text, but DO NOT disable the button.
            -- Keeping the button enabled avoids the "stuck disabled" state after adding
            -- categories again in the same session.
            UIDropDownMenu_Initialize(dd, function() end)

            if UIDropDownMenu_SetSelectedValue then
                pcall(UIDropDownMenu_SetSelectedValue, dd, nil)
            end
            if UIDropDownMenu_SetText then
                pcall(UIDropDownMenu_SetText, "(Empty)", dd)
            end

            _GreyifyDD(dd)

            -- NOTE: deliberately do NOT disable the button here.
            -- local btn = _G[dd:GetName().."Button"]
            -- if btn and btn.Disable then btn:Disable() end

            Category_UpdateButtonState()
            return
        end

        -- Categories: build the real menu
        UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
            local info
            for _, name in ipairs(list) do
                info = {}
                info.text  = name
                info.value = name
                local pickedName = name

                info.func = function(button)
                    if not currentKey then return end
                    local picked = (button and button.value) or pickedName
                    local d = EnsureDBEntry(currentKey)
                    d.category = picked

                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, dd, picked)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, picked, dd)
                    end
                    _WhiteifyDDText(dd)
                    Category_UpdateButtonState()
                    SafeRefresh(); SafeEvaluate()
                end

                local d    = (currentKey and DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[currentKey]) or nil
                local dcat = d and d.category
                if selectedName and selectedName == name then
                    info.checked = true
                else
                    info.checked = (dcat == name)
                end

                UIDropDownMenu_AddButton(info)
            end
        end)

        -- Ensure button is enabled again now that have entries
        local btn = _G[dd:GetName().."Button"]
        if btn and btn.Enable then
            btn:Enable()
        end
        _WhiteifyDDText(dd)

        -- Pick selection: passed-in, or this icon's current category, or "Select"
        local d      = (currentKey and DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[currentKey]) or nil
        local chosen = selectedName or (d and d.category)

        if chosen then
            if UIDropDownMenu_SetSelectedValue then
                pcall(UIDropDownMenu_SetSelectedValue, dd, chosen)
            end
            if UIDropDownMenu_SetText then
                pcall(UIDropDownMenu_SetText, chosen, dd)
            end
        else
            if UIDropDownMenu_SetSelectedValue then
                pcall(UIDropDownMenu_SetSelectedValue, dd, nil)
            end
            if UIDropDownMenu_SetText then
                pcall(UIDropDownMenu_SetText, "Select", dd)
            end
        end
		_WhiteifyDDText(dd)
        Category_UpdateButtonState()
    end

    Category_AddFromUI = function()
        if not currentKey or not condFrame or not condFrame.categoryInput then return end
        local raw = _TrimCategoryText(condFrame.categoryInput:GetText() or "")
        if raw == "" then
            return
        end

        -- Always store and present categories in TitleCase
        local pretty = AuraCond_TitleCase(raw)
        local list   = _GetCategoryList()

        local i, n   = 1, table.getn(list)
        local found  = false
        while i <= n do
            if list[i] == pretty then
                found = true
                break
            end
            i = i + 1
        end
        if not found then
            list[n+1] = pretty
        end

        local d = EnsureDBEntry(currentKey)
        d.category = pretty

        condFrame.categoryInput:SetText("")

        -- Make sure "Categorize" is on and the widgets are visible
        if condFrame.categoryCheck then
            condFrame.categoryCheck:Show()
            condFrame.categoryCheck:SetChecked(true)
        end
        if condFrame.categoryInput  then condFrame.categoryInput:Show()  end
        if condFrame.categoryButton then condFrame.categoryButton:Show() end
        if condFrame.categoryLabel  then condFrame.categoryLabel:Show()  end
        if condFrame.categoryDD     then condFrame.categoryDD:Show()     end

        if Category_RefreshDropdown then
            Category_RefreshDropdown(pretty)
        end
        if Category_UpdateButtonState then
            Category_UpdateButtonState()
        end

        SafeRefresh(); SafeEvaluate()
        if UpdateCondFrameForKey then
            UpdateCondFrameForKey(currentKey)
        end
    end

    -- Confirmation popup for removing a category
    local categoryConfirmFrame, categoryConfirmBG, categoryConfirmBox
    local categoryConfirmTitle, categoryConfirmDesc
    local categoryConfirmYes, categoryConfirmNo
    local categoryPendingRemoveName
    local Category_DoRemove

    local function Category_EnsureConfirmFrame()
        if categoryConfirmFrame then return end

		categoryConfirmFrame = CreateFrame("Frame", "DoiteCond_CategoryConfirmFrame", UIParent)

		-- Make absolutely sure it's on top of everything
		if categoryConfirmFrame.SetFrameStrata then
			categoryConfirmFrame:SetFrameStrata("TOOLTIP")
		end
		if UIParent and UIParent.GetFrameLevel and categoryConfirmFrame.SetFrameLevel then
			local lvl = UIParent:GetFrameLevel() or 0
			categoryConfirmFrame:SetFrameLevel(lvl + 1000)
		end

		categoryConfirmFrame:SetAllPoints(UIParent)
		categoryConfirmFrame:Hide()


        -- Make Esc close this popup
        if UISpecialFrames then
            table.insert(UISpecialFrames, "DoiteCond_CategoryConfirmFrame")
        end

        -- Dark fullscreen background
        categoryConfirmBG = categoryConfirmFrame:CreateTexture(nil, "BACKGROUND")
        categoryConfirmBG:SetAllPoints(categoryConfirmFrame)
        categoryConfirmBG:SetTexture(0, 0, 0, 0.75)

        -- Center dialog box
        categoryConfirmBox = CreateFrame("Frame", nil, categoryConfirmFrame)
        categoryConfirmBox:SetWidth(400)
        categoryConfirmBox:SetHeight(120)
        categoryConfirmBox:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

		-- ensure the box itself is above the dark background
		if categoryConfirmFrame.GetFrameLevel and categoryConfirmBox.SetFrameLevel then
			categoryConfirmBox:SetFrameLevel(categoryConfirmFrame:GetFrameLevel() + 1)
		end

        local boxBG = categoryConfirmBox:CreateTexture(nil, "BACKGROUND")
        boxBG:SetAllPoints(categoryConfirmBox)
        boxBG:SetTexture(0, 0, 0, 0.9)

        -- Title: "Are you sure?"
        categoryConfirmTitle = categoryConfirmBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        categoryConfirmTitle:SetPoint("TOP", categoryConfirmBox, "TOP", 0, -16)
        categoryConfirmTitle:SetText("Are you sure?")

        -- Description text (centered, wraps)
        categoryConfirmDesc = categoryConfirmBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        categoryConfirmDesc:SetPoint("TOP", categoryConfirmTitle, "BOTTOM", 0, -10)
        categoryConfirmDesc:SetWidth(360)
        categoryConfirmDesc:SetJustifyH("CENTER")

        -- Yes button
        categoryConfirmYes = CreateFrame("Button", nil, categoryConfirmBox, "UIPanelButtonTemplate")
        categoryConfirmYes:SetWidth(80)
        categoryConfirmYes:SetHeight(22)
        categoryConfirmYes:SetText("Yes")
        categoryConfirmYes:SetPoint("BOTTOMRIGHT", categoryConfirmBox, "BOTTOM", -10, 15)

        -- No button
        categoryConfirmNo = CreateFrame("Button", nil, categoryConfirmBox, "UIPanelButtonTemplate")
        categoryConfirmNo:SetWidth(80)
        categoryConfirmNo:SetHeight(22)
        categoryConfirmNo:SetText("No")
        categoryConfirmNo:SetPoint("BOTTOMLEFT", categoryConfirmBox, "BOTTOM", 10, 15)

        categoryConfirmNo:SetScript("OnClick", function()
            categoryPendingRemoveName = nil
            categoryConfirmFrame:Hide()
        end)

        categoryConfirmYes:SetScript("OnClick", function()
            if categoryPendingRemoveName then
                Category_DoRemove(categoryPendingRemoveName)
            end
            categoryPendingRemoveName = nil
            categoryConfirmFrame:Hide()
        end)
    end

    -- Worker that actually removes the given category from DB + UI
    Category_DoRemove = function(selected)
        if not currentKey or not condFrame or not condFrame.categoryDD then return end
        if not selected or selected == "" then
            return
        end

        local list = _GetCategoryList()
        local n = table.getn(list)
        if n > 0 then
            local i = 1
            while i <= n do
                if list[i] == selected then
                    table.remove(list, i)
                    n = n - 1
                else
                    i = i + 1
                end
            end
        end

        -- Remove this category from all icons that had it
        if DoiteAurasDB and DoiteAurasDB.spells then
            for key, spell in pairs(DoiteAurasDB.spells) do
                if spell and spell.category == selected then
                    spell.category = nil
                end
            end
        end

        local d = EnsureDBEntry(currentKey)
        if d.category == selected then
            d.category = nil
        end

        condFrame.categoryInput:SetText("")
        Category_RefreshDropdown(nil)
        Category_UpdateButtonState()
        SafeRefresh(); SafeEvaluate()
        if UpdateCondFrameForKey then
            UpdateCondFrameForKey(currentKey)
        end
    end

    -- Public entry point: called when "Remove->" is pressed
    Category_RemoveSelected = function()
        if not currentKey or not condFrame or not condFrame.categoryDD then return end
        local dd = condFrame.categoryDD
        local selected = nil
        if UIDropDownMenu_GetSelectedValue then
            selected = UIDropDownMenu_GetSelectedValue(dd)
        end
        if not selected or selected == "" then
            return
        end

        Category_EnsureConfirmFrame()
        categoryPendingRemoveName = selected

        local msg = "You are about to remove a category - " .. selected .. "."
                  .. "\nAll icons in this category will be uncategorized if you proceed."
                  .. "\nDo you wish to proceed?"
        categoryConfirmDesc:SetText(msg)

        categoryConfirmFrame:Show()
    end

    -- Wiring for category widgets
condFrame.categoryCheck:SetScript("OnClick", function()
    if not currentKey then
        this:SetChecked(false)
        return
    end
    local d = EnsureDBEntry(currentKey)
    local checked = this:GetChecked()

    if checked then
        -- Show controls; category itself is chosen via dropdown
        condFrame.categoryInput:Show()
        condFrame.categoryButton:Show()
        condFrame.categoryLabel:Show()
        condFrame.categoryDD:Show()
        Category_RefreshDropdown(d.category)
    else
        -- Uncategorize this icon
        d.category = nil
        condFrame.categoryInput:Hide()
        condFrame.categoryButton:Hide()
        condFrame.categoryLabel:Hide()
        condFrame.categoryDD:Hide()
        condFrame.categoryInput:SetText("")
        Category_RefreshDropdown(nil)
    end

    Category_UpdateButtonState()
    SafeRefresh(); SafeEvaluate()

    if UpdateCondFrameForKey and not checked then
        UpdateCondFrameForKey(currentKey)
    end
end)

    condFrame.categoryInput:SetScript("OnTextChanged", function()
        Category_UpdateButtonState()
    end)

    condFrame.categoryInput:SetScript("OnEnterPressed", function()
        Category_AddFromUI()
        if this and this.ClearFocus then this:ClearFocus() end
    end)

    condFrame.categoryButton:SetScript("OnClick", function()
        if not currentKey then return end
        local txt = _TrimCategoryText(condFrame.categoryInput:GetText() or "")
        local selected = nil
        if UIDropDownMenu_GetSelectedValue and condFrame.categoryDD then
            selected = UIDropDownMenu_GetSelectedValue(condFrame.categoryDD)
        end

        if txt ~= "" then
            -- Always treat non-empty text as an add action
            Category_AddFromUI()
        elseif selected then
            -- No text but a selection: remove it everywhere
            Category_RemoveSelected()
        else
            -- No-op: no text and nothing selected
        end
    end)

    -- Start hidden; UpdateConditionsUI will manage visibility based on group state
    condFrame.categoryCheck:Hide()
    condFrame.categoryInput:Hide()
    condFrame.categoryButton:Hide()
    condFrame.categoryLabel:Hide()
    condFrame.categoryDD:Hide()

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
	condFrame.cond_ability_usable:SetScript("OnClick", function()
		if this:GetChecked() then
			condFrame.cond_ability_notcd:SetChecked(false)
			condFrame.cond_ability_oncd:SetChecked(false)
			SetExclusiveAbilityMode("usable")
		else
			SetExclusiveAbilityMode(nil)
		end
	end)

	condFrame.cond_ability_notcd:SetScript("OnClick", function()
		if this:GetChecked() then
			condFrame.cond_ability_usable:SetChecked(false)
			condFrame.cond_ability_oncd:SetChecked(false)
			SetExclusiveAbilityMode("notcd")
		else
			SetExclusiveAbilityMode(nil)
		end
	end)

	condFrame.cond_ability_oncd:SetScript("OnClick", function()
		if this:GetChecked() then
			condFrame.cond_ability_usable:SetChecked(false)
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

    -- Ability target row (multi-select) + target status row
    local function SaveAbilityTargetsFromUI()
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.ability = d.conditions.ability or {}

        local ca = d.conditions.ability

        ca.targetHelp  = condFrame.cond_ability_target_help:GetChecked() and true or false
        ca.targetHarm  = condFrame.cond_ability_target_harm:GetChecked() and true or false
        ca.targetSelf  = condFrame.cond_ability_target_self:GetChecked() and true or false
        ca.targetAlive = condFrame.cond_ability_target_alive:GetChecked() and true or false
        ca.targetDead  = condFrame.cond_ability_target_dead:GetChecked()  and true or false
    end

	condFrame.cond_ability_target_alive:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end

        if this:GetChecked() then
            -- turn off Dead when Alive is ticked
            condFrame.cond_ability_target_dead:SetChecked(false)
        end

        SaveAbilityTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

    condFrame.cond_ability_target_dead:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end

        if this:GetChecked() then
            -- turn off Alive when Dead is ticked
            condFrame.cond_ability_target_alive:SetChecked(false)
        end

        SaveAbilityTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

	condFrame.cond_ability_target_help:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
		-- Make sure Target Distance & Type DDs re-evaluate lock state
		UpdateCondFrameForKey(currentKey)
	end)

	condFrame.cond_ability_target_harm:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
		-- Make sure Target Distance & Type DDs re-evaluate lock state
		UpdateCondFrameForKey(currentKey)
	end)

	condFrame.cond_ability_target_self:SetScript("OnClick", function()
		if not currentKey then this:SetChecked(false) return end
		SaveAbilityTargetsFromUI()
		SafeRefresh(); SafeEvaluate()
		-- Make sure Target Distance & Type DDs re-evaluate lock state
		UpdateCondFrameForKey(currentKey)
	end)

    -- Item target row (same logic as abilities)
    local function SaveItemTargetsFromUI()
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions.item = d.conditions.item or {}
		
		local ca = d.conditions.item
		
        ca.targetHelp = condFrame.cond_item_target_help:GetChecked() and true or false
        ca.targetHarm = condFrame.cond_item_target_harm:GetChecked() and true or false
        ca.targetSelf = condFrame.cond_item_target_self:GetChecked() and true or false
		ca.targetAlive = condFrame.cond_item_target_alive:GetChecked() and true or false
        ca.targetDead  = condFrame.cond_item_target_dead:GetChecked()  and true or false
    end

	condFrame.cond_item_target_alive:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then
            condFrame.cond_item_target_dead:SetChecked(false)
        end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

    condFrame.cond_item_target_dead:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then
            condFrame.cond_item_target_alive:SetChecked(false)
        end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
    end)

    condFrame.cond_item_target_help:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
        -- Re-evaluate Target Distance & Type DD lock state for item
        UpdateCondFrameForKey(currentKey)
    end)

    condFrame.cond_item_target_harm:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
        -- Re-evaluate Target Distance & Type DD lock state for item
        UpdateCondFrameForKey(currentKey)
    end)

    condFrame.cond_item_target_self:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        SaveItemTargetsFromUI()
        SafeRefresh(); SafeEvaluate()
        -- Re-evaluate Target Distance & Type DD lock state for item
        UpdateCondFrameForKey(currentKey)
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
	
    function UpdateItemStacksForMissing()
        if not condFrame or not condFrame.cond_item_where_missing then
            return
        end

        local ms = condFrame.cond_item_where_missing:GetChecked()

        local function _setCheckState(cb, enabled, clearWhenDisabling)
            if not cb then return end
            if enabled then
                cb:Enable()
                if cb.text and cb.text.SetTextColor then
                    cb.text:SetTextColor(1, 0.82, 0)
                end
            else
                if clearWhenDisabling and cb.SetChecked then
                    cb:SetChecked(false)
                end
                cb:Disable()
                if cb.text and cb.text.SetTextColor then
                    cb.text:SetTextColor(0.6, 0.6, 0.6)
                end
            end
        end

		-- keep DB in sync with programmatic UI changes
		if currentKey then
			local d = EnsureDBEntry(currentKey)
			d.conditions = d.conditions or {}
			d.conditions.item = d.conditions.item or {}

			local stacksOn = (condFrame.cond_item_stacks_cb and condFrame.cond_item_stacks_cb.GetChecked
							  and condFrame.cond_item_stacks_cb:GetChecked()) and true or false
			local textOn   = (condFrame.cond_item_text_stack and condFrame.cond_item_text_stack.GetChecked
							  and condFrame.cond_item_text_stack:GetChecked()) and true or false

			d.conditions.item.stacksEnabled      = stacksOn or false
			d.conditions.item.textStackCounter   = textOn   or false
		end
    end

    condFrame.cond_item_where_equipped:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceItemWhereabouts(this)
        SaveItemWhereaboutsFromUI()
        UpdateItemStacksForMissing()
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
    end)

    condFrame.cond_item_where_bag:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceItemWhereabouts(this)
        SaveItemWhereaboutsFromUI()
        UpdateItemStacksForMissing()
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
    end)

    condFrame.cond_item_where_missing:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        EnforceItemWhereabouts(this)
        SaveItemWhereaboutsFromUI()
        UpdateItemStacksForMissing()
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
        if not currentKey then
            this:SetChecked(false)
            return
        end

        if this:GetChecked() then
            condFrame.cond_aura_missing:SetChecked(false)
            SetExclusiveAuraFoundMode("found")
        else
            SetExclusiveAuraFoundMode(nil)
        end

        -- Keep DB/UI logic in sync (needed later when greying out owner on "missing")
        if UpdateCondFrameForKey then
            UpdateCondFrameForKey(currentKey)
        end
        SafeRefresh(); SafeEvaluate()
    end)

    condFrame.cond_aura_missing:SetScript("OnClick", function()
        if not currentKey then
            this:SetChecked(false)
            return
        end

        if this:GetChecked() then
            condFrame.cond_aura_found:SetChecked(false)
            SetExclusiveAuraFoundMode("missing")
        else
            SetExclusiveAuraFoundMode(nil)
        end

        if UpdateCondFrameForKey then
            UpdateCondFrameForKey(currentKey)
        end
        SafeRefresh(); SafeEvaluate()
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
		
		local ca = d.conditions.aura
		
		ca.targetHelp = condFrame.cond_aura_target_help:GetChecked() and true or false
		ca.targetHarm = condFrame.cond_aura_target_harm:GetChecked() and true or false
		ca.targetSelf = condFrame.cond_aura_onself:GetChecked()      and true or false
		ca.targetAlive = condFrame.cond_aura_target_alive:GetChecked() and true or false
        ca.targetDead  = condFrame.cond_aura_target_dead:GetChecked()  and true or false
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

	condFrame.cond_aura_target_alive:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then
            condFrame.cond_aura_target_dead:SetChecked(false)
        end
        SaveAuraTargets()
        SafeRefresh(); SafeEvaluate()
    end)

    condFrame.cond_aura_target_dead:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        if this:GetChecked() then
            condFrame.cond_aura_target_alive:SetChecked(false)
        end
        SaveAuraTargets()
        SafeRefresh(); SafeEvaluate()
    end)

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

    -- Aura owner flags ("My Aura" / "Others Aura") + dependent controls.
    local function _SetAuraCheckEnabled(cb, enabled, clearWhenDisabling)
        if not cb then return end

        if enabled then
            if cb.Enable then cb:Enable() end
            if cb.text and cb.text.SetTextColor then
                cb.text:SetTextColor(1, 0.82, 0)
            end
        else
            if clearWhenDisabling and cb.SetChecked then
                cb:SetChecked(false)
            end
            if cb.Disable then cb:Disable() end
            if cb.text and cb.text.SetTextColor then
                cb.text:SetTextColor(0.6, 0.6, 0.6)
            end
        end
    end

    -- Nampower guard: Aura owner tracking requires Nampower 2.15.1+
    local function AuraOwner_ApplyNampowerGuard()
        if not condFrame then return end

        local ok, verStr = _NP_AtLeast(_NP_REQ_MAJOR, _NP_REQ_MINOR, _NP_REQ_PATCH)
        condFrame._npAuraOwnerOK = ok and true or false
        condFrame._npAuraOwnerVerStr = verStr

        -- Tip text: keep original for OK versions, otherwise show requirement text + detected version
        if condFrame.cond_aura_owner_tip and condFrame.cond_aura_owner_tip.SetText then
            if ok then
                condFrame._aura_owner_tip_default = condFrame._aura_owner_tip_default
                    or "'Remaining' can only be used for a 'My Aura' on 'Target (Help/Harm)'"
                condFrame.cond_aura_owner_tip:SetText(condFrame._aura_owner_tip_default)
            else
                condFrame.cond_aura_owner_tip:SetText(
                    "Nampower 2.15.1+ req. for these options. You have " .. tostring(verStr) .. "."
                )
            end
        end

        -- If not supported: force unchecked + disabled + greyed, and clear DB flags so logic never runs
        if not ok then
            _SetAuraCheckEnabled(condFrame.cond_aura_mine,   false, true)
            _SetAuraCheckEnabled(condFrame.cond_aura_others, false, true)

            if currentKey then
                local d = EnsureDBEntry(currentKey)
                d.conditions = d.conditions or {}
                d.conditions.aura = d.conditions.aura or {}
                d.conditions.aura.onlyMine   = nil
                d.conditions.aura.onlyOthers = nil
            end

            -- Ensure nothing later re-paints enabled/checked visuals without the guard reasserting.
            SafeRefresh()
            SafeEvaluate()
        end
    end

    -- Re-apply the guard reliably:
    local function AuraOwner_EnsureNampowerGuard()
        if not condFrame then return end
        AuraOwner_ApplyNampowerGuard()
    end

    -- 1) Apply right now (important: condFrame may already be visible)
    AuraOwner_EnsureNampowerGuard()

    -- 2) Hook OnShow once
    if condFrame and not condFrame._npAuraOwnerGuardHooked then
        condFrame._npAuraOwnerGuardHooked = true
        local oldOnShow = condFrame:GetScript("OnShow")
        condFrame:SetScript("OnShow", function()
            if oldOnShow then oldOnShow() end
            AuraOwner_EnsureNampowerGuard()
        end)
    end

    -- 3) Wrap UpdateCondFrameForKey once it exists
    if condFrame and not condFrame._npAuraOwnerUCFKHooked then
        condFrame._npAuraOwnerUCFKHooked = true

        local hooker = CreateFrame("Frame")
        hooker._accum = 0
        hooker:SetScript("OnUpdate", function()
            hooker._accum = (hooker._accum or 0) + (arg1 or 0)
            if hooker._accum < 0.10 then return end
            hooker._accum = 0

            if type(UpdateCondFrameForKey) == "function" and not _G["DoiteEdit_NP_UCFKWrapped"] then
                _G["DoiteEdit_NP_UCFKWrapped"] = true

                local old = UpdateCondFrameForKey
                UpdateCondFrameForKey = function(key, ...)
                    local r = { old(key, unpack(arg)) }
                    -- After any refresh, force the Nampower guard to re-assert disabled state.
                    AuraOwner_EnsureNampowerGuard()
                    return unpack(r)
                end

                hooker:SetScript("OnUpdate", nil)
                hooker:Hide()
            end
        end)
    end

    local function AuraOwner_UpdateDependentChecks()
        if not condFrame then return end

        local mine   = condFrame.cond_aura_mine
                            and condFrame.cond_aura_mine.GetChecked
                            and condFrame.cond_aura_mine:GetChecked()
        local others = condFrame.cond_aura_others
                            and condFrame.cond_aura_others.GetChecked
                            and condFrame.cond_aura_others:GetChecked()

        local ownerActive = (mine or others) and true or false

        local rem   = condFrame.cond_aura_remaining_cb
        local textR = condFrame.cond_aura_text_time

		-- keep DB in sync with programmatic UI changes (SetChecked doesn't fire OnClick)
		if currentKey then
			local d = EnsureDBEntry(currentKey)
			d.conditions = d.conditions or {}
			d.conditions.aura = d.conditions.aura or {}

			local remOn   = (rem   and rem.GetChecked   and rem:GetChecked())   and true or false
			local textOn  = (textR and textR.GetChecked and textR:GetChecked()) and true or false

			d.conditions.aura.remainingEnabled    = remOn  or false
			d.conditions.aura.textTimeRemaining  = textOn or false
		end
    end

    local function AuraOwner_EnforceExclusivity(changed)
        if not condFrame then return end
        local mine   = condFrame.cond_aura_mine
        local others = condFrame.cond_aura_others

        if not mine or not others then
            AuraOwner_UpdateDependentChecks()
            return
        end

        if changed == mine and mine:GetChecked() then
            others:SetChecked(false)
        elseif changed == others and others:GetChecked() then
            mine:SetChecked(false)
        end

        -- "Neither" is allowed; no extra enforcement here.

        AuraOwner_UpdateDependentChecks()
    end

    local function SaveAuraOwnerFlags(changed)
        if not currentKey then return end

        local d = EnsureDBEntry(currentKey)
        d.conditions      = d.conditions      or {}
        d.conditions.aura = d.conditions.aura or {}

        local mine   = (condFrame.cond_aura_mine   and condFrame.cond_aura_mine:GetChecked())   and true or false
        local others = (condFrame.cond_aura_others and condFrame.cond_aura_others:GetChecked()) and true or false

        -- Hard exclusivity at DB level: if both somehow end up true, keep only the one just clicked.
        if mine and others then
            if changed == condFrame.cond_aura_mine then
                others = false
                if condFrame.cond_aura_others and condFrame.cond_aura_others.SetChecked then
                    condFrame.cond_aura_others:SetChecked(false)
                end
            elseif changed == condFrame.cond_aura_others then
                mine = false
                if condFrame.cond_aura_mine and condFrame.cond_aura_mine.SetChecked then
                    condFrame.cond_aura_mine:SetChecked(false)
                end
            else
                -- Fallback: prefer "My Aura"
                others = false
                if condFrame.cond_aura_others and condFrame.cond_aura_others.SetChecked then
                    condFrame.cond_aura_others:SetChecked(false)
                end
            end
        end

        d.conditions.aura.onlyMine   = mine   or nil
        d.conditions.aura.onlyOthers = others or nil

        -- Also update remaining/text checks whenever owner flags change.
        AuraOwner_UpdateDependentChecks()
    end


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
	
    -- Wire up the Aura owner checkboxes ("My Aura" / "Others Aura")
    if condFrame.cond_aura_mine then
        condFrame.cond_aura_mine:SetScript("OnClick", function()
            -- Hard guard (lazy): haven't evaluated yet (nil) or it's false, force evaluation now.
            if condFrame and condFrame._npAuraOwnerOK ~= true then
                AuraOwner_ApplyNampowerGuard()
                if condFrame._npAuraOwnerOK ~= true then
                    this:SetChecked(false)
                    return
                end
            end

            if not currentKey then
                this:SetChecked(false)
                return
            end

            -- Enforce exclusive state and update Remaining/Text logic
            AuraOwner_EnforceExclusivity(this)
            SaveAuraOwnerFlags(this)

            SafeRefresh(); SafeEvaluate()

            if UpdateCondFrameForKey then
                UpdateCondFrameForKey(currentKey)
            end
        end)
    end

    if condFrame.cond_aura_others then
        condFrame.cond_aura_others:SetScript("OnClick", function()
            -- Hard guard (lazy): haven't evaluated yet (nil) or it's false, force evaluation now.
            if condFrame and condFrame._npAuraOwnerOK ~= true then
                AuraOwner_ApplyNampowerGuard()
                if condFrame._npAuraOwnerOK ~= true then
                    this:SetChecked(false)
                    return
                end
            end

            if not currentKey then
                this:SetChecked(false)
                return
            end

            -- Enforce exclusive state and update Remaining/Text logic
            AuraOwner_EnforceExclusivity(this)
            SaveAuraOwnerFlags(this)

            SafeRefresh(); SafeEvaluate()

            if UpdateCondFrameForKey then
                UpdateCondFrameForKey(currentKey)
            end
        end)
    end

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
	
	-- Item Stacks toggle
    condFrame.cond_item_stacks_cb:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local enabled = this:GetChecked() and true or false
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.stacksEnabled = enabled

        if enabled then
            condFrame.cond_item_stacks_comp:Show()
            condFrame.cond_item_stacks_val:Show()
            condFrame.cond_item_stacks_val_enter:Show()
        else
            condFrame.cond_item_stacks_comp:Hide()
            condFrame.cond_item_stacks_val:Hide()
            condFrame.cond_item_stacks_val_enter:Hide()
        end

        UpdateCondFrameForKey(currentKey); SafeRefresh(); SafeEvaluate()
    end)

    -- Item text: stack counter
    condFrame.cond_item_text_stack:SetScript("OnClick", function()
        if not currentKey then this:SetChecked(false) return end
        local d = EnsureDBEntry(currentKey); d.conditions.item = d.conditions.item or {}
        d.conditions.item.textStackCounter = this:GetChecked() and true or false
        SafeRefresh(); SafeEvaluate()
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

	----------------------------------------------------------------
    -- Target Distance & Type dropdowns (shared lists)
    ----------------------------------------------------------------
    local distanceChoices = { "Any", "In range", "Melee range", "Not in range", "Behind", "In front" }

    local unitTypeChoices = {
        "Any", "Players", "NPC",
        "1. Humanoid", "2. Beast", "3. Dragonkin", "4. Undead",
        "5. Demon", "6. Giant", "7. Mechanical", "8. Elemental",
        -- Multi: versions (like forms; add common combos)
        "Multi: 1+2",
		"Multi: 1+4",
		"Multi: 1+2+3",
        "Multi: 2+3",
		"Multi: 4+5",
		"Multi: 5+8"
    }

    local function _CommitTargetField(typeKey, field, picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions = d.conditions or {}
        d.conditions[typeKey] = d.conditions[typeKey] or {}
        -- store nil for "Any" to keep DB clean
        if picked == "Any" then
            d.conditions[typeKey][field] = nil
        else
            d.conditions[typeKey][field] = picked
        end
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
    end

    local function InitSimpleListDD(dd, choices, typeKey, field, placeholder)
        if not dd then return end
        ClearDropdown(dd)
        UIDropDownMenu_Initialize(dd, function(frame, level, menuList)
            local info
            for _, txt in ipairs(choices) do
                local picked = txt
                info = {}
                info.text  = txt
                info.value = txt
                info.func  = function(button)
                    local val = (button and button.value) or picked
                    -- Update widget text/selection
                    if UIDropDownMenu_SetSelectedValue then
                        UIDropDownMenu_SetSelectedValue(dd, val)
                    end
                    if UIDropDownMenu_SetText then
                        -- Twow signature: UIDropDownMenu_SetText(text, dropdownFrame)
                        UIDropDownMenu_SetText(val, dd)
                    end
                    _GoldifyDD(dd)
                    -- Persist to DB and refresh logic
                    _CommitTargetField(typeKey, field, val)
                    -- Close the dropdown like other DDs
                    if CloseDropDownMenus then
                        CloseDropDownMenus()
                    end
                end
                -- No checkmark for these lists
                info.notCheckable = true
                UIDropDownMenu_AddButton(info)
            end
        end)

        -- initial placeholder text
        if UIDropDownMenu_SetSelectedValue then
            pcall(UIDropDownMenu_SetSelectedValue, dd, nil)
        end
        if UIDropDownMenu_SetText and placeholder then
            -- placeholder text first, then the dropdown frame
            pcall(UIDropDownMenu_SetText, placeholder, dd)
        end
        _WhiteifyDDText(dd)
    end

    -- Ability DDs
    InitSimpleListDD(condFrame.cond_ability_distanceDD,   distanceChoices, "ability", "targetDistance",   "Distance")
    InitSimpleListDD(condFrame.cond_ability_unitTypeDD,   unitTypeChoices, "ability", "targetUnitType",   "Unit type")

    -- Aura DDs
    InitSimpleListDD(condFrame.cond_aura_distanceDD,      distanceChoices, "aura",    "targetDistance",   "Distance")
    InitSimpleListDD(condFrame.cond_aura_unitTypeDD,      unitTypeChoices, "aura",    "targetUnitType",   "Unit type")

    -- Item DDs
    InitSimpleListDD(condFrame.cond_item_distanceDD,      distanceChoices, "item",    "targetDistance",   "Distance")
    InitSimpleListDD(condFrame.cond_item_unitTypeDD,      unitTypeChoices, "item",    "targetUnitType",   "Unit type")

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
	
	-- Item Stacks comparator
    InitComparatorDD(condFrame.cond_item_stacks_comp, function(picked)
        if not currentKey then return end
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        d.conditions.item.stacksComp = picked
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
	
	-- Item Stacks value
    condFrame.cond_item_stacks_val:SetScript("OnEnterPressed", function()
        if not currentKey then return end
        local v = tonumber(this:GetText())
        local d = EnsureDBEntry(currentKey)
        d.conditions.item = d.conditions.item or {}
        if not v then
            this:SetText(tostring(d.conditions.item.stacksVal or 0))
            return
        end
        if v < 0 then v = 0 end
        d.conditions.item.stacksVal = v
        SafeRefresh(); SafeEvaluate()
        UpdateCondFrameForKey(currentKey)
        if this.ClearFocus then this:ClearFocus() end
    end)
    do
        local _g = false
        condFrame.cond_item_stacks_val:SetScript("OnEditFocusLost", function()
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
	if condFrame.cond_ability_weaponDD then condFrame.cond_ability_weaponDD:Hide() end

    if condFrame.cond_ability_distanceDD   then condFrame.cond_ability_distanceDD:Hide()   end
    if condFrame.cond_ability_unitTypeDD   then condFrame.cond_ability_unitTypeDD:Hide()   end
	
	if condFrame.cond_aura_distanceDD  then condFrame.cond_aura_distanceDD:Hide()  end
	if condFrame.cond_aura_unitTypeDD  then condFrame.cond_aura_unitTypeDD:Hide()  end

    -- Category widgets start hidden; UpdateConditionsUI will toggle them
    if condFrame.categoryCheck then condFrame.categoryCheck:Hide() end
    if condFrame.categoryInput then condFrame.categoryInput:Hide() end
    if condFrame.categoryButton then condFrame.categoryButton:Hide() end
    if condFrame.categoryLabel then condFrame.categoryLabel:Hide() end
    if condFrame.categoryDD then condFrame.categoryDD:Hide() end

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
	if condFrame.cond_aura_others then condFrame.cond_aura_others:Hide() end
    if condFrame.cond_aura_owner_tip then condFrame.cond_aura_owner_tip:Hide() end
    if condFrame.cond_aura_distanceDD   then condFrame.cond_aura_distanceDD:Hide()   end
    if condFrame.cond_aura_unitTypeDD   then condFrame.cond_aura_unitTypeDD:Hide()   end
	if condFrame.cond_aura_weaponDD then condFrame.cond_aura_weaponDD:Hide() end
	
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
	condFrame.cond_item_stacks_cb:Hide()
    condFrame.cond_item_stacks_comp:Hide()
    condFrame.cond_item_stacks_val:Hide()
    condFrame.cond_item_stacks_val_enter:Hide()
    condFrame.cond_item_text_stack:Hide()
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
	if condFrame.cond_item_weaponDD then condFrame.cond_item_weaponDD:Hide() end
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

    -- Make sure the AND/OR logic popup and buttons vanish when the edit frame is closed
    if condFrame and not condFrame._logicHideHooked then
        condFrame._logicHideHooked = true
        local oldOnHide = condFrame:GetScript("OnHide")

        condFrame:SetScript("OnHide", function()
            -- Close the AND/OR / () popup if it is open
            if DoiteAuraLogicFrame and DoiteAuraLogicFrame:IsShown() then
                DoiteAuraLogicFrame:Hide()
            end

            -- Hide all per-type logic buttons as well
            if AuraCond_Managers then
                for _, mgr in pairs(AuraCond_Managers) do
                    if mgr.logicButton then
                        mgr.logicButton:Hide()
                    end
                end
            end

            if oldOnHide then
                oldOnHide()
            end
        end)
    end
end

-- Dynamically resize the scroll/content area to fit the last visible row (+20px buffer)
local function _ReflowCondAreaHeight()
    if not condFrame then return end

    -- Fallback to the frame itself if no explicit content frame exists.
    local parent = condFrame._condArea or condFrame.condArea or condFrame
    if not parent or not parent.GetChildren then return end

    local children = { parent:GetChildren() }
    if not children or not children[1] then return end

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
    -- Try both "_scrollFrame" and "scrollFrame" to match actual field names.
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

-- Dynamic "Aura Conditions" manager (Ability / Aura / Item)
do
    -- Small helper to reopen the dropdown a frame later (like the item version)
    local _ddReopenFrame = CreateFrame("Frame", "DoiteEditReopenFrame")
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
		local seen   = {}
		local i = 1

		while true do
			local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
			if not name then
				break
			end

			-- filter out passives
			local isPassive = false
			if IsPassiveSpell then
				local ok, passive = pcall(IsPassiveSpell, i, BOOKTYPE_SPELL)
				if ok and passive then
					isPassive = true
				end
			end
			if (not isPassive) and rank and string.find(rank, "Passive") then
				isPassive = true
			end

			if not isPassive and name and name ~= "" and not seen[name] then
				table.insert(spells, name)
				seen[name] = true
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

        elseif buffType == "TALENT" then
            -- Talent rows: mode stored as "Known" or "Not known"
            local modeStr = mode or ""
            local lower   = string.lower(modeStr)

            local isKnown = (lower == "known")
            local stateWord
            if isKnown then
                stateWord = "Known"
            else
                stateWord = "Not known"
            end

            local stateColor = isKnown and "|cff00ff00" or "|cffff0000"
            local statePart  = stateColor .. stateWord .. "|r"

            -- Talent (yellow)
            local talentPart = yellow .. "Talent" .. "|r"
            local namePart   = white .. (niceName or "") .. "|r"

            --   Talent (yellow) | Known/Not known (green/red): Name (white)
            return talentPart .. " " .. sep .. statePart .. ": " .. namePart
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
		if row.btn3 then row.btn3:Hide() end
		row.closeBtn:Show()
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
			-- First step: four choices (Ability / Buff / Debuff / Talent)
			row._branch = nil

			-- Space available for four buttons (leave room for [X] and some padding)
			local available = parentWidth - closeWidth - spacing*5
			if available < 80 then
				available = 80
			end
			local w = math.floor(available / 4)

			row.btn1:SetWidth(w)
			row.btn2:SetWidth(w)
			row.addButton:SetWidth(w)
			if row.btn3 then
				row.btn3:SetWidth(w)
			end

			row.btn1:ClearAllPoints()
			row.btn2:ClearAllPoints()
			row.addButton:ClearAllPoints()
			if row.btn3 then row.btn3:ClearAllPoints() end

			row.btn1:SetPoint("LEFT", row, "LEFT", 0, 0)
			row.btn2:SetPoint("LEFT", row.btn1, "RIGHT", spacing, 0)
			row.addButton:SetPoint("LEFT", row.btn2, "RIGHT", spacing, 0)
			if row.btn3 then
				row.btn3:SetPoint("LEFT", row.addButton, "RIGHT", spacing, 0)
			end

			row.btn1:SetText("Ability")
			row.btn2:SetText("Buff")
			row.addButton:SetText("Debuff")
			if row.btn3 then
				row.btn3:SetText("Talent")
			end

			row.btn1:Show()
			row.btn2:Show()
			row.addButton:Show()
			if row.btn3 then row.btn3:Show() end

		elseif state == "STEP2" then
			-- Second step: two wide buttons (Not on CD / On CD, Found / Missing, Known / Not known)

			-- Space for two buttons + [X]
			local available = parentWidth - closeWidth - spacing*3
			if available < 120 then
				available = 120
			end
			local w = math.floor(available / 2)

			row.btn1:SetWidth(w)
			row.btn2:SetWidth(w)

			row.btn1:ClearAllPoints()
			row.btn2:ClearAllPoints()
			row.btn1:SetPoint("LEFT", row, "LEFT", 0, 0)
			row.btn2:SetPoint("LEFT", row.btn1, "RIGHT", spacing, 0)

			if row._branch == "ABILITY" then
				-- Ability: cooldown mode
				row.btn1:SetText("Not on CD")
				row.btn2:SetText("On CD")

			elseif row._branch == "TALENT" then
				-- Talent: Known / Not known
				row.btn1:SetText("Known")
				row.btn2:SetText("Not known")

			else
				-- Aura (Buff/Debuff): Found / Missing
				row.btn1:SetText("Found")
				row.btn2:SetText("Missing")
			end

			row.btn1:Show()
			row.btn2:Show()

		elseif state == "STEP3" then
			-- Aura only: unit selection (two wide buttons: On player / On target)

			local available = parentWidth - closeWidth - spacing*3
			if available < 120 then
				available = 120
			end
			local w = math.floor(available / 2)

			row.btn1:SetWidth(w)
			row.btn2:SetWidth(w)

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
				-- Aura/Talent branch: manual spell/talent name input + Add
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
                -- layout: label at 0, then rows going down
        local y = -14

        -- saved rows
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

        -- logic button under the last condition row (only if ≥ 2)
        local list = AuraCond_GetListForType(typeKey) or {}
        local count = AuraCond_Len(list)

        if mgr.logicButton then
            if count >= 2 then
                mgr.logicButton:Show()
                mgr.logicButton:ClearAllPoints()
                mgr.logicButton:SetPoint("TOPLEFT",  mgr.anchor, "TOPLEFT",  0, y)
                mgr.logicButton:SetWidth(110)
                y = y - 20
            else
                mgr.logicButton:Hide()
            end
        end

        -- editing row goes under the logic button (if any)
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
		elseif row._branch == "TALENT" then
			-- Talent rows have no unit field; keep buffType = "TALENT"
			unit = nil
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

        -- rebuild so a fresh saved row and a new clean editing row
        AuraCond_RebuildFromDB_Internal(mgr.typeKey)
    end

    local function AuraCond_OnDeleteSaved(row)
        if not currentKey then return end
        local mgr = row._manager
        if not mgr then return end

        local list = AuraCond_GetListForType(mgr.typeKey)
        if not list then return end

        local idx = row._entryIndex or 0
        local n   = AuraCond_Len(list)
        if idx < 1 or idx > n then return end

        -- Remember if this entry carried parentheses; only then allow a logic reset (your "NOT affecting parentheses" rule).
        local deletedEntry = list[idx]
        local hadParens = deletedEntry and (deletedEntry.parenOpen or deletedEntry.parenClose)

        -- compact the array: shift down all elements after idx
        local i
        for i = idx, n-1 do
            list[i] = list[i+1]
        end
        list[n] = nil

        -- If this deletion ruined the bracket structure, reset the icon's logic for this typeKey to pure AND + no parentheses and notify.
        if hadParens and DoiteLogic and DoiteLogic.ValidateOrResetCurrentLogic then
            DoiteLogic.ValidateOrResetCurrentLogic(mgr.typeKey)
        end

        AuraCond_RebuildFromDB_Internal(mgr.typeKey)
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
		row.btn3 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.closeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
		row.addButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.labelFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

        local ddName = "DoiteAuraCond_AbilityDD_" .. tostring(mgr.typeKey or "X") .. "_" .. tostring(AuraCond_RowCounter)
        row.abilityDD = CreateFrame("Frame", ddName, row, "UIDropDownMenuTemplate")

		row.btn1:SetWidth(mainWidth)
		row.btn2:SetWidth(mainWidth)
		row.btn3:SetWidth(mainWidth)
		row.btn1:SetHeight(18)
		row.btn2:SetHeight(18)
		row.btn3:SetHeight(18)

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
		YellowifyButton(row.btn3)
		YellowifyButton(row.addButton)
		YellowifyButton(row.closeBtn)

        -- progression buttons:
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

				elseif row._branch == "TALENT" then
					-- Talent: Known
					row._choiceMode = "Known"
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

				elseif row._branch == "TALENT" then
					-- Talent: Not known
					row._choiceMode = "Not Known"
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

		
		row.btn3:SetScript("OnClick", function()
			if not currentKey then return end
			local state = row._state

			if state == "STEP1" then
				-- Talent branch
				row._branch         = "TALENT"
				row._choiceBuffType = "TALENT"
				row._choiceMode     = nil
				row._choiceUnit     = nil
				AuraCond_SetRowState(row, "STEP2")
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

		local mgr = AuraCond_Managers[typeKey]
		if not mgr then
			mgr = {}
			AuraCond_Managers[typeKey] = mgr
		end

		mgr.typeKey    = typeKey
		mgr.anchor     = anchorFrame
		mgr.savedRows  = mgr.savedRows or {}
		mgr.editRow    = mgr.editRow   or nil
		mgr._createRow = AuraCond_CreateRow

		-- Header label for this section
		if not mgr.label then
			local label = anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			label:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", 0, 0)
			label:SetJustifyH("LEFT")
			label:SetTextColor(1, 0.82, 0)
			label:SetText("Add extra ability / aura / talent conditions:")
			mgr.label = label
		end

		-- Create the And/Or logic button once per manager
		if not mgr.logicButton then
			local btnName = "DoiteAuraLogicButton_" .. tostring(typeKey)
			-- parent MUST be the same scroll-child anchor frame so it scrolls with rows
			local btn = CreateFrame("Button", btnName, anchorFrame, "UIPanelButtonTemplate")
			btn:SetWidth(50)
			btn:SetHeight(18)
			btn:SetText("And/Or Logic")

			-- place it on the same top row, right side of the anchor frame
			btn:ClearAllPoints()
			btn:SetPoint("TOPRIGHT", anchorFrame, "TOPRIGHT", 0, 0)

			-- make sure it is drawn above the scroll child contents
			if btn.SetFrameStrata then
				btn:SetFrameStrata("HIGH")
			end
			if anchorFrame.GetFrameLevel and btn.SetFrameLevel then
				btn:SetFrameLevel(anchorFrame:GetFrameLevel() + 1)
			end

			-- yellow small text, like the other small buttons
			local fs = btn:GetFontString()
			if fs and fs.SetTextColor then
				fs:SetTextColor(1, 0.82, 0)
			end

			btn:Hide()

			btn:SetScript("OnClick", function()
				local DL = _G["DoiteLogic"]
				if DL and DL.OpenAuraLogicEditor then
					DL.OpenAuraLogicEditor(typeKey)   -- or "ability"/"item"
				end
			end)

			mgr.logicButton = btn
		end

		-- Base height: rows will extend this via AuraCond_CreateRow / refresh
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

    -- Always announce in chat when entering edit for this icon
    local dn = data.displayName
    if not dn or dn == "" then
        dn = currentKey
    end
    DoiteEdit_AnnounceEditingIcon(dn)

    local c = data.conditions
	
	    local function _IsWarriorPaladinShaman()
        local _, cls = UnitClass("player")
        cls = cls and string.upper(cls) or ""
        return (cls == "WARRIOR" or cls == "PALADIN" or cls == "SHAMAN")
    end


    ----------------------------------------------------------------
    -- Icon-level categories (applies regardless of type)
    ----------------------------------------------------------------
    if condFrame.categoryCheck and condFrame.categoryInput and condFrame.categoryButton
       and condFrame.categoryLabel and condFrame.categoryDD then

        if data.group then
            -- When grouped: hide and auto-uncheck the category UI
            condFrame.categoryCheck:SetChecked(false)
            condFrame.categoryCheck:Hide()
            condFrame.categoryInput:Hide()
            condFrame.categoryButton:Hide()
            condFrame.categoryLabel:Hide()
            condFrame.categoryDD:Hide()
        else
            -- Not grouped: category UI is available
            condFrame.categoryCheck:Show()

            local dcat = data.category
            local isOn = (dcat ~= nil and dcat ~= "")

            condFrame.categoryCheck:SetChecked(isOn)

            if isOn then
                condFrame.categoryInput:Show()
                condFrame.categoryButton:Show()
                condFrame.categoryLabel:Show()
                condFrame.categoryDD:Show()
                if Category_RefreshDropdown then
                    Category_RefreshDropdown(dcat)
                end
            else
                condFrame.categoryInput:Hide()
                condFrame.categoryButton:Hide()
                condFrame.categoryLabel:Hide()
                condFrame.categoryDD:Hide()
                condFrame.categoryInput:SetText("")
                if Category_RefreshDropdown then
                    -- Still refresh so "(Empty)" or "Select" is correct when user ticks the box
                    Category_RefreshDropdown(nil)
                end
            end

            if Category_UpdateButtonState then
                Category_UpdateButtonState()
            end
        end
    end

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
		
		-- TARGET STATUS (ability): mutually exclusive, but both can be off
        local ta = (c.ability and c.ability.targetAlive) == true
        local td = (c.ability and c.ability.targetDead)  == true

        if condFrame.cond_ability_target_alive then
            condFrame.cond_ability_target_alive:SetChecked(ta)
            condFrame.cond_ability_target_alive:Show()
        end
        if condFrame.cond_ability_target_dead then
            condFrame.cond_ability_target_dead:SetChecked(td)
            condFrame.cond_ability_target_dead:Show()
        end
		
		        -- === TARGET DISTANCE & TYPE (Ability) ===
        if condFrame.cond_ability_distanceDD then
            condFrame.cond_ability_distanceDD:Show()
            condFrame.cond_ability_unitTypeDD:Show()

            local a = c.ability or {}

            local function _RestoreDD(dd, val, placeholder)
                if not dd then return end
                if val and val ~= "" then
                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, dd, val)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, val, dd)
                    end
                    _GoldifyDD(dd)
                else
                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, dd, nil)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, placeholder, dd)
                    end
                    _WhiteifyDDText(dd)
                end
            end

            _RestoreDD(condFrame.cond_ability_distanceDD,  a.targetDistance,   "Distance")
            _RestoreDD(condFrame.cond_ability_unitTypeDD,  a.targetUnitType,   "Unit type")

            -- Grey out and make unselectable when Target (self) is active
            local disableTargetRow = false
            if condFrame.cond_ability_target_self and condFrame.cond_ability_target_self.GetChecked then
                disableTargetRow = condFrame.cond_ability_target_self:GetChecked()
            end

            if disableTargetRow then
                -- clear DB fields
                a.targetDistance   = nil
                a.targetUnitType   = nil

                -- reset visible state and disable
                _SetDDEnabled(condFrame.cond_ability_distanceDD,  false, "Distance")
                _SetDDEnabled(condFrame.cond_ability_unitTypeDD,  false, "Unit type")
            else
                _SetDDEnabled(condFrame.cond_ability_distanceDD,  true, "Distance")
                _SetDDEnabled(condFrame.cond_ability_unitTypeDD,  true, "Unit type")
            end
        end

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

        -- Combo points / class-specific note / weapon filter
        local isRogueOrDruid = _IsRogueOrDruid and _IsRogueOrDruid() or false
        local isWPS          = _IsWarriorPaladinShaman()

        if condFrame.cond_ability_weaponDD then
            condFrame.cond_ability_weaponDD:Hide()
        end

        if isRogueOrDruid then
            -- Original combo-point behavior (Rogue / Druid)
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

        elseif isWPS and condFrame.cond_ability_weaponDD then
            -- Warrior / Paladin / Shaman: use weapon / fighting-style dropdown instead of CPs
            condFrame.cond_ability_cp_cb:Hide()
            condFrame.cond_ability_cp_comp:Hide()
            condFrame.cond_ability_cp_val:Hide()
            condFrame.cond_ability_cp_val_enter:Hide()
            if condFrame.cond_ability_class_note then
                condFrame.cond_ability_class_note:Hide()
            end

            condFrame.cond_ability_weaponDD:Show()
            InitWeaponDropdown(condFrame.cond_ability_weaponDD, data, "ability")

        else
            -- Other classes: neither CP nor weapon-filter → show neutral note
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
		if condFrame.cond_aura_weaponDD then condFrame.cond_aura_weaponDD:Hide() end

        -- hide aura target distance/type row when not editing an aura
        if condFrame.cond_aura_distanceDD  then condFrame.cond_aura_distanceDD:Hide()  end
        if condFrame.cond_aura_unitTypeDD  then condFrame.cond_aura_unitTypeDD:Hide()  end
		
		-- also hide item target distance/type row when not editing an item
        if condFrame.cond_item_distanceDD  then condFrame.cond_item_distanceDD:Hide()  end
        if condFrame.cond_item_unitTypeDD  then condFrame.cond_item_unitTypeDD:Hide()  end
		
		if condFrame.cond_aura_mine then condFrame.cond_aura_mine:Hide() end
		if condFrame.cond_aura_others then condFrame.cond_aura_others:Hide() end
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
		if condFrame.cond_item_weaponDD then condFrame.cond_item_weaponDD:Hide() end
		        -- Hide TARGET STATUS for aura & item when editing an ability
        if condFrame.cond_aura_target_alive then condFrame.cond_aura_target_alive:Hide() end
        if condFrame.cond_aura_target_dead  then condFrame.cond_aura_target_dead:Hide()  end
        if condFrame.cond_item_target_alive then condFrame.cond_item_target_alive:Hide() end
        if condFrame.cond_item_target_dead  then condFrame.cond_item_target_dead:Hide()  end
		        -- hide Item stacks row when not editing an item
        if condFrame.cond_item_stacks_cb then condFrame.cond_item_stacks_cb:Hide() end
        if condFrame.cond_item_text_stack then condFrame.cond_item_text_stack:Hide() end
        if condFrame.cond_item_stacks_comp then condFrame.cond_item_stacks_comp:Hide() end
        if condFrame.cond_item_stacks_val then condFrame.cond_item_stacks_val:Hide() end
        if condFrame.cond_item_stacks_val_enter then condFrame.cond_item_stacks_val_enter:Hide() end

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

        if UpdateItemStacksForMissing then
            UpdateItemStacksForMissing()
        end
		
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

            -- preserve outer isMissing flag for rest of Item logic
            isMissing = ms
        end
		
		----------------------------------------------------------------
        -- === TARGET DISTANCE & TYPE (Item) ===   <-- now for ALL items
        ----------------------------------------------------------------
        if condFrame.cond_item_distanceDD then
            condFrame.cond_item_distanceDD:Show()
            condFrame.cond_item_unitTypeDD:Show()

            local function _RestoreItemDD(dd, val, placeholder)
                if not dd then return end
                if val and val ~= "" then
                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, dd, val)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, val, dd)
                    end
                    _GoldifyDD(dd)
                else
                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, dd, nil)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, placeholder, dd)
                    end
                    _WhiteifyDDText(dd)
                end
            end

            -- Always clear & hard-disable Distance for items
            ic.targetDistance = nil
            _RestoreItemDD(condFrame.cond_item_distanceDD, nil, "Distance")
            _SetDDEnabled(condFrame.cond_item_distanceDD, false, "Distance")

            -- UnitType still follow the old rules
            _RestoreItemDD(condFrame.cond_item_unitTypeDD,  ic.targetUnitType,  "Unit type")

            local isMissingForDD = (ic.whereMissing == true)
            local hasSelfTarget  = (ic.targetSelf == true)

            if isMissingForDD or hasSelfTarget then
                ic.targetUnitType  = nil
                _SetDDEnabled(condFrame.cond_item_unitTypeDD,  false, "Unit type")
            else
                _SetDDEnabled(condFrame.cond_item_unitTypeDD,  true, "Unit type")
            end
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
		
        -- TARGET STATUS (item)
        if condFrame.cond_item_target_alive then
            condFrame.cond_item_target_alive:SetChecked(ic.targetAlive == true)
            condFrame.cond_item_target_alive:Show()
        end
        if condFrame.cond_item_target_dead then
            condFrame.cond_item_target_dead:SetChecked(ic.targetDead == true)
            condFrame.cond_item_target_dead:Show()
        end

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

        -- ITEM STACKS row (Item stacks + text stack counter)
        do
            local stacksOn   = (ic.stacksEnabled == true)
            local textStacks = (ic.textStackCounter == true)

            -- Always show the two checkboxes for any Item-type entry
            condFrame.cond_item_stacks_cb:Show()
            condFrame.cond_item_text_stack:Show()

            if isMissing then
                condFrame.cond_item_stacks_cb:SetChecked(false)
                condFrame.cond_item_text_stack:SetChecked(false)

                _disCheck(condFrame.cond_item_stacks_cb)
                _disCheck(condFrame.cond_item_text_stack)

                if condFrame.cond_item_stacks_comp then
                    condFrame.cond_item_stacks_comp:Hide()
                end
                if condFrame.cond_item_stacks_val then
                    condFrame.cond_item_stacks_val:Hide()
                end
                if condFrame.cond_item_stacks_val_enter then
                    condFrame.cond_item_stacks_val_enter:Hide()
                end
            else
                _enCheck(condFrame.cond_item_stacks_cb)
                _enCheck(condFrame.cond_item_text_stack)

                condFrame.cond_item_stacks_cb:SetChecked(stacksOn)
                condFrame.cond_item_text_stack:SetChecked(textStacks)

                if stacksOn then
                    if condFrame.cond_item_stacks_comp then
                        condFrame.cond_item_stacks_comp:Show()
                    end
                    if condFrame.cond_item_stacks_val then
                        condFrame.cond_item_stacks_val:Show()
                    end
                    if condFrame.cond_item_stacks_val_enter then
                        condFrame.cond_item_stacks_val_enter:Show()
                    end

                    local comp = ic.stacksComp or ""
                    UIDropDownMenu_SetSelectedValue(condFrame.cond_item_stacks_comp, comp)
                    UIDropDownMenu_SetText(comp, condFrame.cond_item_stacks_comp)
                    _GoldifyDD(condFrame.cond_item_stacks_comp)

                    condFrame.cond_item_stacks_val:SetText(tostring(ic.stacksVal or 0))
                else
                    if condFrame.cond_item_stacks_comp then
                        condFrame.cond_item_stacks_comp:Hide()
                    end
                    if condFrame.cond_item_stacks_val then
                        condFrame.cond_item_stacks_val:Hide()
                    end
                    if condFrame.cond_item_stacks_val_enter then
                        condFrame.cond_item_stacks_val_enter:Hide()
                    end
                end
            end
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

        -- CLASS-SPECIFIC (combo points / note / weapon filter)
        local isRogueOrDruid = _IsRogueOrDruid and _IsRogueOrDruid() or false
        local isWPS          = _IsWarriorPaladinShaman()

        -- Default: hide weapon dropdown; show+init only for W/P/S
        if condFrame.cond_item_weaponDD then
            condFrame.cond_item_weaponDD:Hide()
        end

        if isRogueOrDruid then
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

        elseif isWPS and condFrame.cond_item_weaponDD then
            -- Warrior / Paladin / Shaman: weapon / fighting-style dropdown instead of CP
            condFrame.cond_item_cp_cb:Hide()
            condFrame.cond_item_cp_comp:Hide()
            condFrame.cond_item_cp_val:Hide()
            condFrame.cond_item_cp_val_enter:Hide()
            if condFrame.cond_item_class_note then
                condFrame.cond_item_class_note:Hide()
            end

            condFrame.cond_item_weaponDD:Show()
            InitWeaponDropdown(condFrame.cond_item_weaponDD, data, "item")

        else
            -- Other classes: no CP and no weapon filter → show neutral note
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
		if condFrame.cond_ability_weaponDD then condFrame.cond_ability_weaponDD:Hide() end
		if condFrame.cond_ability_target_alive then condFrame.cond_ability_target_alive:Hide() end
        if condFrame.cond_ability_target_dead  then condFrame.cond_ability_target_dead:Hide()  end

        -- hide aura controls
        condFrame.cond_aura_found:Hide()
        condFrame.cond_aura_missing:Hide()
        condFrame.cond_aura_incombat:Hide()
        condFrame.cond_aura_outcombat:Hide()
        condFrame.cond_aura_target_help:Hide()
        condFrame.cond_aura_target_harm:Hide()
        condFrame.cond_aura_onself:Hide()
		if condFrame.cond_aura_target_alive then condFrame.cond_aura_target_alive:Hide() end
        if condFrame.cond_aura_target_dead  then condFrame.cond_aura_target_dead:Hide()  end
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
		if condFrame.cond_aura_weaponDD then condFrame.cond_aura_weaponDD:Hide() end

        -- hide aura target distance/type row when not editing an aura
        if condFrame.cond_aura_distanceDD  then condFrame.cond_aura_distanceDD:Hide()  end
        if condFrame.cond_aura_unitTypeDD  then condFrame.cond_aura_unitTypeDD:Hide()  end
		
		-- hide ability target distance/type row when not editing an ability
        if condFrame.cond_ability_distanceDD  then condFrame.cond_ability_distanceDD:Hide()  end
        if condFrame.cond_ability_unitTypeDD  then condFrame.cond_ability_unitTypeDD:Hide()  end

		condFrame.cond_aura_mine:Hide()
		condFrame.cond_aura_others:Hide()
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
        local function _hideRemInputs()
            condFrame.cond_aura_remaining_comp:Hide()
            condFrame.cond_aura_remaining_val:Hide()
            condFrame.cond_aura_remaining_val_enter:Hide()
        end

        condFrame.cond_aura_found:Show()
        condFrame.cond_aura_missing:Show()
        if condFrame.cond_aura_tip then condFrame.cond_aura_tip:Show() end
		if condFrame.cond_aura_owner_tip then condFrame.cond_aura_owner_tip:Show() end
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
		
        -- TARGET STATUS
        local taa = (c.aura and c.aura.targetAlive) == true
        local tad = (c.aura and c.aura.targetDead)  == true
        condFrame.cond_aura_target_alive:SetChecked(taa)
        condFrame.cond_aura_target_dead:SetChecked(tad)
		if condFrame.cond_aura_target_alive then condFrame.cond_aura_target_alive:Show() end
        if condFrame.cond_aura_target_dead  then condFrame.cond_aura_target_dead:Show()  end

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

        -- === TARGET DISTANCE & TYPE (Aura) ===
        if condFrame.cond_aura_distanceDD then
            condFrame.cond_aura_distanceDD:Show()
            condFrame.cond_aura_unitTypeDD:Show()

            local a = c.aura or {}

            local function _RestoreAuraDD(dd, val, placeholder)
                if not dd then return end
                if val and val ~= "" then
                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, dd, val)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, val, dd)
                    end
                    _GoldifyDD(dd)
                else
                    if UIDropDownMenu_SetSelectedValue then
                        pcall(UIDropDownMenu_SetSelectedValue, dd, nil)
                    end
                    if UIDropDownMenu_SetText then
                        pcall(UIDropDownMenu_SetText, placeholder, dd)
                    end
                    _WhiteifyDDText(dd)
                end
            end

            -- Always clear & hard-disable Distance for auras
            if a then a.targetDistance = nil end
            _RestoreAuraDD(condFrame.cond_aura_distanceDD, nil, "Distance")
            _SetDDEnabled(condFrame.cond_aura_distanceDD, false, "Distance")

            -- UnitType remain usable
            _RestoreAuraDD(condFrame.cond_aura_unitTypeDD,  a.targetUnitType,  "Unit type")

            -- Self-only target: UnitType are meaningless
            local isSelfOnly = (a.targetSelf == true)
            if isSelfOnly then
                a.targetUnitType   = nil

                _SetDDEnabled(condFrame.cond_aura_unitTypeDD,  false, "Unit type")
            else
                _SetDDEnabled(condFrame.cond_aura_unitTypeDD,  true, "Unit type")
            end
        end

        condFrame.cond_aura_glow:SetChecked((c.aura and c.aura.glow) or false)
        condFrame.cond_aura_greyscale:SetChecked((c.aura and c.aura.greyscale) or false)

        local isBuff     = (data.type == "Buff")

        -- Combo points / class-specific note / weapon filter
        local isRogueOrDruid = _IsRogueOrDruid and _IsRogueOrDruid() or false
        local isWPS          = _IsWarriorPaladinShaman()

        if condFrame.cond_aura_weaponDD then
            condFrame.cond_aura_weaponDD:Hide()
        end

        if isRogueOrDruid then
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

        elseif isWPS and condFrame.cond_aura_weaponDD then
            -- Warrior / Paladin / Shaman: weapon / fighting-style dropdown instead of CPs
            condFrame.cond_aura_cp_cb:Hide()
            condFrame.cond_aura_cp_comp:Hide()
            condFrame.cond_aura_cp_val:Hide()
            condFrame.cond_aura_cp_val_enter:Hide()
            if condFrame.cond_aura_class_note then
                condFrame.cond_aura_class_note:Hide()
            end

            condFrame.cond_aura_weaponDD:Show()
            InitWeaponDropdown(condFrame.cond_aura_weaponDD, data, "aura")

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

		-- Aura owner flags ("My Aura" / "Others Aura") – buff and debuff identical. IMPORTANT: must respect Nampower guard (2.15.1+), otherwise UpdateConditionsUI will re-enable them.
		local npOK = (condFrame and condFrame._npAuraOwnerOK == true) and true or false

		-- Use the shared helper if available; otherwise fall back to local enable/disable behavior.
		local function _AO_SetEnabled(cb, enabled, clearWhenDisabling)
			if not cb then return end
			if type(_SetAuraCheckEnabled) == "function" then
				_SetAuraCheckEnabled(cb, enabled, clearWhenDisabling)
				return
			end

			if enabled then
				if cb.Enable then cb:Enable() end
				if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(1, 0.82, 0) end
			else
				if clearWhenDisabling and cb.SetChecked then cb:SetChecked(false) end
				if cb.Disable then cb:Disable() end
				if cb.text and cb.text.SetTextColor then cb.text:SetTextColor(0.6, 0.6, 0.6) end
			end
		end

		local onlyMine   = (c.aura and c.aura.onlyMine)   and true or false
		local onlyOthers = (c.aura and c.aura.onlyOthers) and true or false

		-- If Nampower is not supported, forcibly clear DB + UI state here as well.
		if not npOK then
			onlyMine, onlyOthers = false, false
			if c.aura then
				c.aura.onlyMine   = nil
				c.aura.onlyOthers = nil
			end
		else
			-- Sanitize DB: if both are somehow true, keep "My Aura" only.
			if onlyMine and onlyOthers then
				onlyOthers = false
				if c.aura then
					c.aura.onlyOthers = nil
				end
			end
		end

		if amode == "found" then
			-- Owner row visible for FOUND. Enabled only when Nampower guard is OK; otherwise visible but greyed + forced off.
			if condFrame.cond_aura_mine then
				condFrame.cond_aura_mine:Show()
				condFrame.cond_aura_mine:SetChecked(onlyMine)
				_AO_SetEnabled(condFrame.cond_aura_mine, npOK, true)
			end

			if condFrame.cond_aura_others then
				condFrame.cond_aura_others:Show()
				condFrame.cond_aura_others:SetChecked(onlyOthers)
				_AO_SetEnabled(condFrame.cond_aura_others, npOK, true)
			end

		elseif amode == "missing" then
			-- Missing: keep row visible but disable + clear flags (always).
			if condFrame.cond_aura_mine then
				condFrame.cond_aura_mine:Show()
				condFrame.cond_aura_mine:SetChecked(false)
				_AO_SetEnabled(condFrame.cond_aura_mine, false, true)
			end

			if condFrame.cond_aura_others then
				condFrame.cond_aura_others:Show()
				condFrame.cond_aura_others:SetChecked(false)
				_AO_SetEnabled(condFrame.cond_aura_others, false, true)
			end

			if c.aura then
				c.aura.onlyMine   = nil
				c.aura.onlyOthers = nil
			end

		else
			-- No aura mode selected → hide owner controls.
			if condFrame.cond_aura_mine then
				condFrame.cond_aura_mine:Hide()
			end
			if condFrame.cond_aura_others then
				condFrame.cond_aura_others:Hide()
			end
		end

		-- After setting the owner flags from DB, update Remaining/Text grey state.
		if AuraOwner_UpdateDependentChecks then
			AuraOwner_UpdateDependentChecks()
		end

        -- Row 10: Text flags (Text: stack + Text: remaining)
        if amode == "found" then
            -- === Text: Stack counter ===
            condFrame.cond_aura_text_stack:Show()
            _enableCheck(condFrame.cond_aura_text_stack)
            condFrame.cond_aura_text_stack:SetChecked((c.aura and c.aura.textStackCounter) or false)

            -- === Text: Time remaining ===
            condFrame.cond_aura_text_time:Show()

            if isSelfOnly then
                -- On Player (self): user may freely toggle Text: Remaining
                _enableCheck(condFrame.cond_aura_text_time)
                condFrame.cond_aura_text_time:SetChecked((c.aura and c.aura.textTimeRemaining) or false)

            elseif isHelpOrHarm then
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
                -- On Player (self): user can freely toggle Remaining
                _enableCheck(condFrame.cond_aura_remaining_cb)
                condFrame.cond_aura_remaining_cb:SetChecked(aRemEnabled)

            elseif isHelpOrHarm then
                -- Help/Harm target: apply My Aura rules
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
		if condFrame.cond_ability_target_alive then condFrame.cond_ability_target_alive:Hide() end
        if condFrame.cond_ability_target_dead  then condFrame.cond_ability_target_dead:Hide()  end

        if condFrame.cond_ability_hp_my then condFrame.cond_ability_hp_my:Hide() end
        if condFrame.cond_ability_hp_tgt then condFrame.cond_ability_hp_tgt:Hide() end
        if condFrame.cond_ability_hp_comp then condFrame.cond_ability_hp_comp:Hide() end
        if condFrame.cond_ability_hp_val then condFrame.cond_ability_hp_val:Hide() end
        if condFrame.cond_ability_hp_val_enter then condFrame.cond_ability_hp_val_enter:Hide() end

        if condFrame.cond_ability_cp_cb then condFrame.cond_ability_cp_cb:Hide() end
        if condFrame.cond_ability_cp_comp then condFrame.cond_ability_cp_comp:Hide() end
        if condFrame.cond_ability_cp_val then condFrame.cond_ability_cp_val:Hide() end
        if condFrame.cond_ability_cp_val_enter then condFrame.cond_ability_cp_val_enter:Hide() end
		if condFrame.cond_ability_weaponDD then condFrame.cond_ability_weaponDD:Hide() end
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
		if condFrame.cond_item_target_alive then condFrame.cond_item_target_alive:Hide() end
        if condFrame.cond_item_target_dead  then condFrame.cond_item_target_dead:Hide()  end
		if condFrame.cond_item_weaponDD then condFrame.cond_item_weaponDD:Hide() end
		        -- hide Item stacks row when not editing an item
        if condFrame.cond_item_stacks_cb then condFrame.cond_item_stacks_cb:Hide() end
        if condFrame.cond_item_text_stack then condFrame.cond_item_text_stack:Hide() end
        if condFrame.cond_item_stacks_comp then condFrame.cond_item_stacks_comp:Hide() end
        if condFrame.cond_item_stacks_val then condFrame.cond_item_stacks_val:Hide() end
        if condFrame.cond_item_stacks_val_enter then condFrame.cond_item_stacks_val_enter:Hide() end

        -- hide ability DDs when not editing an ability
        if condFrame.cond_ability_distanceDD  then condFrame.cond_ability_distanceDD:Hide()  end
        if condFrame.cond_ability_unitTypeDD  then condFrame.cond_ability_unitTypeDD:Hide()  end

        -- hide item DDs when not editing an item
		if condFrame.cond_item_distanceDD   then condFrame.cond_item_distanceDD:Hide()   end
		if condFrame.cond_item_unitTypeDD   then condFrame.cond_item_unitTypeDD:Hide()   end
    end
	_ReflowCondAreaHeight()
end

----------------------------------------------------------------
-- End Conditions UI section
----------------------------------------------------------------

-- Update frame controls to reflect db for `key`
function UpdateCondFrameForKey(key)
    if not condFrame or not key then return end
	
	-- When switching icons, force-close the AND/OR logic popup for the old icon
    if DoiteAuraLogicFrame and DoiteAuraLogicFrame:IsShown() then
        DoiteAuraLogicFrame:Hide()
    end
	
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
					lastAnnouncedKey = nil

					-- kick a repaint so the formerly-forced icon can hide if conditions say so
					if DoiteConditions_RequestEvaluate then
						DoiteConditions_RequestEvaluate()
					end
				end)

		_G["DoiteEdit_Frame"] = condFrame

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

		if not condFrame.condListContainer then
			local cW = condFrame:GetWidth() - 43
			local cH = 210

			local listContainer = CreateFrame("Frame", nil, condFrame)
			listContainer:SetWidth(cW)
			listContainer:SetHeight(cH)
			listContainer:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 14, -143)
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
			listContent:SetHeight(cH - 10)
			scrollFrame:SetScrollChild(listContent)
			condFrame._condArea = listContent
			
			listContent:SetHeight(900)

			-- 2) Make absolutely sure the visual stacking (levels) keeps the backdrop under the controls.
			local baseLevel = condFrame:GetFrameLevel() or 1
			listContainer:SetFrameLevel(baseLevel + 0)
			scrollFrame:SetFrameLevel(baseLevel + 1)
			listContent:SetFrameLevel(baseLevel + 2)

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
				DoiteEdit_FlushHeavy()
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

            -- editbox -> slider while typing
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
