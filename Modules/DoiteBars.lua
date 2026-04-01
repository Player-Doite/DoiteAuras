---------------------------------------------------------------
-- DoiteBars.lua
-- Adding bars, all edit, updates and condition logic
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

DoiteBars = DoiteBars or {}

---------------------------------------------------------------
-- Bar Kind Registry
---------------------------------------------------------------
DoiteBars.Kinds = {

    Powerbar = {
        label = "Powerbar",
        getValues = function()
            local cur = UnitMana("player")    or 0
            local max = UnitManaMax("player") or 1
            if max <= 0 then max = 1 end
            return cur, max
        end,
        r = 0.0, g = 0.0, b = 1.0,
    },

    Healthbar = {
        label = "Healthbar",
        getValues = function()
            local cur = UnitHealth("player")    or 0
            local max = UnitHealthMax("player") or 1
            if max <= 0 then max = 1 end
            return cur, max
        end,
        r = 0.0, g = 1.0, b = 0.0,
    },
}

DoiteBars.KindOrder = {
    "Powerbar",
    "Healthbar",
}

---------------------------------------------------------------
-- Per-power-type colour lookup
-- 0=Mana  1=Rage  2=Focus  3=Energy
---------------------------------------------------------------
local DA_PowerColors = {
    [0] = { r = 0.00, g = 0.00, b = 1.00 },
    [1] = { r = 1.00, g = 0.00, b = 0.00 },
    [2] = { r = 0.90, g = 0.61, b = 0.23 },
    [3] = { r = 1.00, g = 1.00, b = 0.00 },
}

local function DA_BarColorForPowerType()
    local pt = UnitPowerType and UnitPowerType("player") or 0
    local c  = DA_PowerColors[pt]
    if c then return c.r, c.g, c.b end
    return 0.0, 0.0, 1.0
end

---------------------------------------------------------------
-- Internal frame pool
---------------------------------------------------------------
local barFrames = {}
local BAR_BORDER = 0
local BE_IsOutsideTextPosition

---------------------------------------------------------------
-- Shared defaults
---------------------------------------------------------------
local BAR_DEFAULTS = {
    barWidth      = 200,
    barHeight     = 24,
    offsetX       = 0,
    offsetY       = 0,
    scale         = 1,
    alpha         = 1,
    inCombat      = true,
    outCombat     = true,
    powerOnly     = false,
    powerComp     = ">=",
    powerValue    = 0,
    hpMode        = nil,      -- nil | "my" | "target"
    hpComp        = ">=",
    hpValue       = 0,
    barR          = -1,
    barG          = -1,
    barB          = -1,
    barAlpha      = 1,
    bgR           = 0,
    bgG           = 0,
    bgB           = 0,
    bgAlpha       = 0.7,
    textFormat    = "Actual",
    textPosition  = "Center",
    orientation   = "Horizontal",
    direction     = "Left to right",
    fillTexture   = "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_tukui",
    fontSize      = 10,
}
local DA_DEFAULT_BAR_TEXTURE = "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_tukui"

local function DA_BarForceCategory(data)
    if not data then return end
    data.category = "BARS"
    data.group = nil
    data.isLeader = nil
end

local function DA_DefaultDirectionForOrientation(orientation)
    if orientation == "Vertical" then
        return "From down to up"
    end
    return "Left to right"
end

local function DA_IsDirectionValid(orientation, direction)
    if orientation == "Vertical" then
        return direction == "From up to down" or direction == "From down to up"
    end
    return direction == "Left to right" or direction == "Right to left"
end

local function DA_IsTextureValid(path)
    return path == "Interface\\TargetingFrame\\UI-StatusBar"
        or path == "Interface\\Buttons\\WHITE8X8"
        or path == "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar"
        or path == "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_tukui"
        or path == "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_elvui"
        or path == "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_gradient"
        or path == "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_striped"
        or path == "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar"
end

local function DA_BarApplyDefaults(data)
    for k, v in pairs(BAR_DEFAULTS) do
        if data[k] == nil then
            data[k] = v
        end
    end
    if data.bgUseDefault == nil then
        data.bgUseDefault = (data.bgR == 0 and data.bgG == 0 and data.bgB == 0 and data.bgAlpha == 0.7)
    end
    if data.orientation ~= "Vertical" then
        data.orientation = "Horizontal"
    end
    if not data.direction or data.direction == "" or not DA_IsDirectionValid(data.orientation, data.direction) then
        data.direction = DA_DefaultDirectionForOrientation(data.orientation)
    end
    if not data.fillTexture or not DA_IsTextureValid(data.fillTexture) then
        data.fillTexture = DA_DEFAULT_BAR_TEXTURE
    end
    DA_BarForceCategory(data)
end

local function DA_BarCompare(left, comp, right)
    if comp == "<=" then return left <= right end
    if comp == "==" then return left == right end
    return left >= right
end

local function DA_BarApplyFill(frame, data, cur, max)
    if not frame or not frame.bar or not frame.fill then return end
    local m = tonumber(max) or 0
    local c = tonumber(cur) or 0
    if m <= 0 then m = 1 end
    if c < 0 then c = 0 end
    if c > m then c = m end
    local pct = c / m

    local innerW, innerH
    if data and data.orientation == "Vertical" then
        innerW = (tonumber(data.barHeight) or 0) - (BAR_BORDER * 2)
        innerH = (tonumber(data.barWidth) or 0) - (BAR_BORDER * 2)
    else
        innerW = (tonumber(data and data.barWidth) or 0) - (BAR_BORDER * 2)
        innerH = (tonumber(data and data.barHeight) or 0) - (BAR_BORDER * 2)
    end
    if innerW < 0 then innerW = 0 end
    if innerH < 0 then innerH = 0 end

    frame.fill:ClearAllPoints()
    if data.orientation == "Vertical" then
        if frame.fill.SetTexCoord then
            -- rotate texture so vertical bars use vertical texture flow
            if data.direction == "From down to up" then
                -- 90° CCW
                frame.fill:SetTexCoord(1, 0, 0, 0, 1, 1, 0, 1)
            else
                -- 90° CW
                frame.fill:SetTexCoord(0, 1, 1, 1, 0, 0, 1, 0)
            end
        end
        local fh = math.floor(innerH * pct + 0.5)
        if fh < 1 and pct > 0 then fh = 1 end
        if fh <= 0 then
            frame.fill:Hide()
            return
        end
        frame.fill:Show()
        if data.direction == "From down to up" then
            frame.fill:SetPoint("BOTTOMLEFT", frame.bar, "BOTTOMLEFT", 0, 0)
            frame.fill:SetPoint("BOTTOMRIGHT", frame.bar, "BOTTOMRIGHT", 0, 0)
            frame.fill:SetHeight(fh)
        else
            frame.fill:SetPoint("TOPLEFT", frame.bar, "TOPLEFT", 0, 0)
            frame.fill:SetPoint("TOPRIGHT", frame.bar, "TOPRIGHT", 0, 0)
            frame.fill:SetHeight(fh)
        end
    else
        if frame.fill.SetTexCoord then
            if data.direction == "Left to right" then
                frame.fill:SetTexCoord(0, 1, 0, 1)
            else
                frame.fill:SetTexCoord(1, 0, 0, 1)
            end
        end
        local fw = math.floor(innerW * pct + 0.5)
        if fw < 1 and pct > 0 then fw = 1 end
        if fw <= 0 then
            frame.fill:Hide()
            return
        end
        frame.fill:Show()
        if data.direction == "Left to right" then
            frame.fill:SetPoint("TOPLEFT", frame.bar, "TOPLEFT", 0, 0)
            frame.fill:SetPoint("BOTTOMLEFT", frame.bar, "BOTTOMLEFT", 0, 0)
            frame.fill:SetWidth(fw)
        else
            frame.fill:SetPoint("TOPRIGHT", frame.bar, "TOPRIGHT", 0, 0)
            frame.fill:SetPoint("BOTTOMRIGHT", frame.bar, "BOTTOMRIGHT", 0, 0)
            frame.fill:SetWidth(fw)
        end
    end
end

local function DA_BarPassesExtraConditions(data)
    if data.powerOnly then
        local cur = UnitMana and UnitMana("player") or 0
        local max = UnitManaMax and UnitManaMax("player") or 0
        local pct = (max and max > 0) and ((cur / max) * 100) or 0
        local val = tonumber(data.powerValue) or 0
        if not DA_BarCompare(pct, data.powerComp or ">=", val) then
            return false
        end
    end

    if data.hpMode == "my" or data.hpMode == "target" then
        local unit = (data.hpMode == "target") and "target" or "player"
        if unit == "target" and UnitExists and not UnitExists("target") then
            return false
        end
        local cur = UnitHealth and UnitHealth(unit) or 0
        local max = UnitHealthMax and UnitHealthMax(unit) or 0
        local pct = (max and max > 0) and ((cur / max) * 100) or 0
        local val = tonumber(data.hpValue) or 0
        if not DA_BarCompare(pct, data.hpComp or ">=", val) then
            return false
        end
    end

    return true
end

---------------------------------------------------------------
-- DoiteBars.CreateOrUpdateBar(key, data)
---------------------------------------------------------------
function DoiteBars.CreateOrUpdateBar(key, data)
    if not key or not data then return nil end
    DA_BarApplyDefaults(data)

    local globalName = "DoiteBar_" .. key
    local f = barFrames[key] or _G[globalName]

    local w = data.barWidth
    local h = data.barHeight
    local drawW, drawH = w, h
    if data.orientation == "Vertical" then
        drawW, drawH = h, w
    end

    if not f then
        f = CreateFrame("Frame", globalName, UIParent)
        f:SetFrameStrata("MEDIUM")
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetWidth(drawW)
        f:SetHeight(drawH)

        -- Background
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints(f)
        f.bg:SetTexture(0, 0, 0, 1)

        -- Fill bar
        f.bar = CreateFrame("Frame", nil, f)
        f.bar:SetPoint("TOPLEFT",     f, "TOPLEFT",     BAR_BORDER, -BAR_BORDER)
        f.bar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -BAR_BORDER, BAR_BORDER)
        f.fill = f.bar:CreateTexture(nil, "ARTWORK")
        f.fill:SetTexture(data.fillTexture)
        f.fill:SetAllPoints(f.bar)

        -- Label
        f.label = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.label:SetAllPoints(f.bar)
        f.label:SetJustifyH("CENTER")
        f.label:SetJustifyV("MIDDLE")

        f._daKey = key

        f:SetScript("OnDragStart", function()
            local fk = this._daKey
            local ek = _G["DoiteEdit_CurrentKey"]
            if not ek or ek ~= fk then return end
            _G["DoiteUI_Dragging"] = true
            this:StartMoving()
            this._daDragging = true
        end)

        f:SetScript("OnDragStop", function()
            this:StopMovingOrSizing()
            this._daDragging = nil
            _G["DoiteUI_Dragging"] = false

            local fk = this._daKey
            if not fk then return end

            local rScale = UIParent:GetEffectiveScale()
            local rX, rY = UIParent:GetCenter()
            rX, rY = rX * rScale, rY * rScale

            local pScale = this:GetEffectiveScale()
            local pX, pY = this:GetCenter()
            pX, pY = pX * pScale, pY * pScale

            local x = math.floor((pX - rX) / pScale * 10 + 0.5) / 10
            local y = math.floor((pY - rY) / pScale * 10 + 0.5) / 10

            local d = DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[fk]
            if d then
                d.offsetX = x
                d.offsetY = y
            end
        end)

        barFrames[key] = f
        _G[globalName] = f
    end

    -- Always enforce current fill texture, even for already-created bars.
    if f.fill and f.fill.SetTexture then
        f.fill:SetTexture(data.fillTexture)
    end

    -- Apply size
    f:SetWidth(drawW)
    f:SetHeight(drawH)

    -- Apply position
    if not f._daDragging then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", data.offsetX, data.offsetY)
    end

    -- Scale / alpha
    f:SetScale(data.scale)
    f:SetAlpha(data.alpha)

    -- Background colour
    f.bg:SetTexture(data.bgR, data.bgG, data.bgB, data.bgAlpha)

    -- Label font
    if f.label and f.label.SetFont then
        f.label:SetFont("Fonts\\FRIZQT__.TTF", data.fontSize, "OUTLINE")
    end

    -- Label position
    f.label:ClearAllPoints()
    local tp = data.textPosition or "Center"
    if tp == "Center" then
        f.label:SetAllPoints(f.bar)
        f.label:SetJustifyH("CENTER")
        f.label:SetJustifyV("MIDDLE")
    elseif tp == "TopLeft" then
        f.label:SetPoint("TOPLEFT", f.bar, "TOPLEFT", 2, -2)
        f.label:SetJustifyH("LEFT")
        f.label:SetJustifyV("TOP")
    elseif tp == "TopRight" then
        f.label:SetPoint("TOPRIGHT", f.bar, "TOPRIGHT", -2, -2)
        f.label:SetJustifyH("RIGHT")
        f.label:SetJustifyV("TOP")
    elseif tp == "BottomLeft" then
        f.label:SetPoint("BOTTOMLEFT", f.bar, "BOTTOMLEFT", 2, 2)
        f.label:SetJustifyH("LEFT")
        f.label:SetJustifyV("BOTTOM")
    elseif tp == "BottomRight" then
        f.label:SetPoint("BOTTOMRIGHT", f.bar, "BOTTOMRIGHT", -2, 2)
        f.label:SetJustifyH("RIGHT")
        f.label:SetJustifyV("BOTTOM")
    elseif tp == "Left" then
        f.label:SetPoint("LEFT", f.bar, "LEFT", 2, 0)
        f.label:SetJustifyH("LEFT")
        f.label:SetJustifyV("MIDDLE")
    elseif tp == "Right" then
        f.label:SetPoint("RIGHT", f.bar, "RIGHT", -2, 0)
        f.label:SetJustifyH("RIGHT")
        f.label:SetJustifyV("MIDDLE")
    elseif tp == "OutsideLeft" then
        f.label:SetPoint("RIGHT", f.bar, "LEFT", -2, 0)
        f.label:SetJustifyH("RIGHT")
        f.label:SetJustifyV("MIDDLE")
    elseif tp == "OutsideRight" then
        f.label:SetPoint("LEFT", f.bar, "RIGHT", 2, 0)
        f.label:SetJustifyH("LEFT")
        f.label:SetJustifyV("MIDDLE")
    elseif tp == "OutsideTop" then
        f.label:SetPoint("BOTTOM", f.bar, "TOP", 0, 2)
        f.label:SetJustifyH("CENTER")
        f.label:SetJustifyV("BOTTOM")
    elseif tp == "OutsideBottom" then
        f.label:SetPoint("TOP", f.bar, "BOTTOM", 0, -2)
        f.label:SetJustifyH("CENTER")
        f.label:SetJustifyV("TOP")
    elseif tp == "OutsideTopLeft" then
        if data.orientation == "Vertical" then
            f.label:SetPoint("TOPRIGHT", f.bar, "TOPLEFT", -2, 0)
            f.label:SetJustifyH("RIGHT")
            f.label:SetJustifyV("TOP")
        else
            f.label:SetPoint("BOTTOMLEFT", f.bar, "TOPLEFT", 0, 2)
            f.label:SetJustifyH("LEFT")
            f.label:SetJustifyV("BOTTOM")
        end
    elseif tp == "OutsideTopRight" then
        if data.orientation == "Vertical" then
            f.label:SetPoint("TOPLEFT", f.bar, "TOPRIGHT", 2, 0)
            f.label:SetJustifyH("LEFT")
            f.label:SetJustifyV("TOP")
        else
            f.label:SetPoint("BOTTOMRIGHT", f.bar, "TOPRIGHT", 0, 2)
            f.label:SetJustifyH("RIGHT")
            f.label:SetJustifyV("BOTTOM")
        end
    elseif tp == "OutsideBottomLeft" then
        if data.orientation == "Vertical" then
            f.label:SetPoint("BOTTOMRIGHT", f.bar, "BOTTOMLEFT", -2, 0)
            f.label:SetJustifyH("RIGHT")
            f.label:SetJustifyV("BOTTOM")
        else
            f.label:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 0, -2)
            f.label:SetJustifyH("LEFT")
            f.label:SetJustifyV("TOP")
        end
    elseif tp == "OutsideBottomRight" or tp == "OutsideBottom Right" then
        if data.orientation == "Vertical" then
            f.label:SetPoint("BOTTOMLEFT", f.bar, "BOTTOMRIGHT", 2, 0)
            f.label:SetJustifyH("LEFT")
            f.label:SetJustifyV("BOTTOM")
        else
            f.label:SetPoint("TOPRIGHT", f.bar, "BOTTOMRIGHT", 0, -2)
            f.label:SetJustifyH("RIGHT")
            f.label:SetJustifyV("TOP")
        end
    else
        f.label:SetAllPoints(f.bar)
        f.label:SetJustifyH("CENTER")
        f.label:SetJustifyV("MIDDLE")
    end
    if f.label and f.label.SetRotation then
        if data.orientation == "Vertical" and not BE_IsOutsideTextPosition(tp) then
            f.label:SetRotation(1.57079632679)
        else
            f.label:SetRotation(0)
        end
    end

    -- Edit mode mouse
    local editKey = _G["DoiteEdit_CurrentKey"]
    if editKey and editKey == key then
        f:EnableMouse(true)
    else
        f:EnableMouse(false)
    end

    return f
end

---------------------------------------------------------------
-- DoiteBars.RefreshBar(key, data)
---------------------------------------------------------------
function DoiteBars.RefreshBar(key, data)
    if not key or not data then return end
    DA_BarApplyDefaults(data)

    local f = barFrames[key] or _G["DoiteBar_" .. key]
    if not f or not f.bar then return end

    -- Visibility (combat state)
    local inCombat = UnitAffectingCombat and UnitAffectingCombat("player") or false
    local visible  = (inCombat and data.inCombat) or ((not inCombat) and data.outCombat)
    if visible and not DA_BarPassesExtraConditions(data) then
        visible = false
    end
    if not visible then
        f:Hide()
        return
    end
    f:Show()

    local kindKey = data.barType or "Powerbar"
    local kind    = DoiteBars.Kinds[kindKey]
    if not kind then return end

    local cur, max = kind.getValues()

    -- Bar colour
    local r, g, b
    if data.barR and data.barR >= 0 then
        r, g, b = data.barR, data.barG, data.barB
    elseif kindKey == "Powerbar" then
        r, g, b = DA_BarColorForPowerType()
    else
        r, g, b = kind.r, kind.g, kind.b
    end
    if f.fill and f.fill.SetVertexColor then
        f.fill:SetVertexColor(r, g, b, data.barAlpha or 1)
    end

    -- Fill value
    DA_BarApplyFill(f, data, cur, max)

    -- Label text
    if f.label then
        local fmt = data.textFormat or "Actual"
        local txt
        if fmt == "Percent" then
            local pct = (max > 0) and math.floor(cur / max * 100 + 0.5) or 0
            txt = tostring(pct) .. "%"
        elseif fmt == "Short" then
            local function shorten(n)
                if n >= 1000 then return string.format("%.1fk", n / 1000) end
                return tostring(n)
            end
            txt = shorten(cur) .. " / " .. shorten(max)
        else
            txt = tostring(cur) .. " / " .. tostring(max)
        end
        f.label:SetText(txt)
    end
end

---------------------------------------------------------------
-- DoiteBars.RefreshAll()
---------------------------------------------------------------
function DoiteBars.RefreshAll()
    if not DoiteAurasDB or not DoiteAurasDB.spells then return end
    for key, data in pairs(DoiteAurasDB.spells) do
        if data and data.type == "Bar" then
            local f = DoiteBars.CreateOrUpdateBar(key, data)
            if f then DoiteBars.RefreshBar(key, data) end
        end
    end
end

---------------------------------------------------------------
-- DoiteBars.HideBar / DestroyBar / GetBarFrame
---------------------------------------------------------------
function DoiteBars.HideBar(key)
    if not key then return end
    local f = barFrames[key] or _G["DoiteBar_" .. key]
    if f then f:Hide() end
end

function DoiteBars.DestroyBar(key)
    if not key then return end
    local f = barFrames[key] or _G["DoiteBar_" .. key]
    if f then
        f:Hide()
        barFrames[key] = nil
    end
end

function DoiteBars.GetBarFrame(key)
    return barFrames[key] or _G["DoiteBar_" .. key]
end

---------------------------------------------------------------
-- Event-driven bar refresh
---------------------------------------------------------------
local function DA_HasBarKind(kindKey)
    if not DoiteAurasDB or not DoiteAurasDB.spells then return false end
    local key, data
    for key, data in pairs(DoiteAurasDB.spells) do
        if data and data.type == "Bar" and data.barType == kindKey then
            return true
        end
    end
    return false
end

local function DA_RefreshBarsByKind(kindKey)
    if not DoiteAurasDB or not DoiteAurasDB.spells then return end
    local key, data, f
    for key, data in pairs(DoiteAurasDB.spells) do
        if data and data.type == "Bar" and data.barType == kindKey then
            f = DoiteBars.CreateOrUpdateBar(key, data)
            if f then
                DoiteBars.RefreshBar(key, data)
            end
        end
    end
end

local barEventFrame = CreateFrame("Frame", "DoiteBarsEventFrame")
barEventFrame:RegisterEvent("UNIT_HEALTH_GUID")
barEventFrame:RegisterEvent("UNIT_MANA_GUID")
barEventFrame:RegisterEvent("UNIT_RAGE_GUID")
barEventFrame:RegisterEvent("UNIT_ENERGY_GUID")
barEventFrame:RegisterEvent("UNIT_FOCUS_GUID")
barEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
barEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
barEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")

barEventFrame:SetScript("OnEvent", function()
    if _G["DoiteAuras_HardDisabled"] == true then return end

    if event == "UNIT_HEALTH_GUID" then
        if not DA_HasBarKind("Healthbar") then return end
        if arg2 ~= 1 then return end -- isPlayer
        DA_RefreshBarsByKind("Healthbar")
        return
    end

    if event == "UNIT_MANA_GUID" or event == "UNIT_RAGE_GUID" or event == "UNIT_ENERGY_GUID" or event == "UNIT_FOCUS_GUID" then
        if not DA_HasBarKind("Powerbar") then return end
        if arg2 ~= 1 then return end -- isPlayer
        DA_RefreshBarsByKind("Powerbar")
        return
    end

    if event == "UPDATE_SHAPESHIFT_FORM" then
        if not DA_HasBarKind("Powerbar") then return end
        DA_RefreshBarsByKind("Powerbar")
        return
    end

    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        DoiteBars.RefreshAll()
        return
    end
end)

-- Initial render on login
local barWorldFrame = CreateFrame("Frame", "DoiteBarsWorldFrame")
barWorldFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
barWorldFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        DoiteBars.RefreshAll()
    end
end)

---------------------------------------------------------------
-- BAR EDIT PANEL — injected directly into condFrame
---------------------------------------------------------------

-- Key currently being edited via injected panel
local _beKey = nil

local function BE_RefreshEditedBar()
    if not _beKey then return end
    local d = DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[_beKey]
    if not d then return end
    DoiteBars.CreateOrUpdateBar(_beKey, d)
    DoiteBars.RefreshBar(_beKey, d)
end

local function BE_GetDirectionOptions(orientation)
    if orientation == "Vertical" then
        return { "From down to up", "From up to down" }
    end
    return { "Left to right", "Right to left" }
end

local BE_TextureChoices = {
    { text = "UI-StatusBar",            value = "Interface\\TargetingFrame\\UI-StatusBar" },
    { text = "WHITE8X8",                value = "Interface\\Buttons\\WHITE8X8" },
    { text = "pfUI bar",                value = "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar" },
    { text = "pfUI bar_tukui",          value = "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_tukui" },
    { text = "pfUI bar_elvui",          value = "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_elvui" },
    { text = "pfUI bar_gradient",       value = "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_gradient" },
    { text = "pfUI bar_striped",        value = "Interface\\AddOns\\DoiteAuras\\Textures\\pfUI\\bar_striped" },
    { text = "UI-Character-Skills-Bar", value = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
}

BE_IsOutsideTextPosition = function(tp)
    return tp == "OutsideLeft"
        or tp == "OutsideRight"
        or tp == "OutsideTopLeft"
        or tp == "OutsideTopRight"
        or tp == "OutsideTop"
        or tp == "OutsideBottom"
        or tp == "OutsideBottomLeft"
        or tp == "OutsideBottomRight"
        or tp == "OutsideBottom Right"
end

local function BE_SetDropdownTextColor(dd, r, g, b)
    if not dd then return end
    local name = dd.GetName and dd:GetName()
    if not name then return end
    local t = _G[name .. "Text"]
    if t and t.SetTextColor then
        t:SetTextColor(r or 1, g or 1, b or 1)
    end
end

local function BE_InitDirectionDropdown(dd, data)
    if not dd then return end
    local opts = BE_GetDirectionOptions(data and data.orientation)
    local cur = data and data.direction or opts[1]
    local valid = false
    local i
    for i = 1, table.getn(opts) do
        if opts[i] == cur then valid = true break end
    end
    if not valid then
        cur = DA_DefaultDirectionForOrientation(data and data.orientation)
        if data then data.direction = cur end
    end

    if UIDropDownMenu_Initialize then
        UIDropDownMenu_Initialize(dd, function()
            local j
            for j = 1, table.getn(opts) do
                local opt = opts[j]
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt
                info.value = opt
                info.checked = (opt == cur)
                info.func = function(button)
                    local picked = (button and button.value) or opt
                    if _beKey and DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[_beKey] then
                        DoiteAurasDB.spells[_beKey].direction = picked
                    end
                    UIDropDownMenu_SetSelectedValue(dd, picked)
                    UIDropDownMenu_SetText(picked, dd)
                    BE_RefreshEditedBar()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
    end
    UIDropDownMenu_SetSelectedValue(dd, cur)
    UIDropDownMenu_SetText(cur, dd)
    BE_SetDropdownTextColor(dd, 1, 1, 1)
end

local function BE_InitTextureDropdown(dd, data)
    if not dd then return end
    local cur = (data and data.fillTexture) or DA_DEFAULT_BAR_TEXTURE
    if not DA_IsTextureValid(cur) then
        cur = DA_DEFAULT_BAR_TEXTURE
        if data then data.fillTexture = cur end
    end
    if UIDropDownMenu_Initialize then
        UIDropDownMenu_Initialize(dd, function()
            local j
            for j = 1, table.getn(BE_TextureChoices) do
                local opt = BE_TextureChoices[j]
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt.text
                info.value = opt.value
                info.checked = (opt.value == cur)
                info.func = function(button)
                    local picked = (button and button.value) or opt.value
                    if _beKey and DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[_beKey] then
                        DoiteAurasDB.spells[_beKey].fillTexture = picked
                    end
                    UIDropDownMenu_SetSelectedValue(dd, picked)
                    local name = opt.text
                    local k
                    for k = 1, table.getn(BE_TextureChoices) do
                        if BE_TextureChoices[k].value == picked then
                            name = BE_TextureChoices[k].text
                            break
                        end
                    end
                    UIDropDownMenu_SetText(name, dd)
                    BE_RefreshEditedBar()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
    end
    UIDropDownMenu_SetSelectedValue(dd, cur)
    local shown = "pfUI bar_tukui"
    local i
    for i = 1, table.getn(BE_TextureChoices) do
        if BE_TextureChoices[i].value == cur then
            shown = BE_TextureChoices[i].text
            break
        end
    end
    UIDropDownMenu_SetText(shown, dd)
    BE_SetDropdownTextColor(dd, 1, 1, 1)
end

local function BE_UpdateSizeSliderLabels(data)
    local wTxt = _G["DoiteBarsEdit_SliderWText"]
    local hTxt = _G["DoiteBarsEdit_SliderHText"]
    if data and data.orientation == "Vertical" then
        if wTxt and wTxt.SetText then wTxt:SetText("Height") end
        if hTxt and hTxt.SetText then hTxt:SetText("Width") end
    else
        if wTxt and wTxt.SetText then wTxt:SetText("Width") end
        if hTxt and hTxt.SetText then hTxt:SetText("Height") end
    end
end

local function BE_EnsureTopDropdowns(cf)
    if not cf then return end
    if cf.beOrientationDD then return end

    cf.beOrientationLabel = cf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cf.beOrientationLabel:SetPoint("TOPLEFT", cf, "TOPLEFT", 20, -68)
    cf.beOrientationLabel:SetText("Orientation")
    if cf.beOrientationLabel.SetTextColor then cf.beOrientationLabel:SetTextColor(1, 0.82, 0) end

    cf.beOrientationDD = CreateFrame("Frame", "DoiteBarsEdit_OrientationDD", cf, "UIDropDownMenuTemplate")
    cf.beOrientationDD:SetPoint("TOPLEFT", cf, "TOPLEFT", 105, -63)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(130, cf.beOrientationDD) end

    cf.beDirectionLabel = cf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cf.beDirectionLabel:SetPoint("TOPLEFT", cf, "TOPLEFT", 20, -96)
    cf.beDirectionLabel:SetText("Direction")
    if cf.beDirectionLabel.SetTextColor then cf.beDirectionLabel:SetTextColor(1, 0.82, 0) end

    cf.beDirectionDD = CreateFrame("Frame", "DoiteBarsEdit_DirectionDD", cf, "UIDropDownMenuTemplate")
    cf.beDirectionDD:SetPoint("TOPLEFT", cf, "TOPLEFT", 105, -91)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(130, cf.beDirectionDD) end

    cf.beTextureLabel = cf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cf.beTextureLabel:SetPoint("TOPLEFT", cf, "TOPLEFT", 20, -124)
    cf.beTextureLabel:SetText("Texture")
    if cf.beTextureLabel.SetTextColor then cf.beTextureLabel:SetTextColor(1, 0.82, 0) end

    cf.beTextureDD = CreateFrame("Frame", "DoiteBarsEdit_TextureDD", cf, "UIDropDownMenuTemplate")
    cf.beTextureDD:SetPoint("TOPLEFT", cf, "TOPLEFT", 105, -119)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(130, cf.beTextureDD) end
end

---------------------------------------------------------------
-- Slider helper; parents to a given frame, mirrors MakeSlider
---------------------------------------------------------------
local function BE_StylePlainEditBox(editBox, justify)
    if not editBox then return end
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("GameFontNormalSmall")
    editBox:SetJustifyH(justify or "CENTER")
    if editBox.SetTextInsets then
        editBox:SetTextInsets(6, 6, 0, 0)
    end
    if editBox.SetBackdrop then
        editBox:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        editBox:SetBackdropColor(0, 0, 0, 0.85)
        editBox:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
end

local function BE_MakeSlider(parent, name, text, x, y, width, minVal, maxVal, step)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetWidth(width)
    s:SetHeight(16)
    s:SetMinMaxValues(minVal, maxVal)
    s:SetValueStep(step)
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local txt  = _G[s:GetName() .. "Text"]
    local low  = _G[s:GetName() .. "Low"]
    local high = _G[s:GetName() .. "High"]
    if txt  then txt:SetText(text);             txt:SetFontObject("GameFontNormalSmall") end
    if low  then low:SetText(tostring(minVal));  low:SetFontObject("GameFontNormalSmall") end
    if high then high:SetText(tostring(maxVal)); high:SetFontObject("GameFontNormalSmall") end

    local eb = CreateFrame("EditBox", name .. "_EditBox", parent)
    eb:SetWidth(38); eb:SetHeight(18)
    eb:SetPoint("TOP", s, "BOTTOM", 3, -8)
    eb:SetText("0")
    BE_StylePlainEditBox(eb, "CENTER")
    eb.slider    = s
    eb._updating = false

    s:SetScript("OnValueChanged", function()
        if this._isSyncing then return end
        local v = math.floor((this:GetValue() or 0) + 0.5)
        if eb and not eb._updating then
            eb._updating = true
            eb:SetText(tostring(v))
            eb._updating = false
        end
        if this.updateFunc then this.updateFunc(v) end
    end)

    s:SetScript("OnMouseDown", function() _G["DoiteUI_Dragging"] = true end)
    s:SetScript("OnMouseUp", function()
        _G["DoiteUI_Dragging"] = false
        if DoiteEdit_FlushHeavy then DoiteEdit_FlushHeavy() end
    end)

    local function CommitEB(box)
        if not box or not box.slider then return end
        local val = tonumber(box:GetText())
        if not val then
            box:SetText(tostring(math.floor((box.slider:GetValue() or 0) + 0.5)))
        else
            val = math.max(minVal, math.min(maxVal, val))
            box._updating = true
            box.slider:SetValue(val)
            box._updating = false
        end
    end

    eb:SetScript("OnTextChanged", function()
        if this._updating then return end
        local num = tonumber(this:GetText())
        if not num then return end
        num = math.max(minVal, math.min(maxVal, num))
        this._updating = true
        this.slider:SetValue(num)
        this._updating = false
    end)
    eb:SetScript("OnEnterPressed", function() CommitEB(this); this:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function()
        this:ClearFocus()
        this._updating = true
        this:SetText(tostring(math.floor((this.slider:GetValue() or 0) + 0.5)))
        this._updating = false
    end)
    eb:SetScript("OnEditFocusLost", function() CommitEB(this) end)

    return s, eb
end

---------------------------------------------------------------
-- Section header + separator
---------------------------------------------------------------
local function BE_MakeHeader(parent, y, labelText)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    holder:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, y)
    holder:SetHeight(16)

    local label = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    label:SetJustifyH("LEFT")
    label:SetText("|cffffffff" .. (labelText or "") .. "|r")

    local lineY = -8
    local lineL = holder:CreateTexture(nil, "ARTWORK")
    lineL:SetHeight(1)
    lineL:SetTexture(1, 1, 1)
    if lineL.SetVertexColor then lineL:SetVertexColor(1, 1, 1, 0.25) end
    lineL:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, lineY)
    lineL:SetPoint("TOPRIGHT", label, "TOPLEFT", -6, lineY)

    local lineR = holder:CreateTexture(nil, "ARTWORK")
    lineR:SetHeight(1)
    lineR:SetTexture(1, 1, 1)
    if lineR.SetVertexColor then lineR:SetVertexColor(1, 1, 1, 0.25) end
    lineR:SetPoint("TOPLEFT", label, "TOPRIGHT", 6, lineY)
    lineR:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, lineY)
end

local function BE_MakeDropdown(parent, name, x, y, width, options, selectedValue, onPick)
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    dd._selectedValue = selectedValue
    dd:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 16, y)
    if UIDropDownMenu_SetWidth then
        UIDropDownMenu_SetWidth(width, dd)
    end

    if UIDropDownMenu_Initialize then
        UIDropDownMenu_Initialize(dd, function()
            local i
            for i = 1, table.getn(options) do
                local opt = options[i]
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt
                info.value = opt
                info.checked = (dd._selectedValue == opt)
                info.func = function(button)
                    local picked = (button and button.value) or opt
                    dd._selectedValue = picked
                    if UIDropDownMenu_SetSelectedValue then
                        UIDropDownMenu_SetSelectedValue(dd, picked)
                    end
                    if UIDropDownMenu_SetText then
                        UIDropDownMenu_SetText(picked, dd)
                    end
                    if onPick then onPick(picked) end
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
    end

    if UIDropDownMenu_SetSelectedValue then
        UIDropDownMenu_SetSelectedValue(dd, selectedValue)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(selectedValue or "", dd)
    end
    if _GoldifyDD then
        _GoldifyDD(dd)
    end
    return dd
end

---------------------------------------------------------------
-- Color picker helpers
---------------------------------------------------------------
local function BE_HideColorPicker(cancelCallback)
    if not ColorPickerFrame then return end
    if cancelCallback then
        _G["DoiteBars_ColorPickerNonce"] = (_G["DoiteBars_ColorPickerNonce"] or 0) + 1
    end
    if ColorPickerFrame.Hide then ColorPickerFrame:Hide() end
end

local function BE_ShowColorPicker(r, g, b, a, changedCallback)
    if not ColorPickerFrame then return end
    if not ColorPickerFrame._daMovable then
        ColorPickerFrame._daMovable = true
        if ColorPickerFrame.SetMovable then ColorPickerFrame:SetMovable(true) end
        if ColorPickerFrame.EnableMouse then ColorPickerFrame:EnableMouse(true) end
        if ColorPickerFrame.SetClampedToScreen then ColorPickerFrame:SetClampedToScreen(true) end

        if not ColorPickerFrame._daDragHandle then
            local h = CreateFrame("Frame", nil, ColorPickerFrame)
            h:SetPoint("TOPLEFT", ColorPickerFrame, "TOPLEFT", 0, 0)
            h:SetPoint("TOPRIGHT", ColorPickerFrame, "TOPRIGHT", 0, 0)
            h:SetHeight(20)
            h:EnableMouse(true)
            h:RegisterForDrag("LeftButton")
            if h.SetFrameStrata then h:SetFrameStrata("TOOLTIP") end
            if h.SetFrameLevel and ColorPickerFrame.GetFrameLevel then
                h:SetFrameLevel((ColorPickerFrame:GetFrameLevel() or 10000) + 20)
            end
            h:SetScript("OnMouseDown", function()
                if ColorPickerFrame and ColorPickerFrame.StartMoving then
                    ColorPickerFrame:StartMoving()
                end
            end)
            h:SetScript("OnMouseUp", function()
                if ColorPickerFrame and ColorPickerFrame.StopMovingOrSizing then
                    ColorPickerFrame:StopMovingOrSizing()
                end
            end)
            h:SetScript("OnDragStart", function()
                if ColorPickerFrame and ColorPickerFrame.StartMoving then
                    ColorPickerFrame:StartMoving()
                end
            end)
            h:SetScript("OnDragStop", function()
                if ColorPickerFrame and ColorPickerFrame.StopMovingOrSizing then
                    ColorPickerFrame:StopMovingOrSizing()
                end
            end)
            ColorPickerFrame._daDragHandle = h
        end
    end
    local h = ColorPickerFrame._daDragHandle
    if h and h.SetHeight and ColorPickerFrame.GetHeight then
        local hh = math.floor((ColorPickerFrame:GetHeight() or 180) * 0.10 + 0.5)
        if hh < 16 then hh = 16 end
        h:SetHeight(hh)
    end
    _G["DoiteBars_ColorPickerNonce"] = (_G["DoiteBars_ColorPickerNonce"] or 0) + 1
    local myNonce = _G["DoiteBars_ColorPickerNonce"]
    ColorPickerFrame:SetColorRGB(r or 1, g or 1, b or 1)
    ColorPickerFrame.hasOpacity = (a ~= nil)
    ColorPickerFrame.opacity = a
    ColorPickerFrame.previousValues = { r or 1, g or 1, b or 1, a }
    ColorPickerFrame.func = function(restore)
        if myNonce ~= _G["DoiteBars_ColorPickerNonce"] then return end
        changedCallback(restore)
    end
    ColorPickerFrame.opacityFunc = ColorPickerFrame.func
    ColorPickerFrame.cancelFunc = ColorPickerFrame.func
    local function BE_BringColorPickerToFront()
        if ColorPickerFrame.SetToplevel then ColorPickerFrame:SetToplevel(true) end
        if ColorPickerFrame.SetParent then ColorPickerFrame:SetParent(UIParent) end
        if ColorPickerFrame.SetFrameStrata then ColorPickerFrame:SetFrameStrata("TOOLTIP") end
        if ColorPickerFrame.SetFrameLevel then ColorPickerFrame:SetFrameLevel(10000) end
        if ColorPickerFrame.Raise then ColorPickerFrame:Raise() end

        local base = ColorPickerFrame.GetFrameLevel and ColorPickerFrame:GetFrameLevel() or 10000

        if ColorPickerFrame._daDragHandle then
            if ColorPickerFrame._daDragHandle.SetFrameStrata then
                ColorPickerFrame._daDragHandle:SetFrameStrata("TOOLTIP")
            end
            if ColorPickerFrame._daDragHandle.SetFrameLevel then
                ColorPickerFrame._daDragHandle:SetFrameLevel(base + 50)
            end
            if ColorPickerFrame._daDragHandle.Raise then
                ColorPickerFrame._daDragHandle:Raise()
            end
        end

        local children = {
            _G["OpacitySliderFrame"],
            _G["ColorPickerOkayButton"],
            _G["ColorPickerCancelButton"],
        }
        local i
        for i = 1, table.getn(children) do
            local cf = children[i]
            if cf then
                if cf.SetFrameStrata then cf:SetFrameStrata("TOOLTIP") end
                if cf.SetFrameLevel then cf:SetFrameLevel(base + 5 + i) end
                if cf.SetToplevel then cf:SetToplevel(true) end
                if cf.Raise then cf:Raise() end
            end
        end
    end

    BE_BringColorPickerToFront()
    BE_HideColorPicker(false)
    ColorPickerFrame:Show()
    BE_BringColorPickerToFront()
end

local function BE_SetSwatchColor(btn, r, g, b, a)
    if not btn or not btn.swatch then return end
    btn.swatch:SetTexture(r or 1, g or 1, b or 1, a or 1)
end

local function BE_MakeColorSwatch(parent, x, y, labelText, onClick)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    lbl:SetText(labelText)

    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(22)
    btn:SetHeight(22)
    btn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true, tileSize = 8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    btn:SetBackdropColor(0, 0, 0, 1)
    btn:SetBackdropBorderColor(1, 1, 1, 1)

    btn.swatch = btn:CreateTexture(nil, "ARTWORK")
    btn.swatch:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
    btn.swatch:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    btn.swatch:SetTexture(1, 1, 1, 1)

    btn:SetScript("OnClick", function()
        if onClick then onClick() end
    end)
    return btn, lbl
end

---------------------------------------------------------------
-- BE_BuildContainer(cf)
-- Creates the scrollable container as a child of condFrame.
-- cf = The main "condFrame" (parent window)
---------------------------------------------------------------
local function BE_BuildContainer(cf)
    -- Defines boundaries of settings area
    local cW = cf:GetWidth() - 43
    local cH = 190

    -- Container: anchor for scroll area
    local container = CreateFrame("Frame", "DoiteBarsEditContainer", cf)
    container:SetWidth(cW)
    container:SetHeight(cH)
    container:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -173)
    container:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
    })
    container:SetBackdropColor(0, 0, 0, 0.7)

    -- Scrollframe
    -- Match the same outside-scrollbar placement pattern used in DoiteEdit list container.
    local scrollFrame = CreateFrame("ScrollFrame", "DoiteBarsEditScroll", container, "UIPanelScrollFrameTemplate")
    scrollFrame:SetWidth(cW - 20)
    scrollFrame:SetHeight(cH - 9)
    scrollFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -5)

    -- Enables mouse scrolling
    if scrollFrame.EnableMouseWheel then scrollFrame:EnableMouseWheel(true) end

    -- the content inside of the scrollframe
    local content = CreateFrame("Frame", "DoiteBarsEditContent", scrollFrame)
    content:SetWidth(cW - 20)
    content:SetHeight(1200) -- Increase/decrease this depending on the amount of options in the frame
    scrollFrame:SetScrollChild(content) -- tells scrollframe that it needs to move content

    -- returned for use in injectcontrolls.
    return container, content
end

---------------------------------------------------------------
-- BE_PopulateContent(content, key)
---------------------------------------------------------------
local function BE_PopulateContent(content, key)
    local data = DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key]
    if not data then return {} end
    DA_BarApplyDefaults(data)

    local sliderW = math.floor((content:GetWidth() - 70 - 16) / 3)
    if sliderW < 80 then sliderW = 80 end
    local baseX = 10
    local gap   = 8
    local col2Offset = 30
    local y     = -10
    local refs  = {}

    BE_MakeHeader(content, y, "VISIBILITY")
    y = y - 23

    refs.cbInCombat = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    refs.cbInCombat:SetWidth(20); refs.cbInCombat:SetHeight(20)
    refs.cbInCombat:SetPoint("TOPLEFT", content, "TOPLEFT", baseX, y)
    refs.cbInCombat:SetChecked(data.inCombat and 1 or 0)
    refs.lblIn = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.lblIn:SetPoint("LEFT", refs.cbInCombat, "RIGHT", 2, 0)
    refs.lblIn:SetText("Show in combat")
    refs.cbInCombat:SetScript("OnClick", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then
            d.inCombat = (this:GetChecked() == 1)
            if not d.inCombat and not d.outCombat then
                d.inCombat = true
                this:SetChecked(1)
            end
            BE_RefreshEditedBar()
        end
    end)

    refs.cbOutCombat = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    refs.cbOutCombat:SetWidth(20); refs.cbOutCombat:SetHeight(20)
    refs.cbOutCombat:SetPoint("TOPLEFT", content, "TOPLEFT", baseX + 110, y)
    refs.cbOutCombat:SetChecked(data.outCombat and 1 or 0)
    refs.lblOut = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.lblOut:SetPoint("LEFT", refs.cbOutCombat, "RIGHT", 0, 0)
    refs.lblOut:SetText("Show out of combat")
    refs.cbOutCombat:SetScript("OnClick", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then
            d.outCombat = (this:GetChecked() == 1)
            if not d.outCombat and not d.inCombat then
                d.outCombat = true
                this:SetChecked(1)
            end
            BE_RefreshEditedBar()
        end
    end)
    y = y - 30

    refs.cbPowerOnly = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    refs.cbPowerOnly:SetWidth(20); refs.cbPowerOnly:SetHeight(20)
    refs.cbPowerOnly:SetPoint("TOPLEFT", content, "TOPLEFT", baseX, y)
    refs.cbPowerOnly:SetChecked(data.powerOnly and 1 or 0)
    refs.cbPowerOnly.text = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.cbPowerOnly.text:SetPoint("LEFT", refs.cbPowerOnly, "RIGHT", 2, 0)
    refs.cbPowerOnly.text:SetText("Power")

    refs.powerCompDD = BE_MakeDropdown(content, "DoiteBarsEdit_PowerCompDD", baseX + 65, y + 3, 50, { ">=", "==", "<=" }, data.powerComp or ">=", function(picked)
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then
            d.powerComp = picked
            BE_RefreshEditedBar()
        end
    end)
    refs.powerValBox = CreateFrame("EditBox", nil, content)
    refs.powerValBox:SetWidth(40); refs.powerValBox:SetHeight(18)
    refs.powerValBox:SetPoint("TOPLEFT", content, "TOPLEFT", baseX + 160, y - 2)
    BE_StylePlainEditBox(refs.powerValBox, "CENTER")
    refs.powerValBox:SetTextColor(1, 0.82, 0)
    refs.powerValBox:SetText(tostring(tonumber(data.powerValue) or 0))
    refs.powerPctLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.powerPctLabel:SetPoint("LEFT", refs.powerValBox, "RIGHT", 4, 0)
    refs.powerPctLabel:SetText("(%)")

    local function BE_UpdatePowerWidgets()
        local d = (_beKey and DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[_beKey]) or data
        local show = (d and d.powerOnly) and true or false
        if show then
            refs.powerCompDD:Show(); refs.powerValBox:Show(); refs.powerPctLabel:Show()
        else
            refs.powerCompDD:Hide(); refs.powerValBox:Hide(); refs.powerPctLabel:Hide()
        end
    end

    refs.cbPowerOnly:SetScript("OnClick", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then
            d.powerOnly = (this:GetChecked() == 1)
            BE_UpdatePowerWidgets()
            BE_RefreshEditedBar()
        end
    end)
    refs.powerValBox:SetScript("OnEnterPressed", function() this:ClearFocus() end)
    refs.powerValBox:SetScript("OnEditFocusLost", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]; if not d then return end
        local v = tonumber(this:GetText()) or 0
        if v < 0 then v = 0 end
        if v > 100 then v = 100 end
        d.powerValue = v
        this:SetText(tostring(v))
        BE_RefreshEditedBar()
    end)
    BE_UpdatePowerWidgets()
    y = y - 30

    refs.cbMyHP = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    refs.cbMyHP:SetWidth(20); refs.cbMyHP:SetHeight(20)
    refs.cbMyHP:SetPoint("TOPLEFT", content, "TOPLEFT", baseX, y)
    refs.cbMyHP.text = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.cbMyHP.text:SetPoint("LEFT", refs.cbMyHP, "RIGHT", 2, 0)
    refs.cbMyHP.text:SetText("My HP")

    refs.cbTargetHP = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    refs.cbTargetHP:SetWidth(20); refs.cbTargetHP:SetHeight(20)
    refs.cbTargetHP:SetPoint("TOPLEFT", content, "TOPLEFT", baseX + 65, y)
    refs.cbTargetHP.text = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.cbTargetHP.text:SetPoint("LEFT", refs.cbTargetHP, "RIGHT", 2, 0)
    refs.cbTargetHP.text:SetText("Target HP")

    refs.hpCompDD = BE_MakeDropdown(content, "DoiteBarsEdit_HpCompDD", baseX + 145, y + 3, 50, { ">=", "==", "<=" }, data.hpComp or ">=", function(picked)
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then
            d.hpComp = picked
            BE_RefreshEditedBar()
        end
    end)

    refs.hpValBox = CreateFrame("EditBox", nil, content)
    refs.hpValBox:SetWidth(40); refs.hpValBox:SetHeight(18)
    refs.hpValBox:SetPoint("TOPLEFT", content, "TOPLEFT", baseX + 220, y - 2)
    BE_StylePlainEditBox(refs.hpValBox, "CENTER")
    refs.hpValBox:SetTextColor(1, 0.82, 0)
    refs.hpValBox:SetText(tostring(tonumber(data.hpValue) or 0))
    refs.hpPctLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.hpPctLabel:SetPoint("LEFT", refs.hpValBox, "RIGHT", 4, 0)
    refs.hpPctLabel:SetText("(%)")

    local function BE_UpdateHPWidgets()
        local d = (_beKey and DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[_beKey]) or data
        local mode = d and d.hpMode
        refs.cbMyHP:SetChecked(mode == "my" and 1 or 0)
        refs.cbTargetHP:SetChecked(mode == "target" and 1 or 0)
        local showExtra = (mode == "my" or mode == "target")
        if showExtra then
            refs.hpCompDD:Show(); refs.hpValBox:Show(); refs.hpPctLabel:Show()
        else
            refs.hpCompDD:Hide(); refs.hpValBox:Hide(); refs.hpPctLabel:Hide()
        end
    end

    refs.cbMyHP:SetScript("OnClick", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]; if not d then return end
        d.hpMode = (this:GetChecked() == 1) and "my" or nil
        BE_UpdateHPWidgets()
        BE_RefreshEditedBar()
    end)
    refs.cbTargetHP:SetScript("OnClick", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]; if not d then return end
        d.hpMode = (this:GetChecked() == 1) and "target" or nil
        BE_UpdateHPWidgets()
        BE_RefreshEditedBar()
    end)
    refs.hpValBox:SetScript("OnEnterPressed", function() this:ClearFocus() end)
    refs.hpValBox:SetScript("OnEditFocusLost", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]; if not d then return end
        local v = tonumber(this:GetText()) or 0
        if v < 0 then v = 0 end
        if v > 100 then v = 100 end
        d.hpValue = v
        this:SetText(tostring(v))
        BE_RefreshEditedBar()
    end)
    BE_UpdateHPWidgets()
    y = y - 35

    BE_MakeHeader(content, y, "POSITION & SIZE")
    y = y - 33

    local minX, maxX, minY, maxY = -1200, 1200, -1200, 1200
    local sX, _ = BE_MakeSlider(content, "DoiteBarsEdit_SliderX", "Horizontal Position", baseX, y, sliderW, minX, maxX, 1)
    local sY, _ = BE_MakeSlider(content, "DoiteBarsEdit_SliderY", "Vertical Position", baseX + sliderW + gap + col2Offset, y, sliderW, minY, maxY, 1)
    refs.sliderX = sX
    refs.sliderY = sY
    sX:SetValue(data.offsetX)
    sY:SetValue(data.offsetY)
    sX.updateFunc = function(v)
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then d.offsetX = v; DoiteBars.CreateOrUpdateBar(_beKey, d) end
    end
    sY.updateFunc = function(v)
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then d.offsetY = v; DoiteBars.CreateOrUpdateBar(_beKey, d) end
    end
    y = y - 70

    local sW, _ = BE_MakeSlider(content, "DoiteBarsEdit_SliderW", "Width",  baseX,                 y, sliderW, 20, 800, 1)
    local sH, _ = BE_MakeSlider(content, "DoiteBarsEdit_SliderH", "Height", baseX + sliderW + gap + col2Offset, y, sliderW, 4,  200, 1)
    refs.sliderW = sW
    refs.sliderH = sH
    sW:SetValue(data.barWidth)
    sH:SetValue(data.barHeight)
    sW.updateFunc = function(v)
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then d.barWidth = v; DoiteBars.CreateOrUpdateBar(_beKey, d) end
    end
    sH.updateFunc = function(v)
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then d.barHeight = v; DoiteBars.CreateOrUpdateBar(_beKey, d) end
    end
    y = y - 55

    BE_MakeHeader(content, y, "COLOR")
    y = y - 28

    refs.barUseDefault = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    refs.barUseDefault:SetWidth(20); refs.barUseDefault:SetHeight(20)
    refs.barUseDefault:SetPoint("TOPLEFT", content, "TOPLEFT", baseX, y + 4)
    refs.barUseDefault:SetChecked((data.barR or -1) < 0 and 1 or 0)
    refs.barUseDefault.text = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.barUseDefault.text:SetPoint("LEFT", refs.barUseDefault, "RIGHT", 2, 0)
    refs.barUseDefault.text:SetText("Use default bar color")
    refs.barUseDefault:SetScript("OnClick", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if not d then return end
        if this:GetChecked() == 1 then
            d.barR, d.barG, d.barB = -1, -1, -1
        else
            if (d.barR or -1) < 0 then
                d.barR, d.barG, d.barB = 0, 0.44, 0.87
            end
        end
        BE_RefreshEditedBar()
    end)

    refs.barColorSwatch = BE_MakeColorSwatch(content, baseX + 160, y, "Bar:", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if not d then return end
        local sr, sg, sb = d.barR, d.barG, d.barB
        if not sr or sr < 0 then sr, sg, sb = 0, 0.44, 0.87 end
        local sa = d.barAlpha or 1
        BE_ShowColorPicker(sr, sg, sb, sa, function(restore)
            local nr, ng, nb, na
            if restore then
                nr, ng, nb, na = unpack(restore)
            else
                na = OpacitySliderFrame and OpacitySliderFrame:GetValue() or sa
                nr, ng, nb = ColorPickerFrame:GetColorRGB()
            end
            d.barR, d.barG, d.barB = nr, ng, nb
            d.barAlpha = na or 1
            if refs.barUseDefault then refs.barUseDefault:SetChecked(0) end
            BE_SetSwatchColor(refs.barColorSwatch, nr, ng, nb, na)
            BE_RefreshEditedBar()
        end)
    end)
    y = y - 40

    refs.bgUseDefault = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    refs.bgUseDefault:SetWidth(20); refs.bgUseDefault:SetHeight(20)
    refs.bgUseDefault:SetPoint("TOPLEFT", content, "TOPLEFT", baseX, y + 4)
    refs.bgUseDefault:SetChecked(data.bgUseDefault and 1 or 0)
    refs.bgUseDefault.text = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    refs.bgUseDefault.text:SetPoint("LEFT", refs.bgUseDefault, "RIGHT", 2, 0)
    refs.bgUseDefault.text:SetText("Use default background")
    refs.bgUseDefault:SetScript("OnClick", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if not d then return end
        local checked = (this:GetChecked() == 1)
        d.bgUseDefault = checked and true or false
        if checked then
            d.bgR, d.bgG, d.bgB, d.bgAlpha = 0, 0, 0, 0.7
        end
        BE_RefreshEditedBar()
    end)

    refs.bgColorSwatch = BE_MakeColorSwatch(content, baseX + 160, y, "Background:", function()
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if not d then return end
        local sr, sg, sb, sa = d.bgR or 0, d.bgG or 0, d.bgB or 0, d.bgAlpha or 0.7
        BE_ShowColorPicker(sr, sg, sb, sa, function(restore)
            local nr, ng, nb, na
            if restore then
                nr, ng, nb, na = unpack(restore)
            else
                na = OpacitySliderFrame and OpacitySliderFrame:GetValue() or sa
                nr, ng, nb = ColorPickerFrame:GetColorRGB()
            end
            d.bgR, d.bgG, d.bgB = nr, ng, nb
            d.bgAlpha = na or 0.7
            d.bgUseDefault = false
            if refs.bgUseDefault then refs.bgUseDefault:SetChecked(0) end
            BE_SetSwatchColor(refs.bgColorSwatch, nr, ng, nb, na)
            BE_RefreshEditedBar()
        end)
    end)
    y = y - 35

    BE_MakeHeader(content, y, "TEXT")
    y = y - 28

    local sFontSize, _ = BE_MakeSlider(content, "DoiteBarsEdit_FontSize", "Font Size", baseX, y, sliderW, 6, 32, 1)
    refs.sFontSize = sFontSize
    sFontSize:SetValue(data.fontSize)
    sFontSize.updateFunc = function(v)
        if not _beKey then return end
        local d = DoiteAurasDB.spells[_beKey]
        if d then
            d.fontSize = v
            DoiteBars.CreateOrUpdateBar(_beKey, d)
        end
    end
    y = y - 55

    -- Format dropdown
    local fmtLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fmtLabel:SetPoint("TOPLEFT", content, "TOPLEFT", baseX, y)
    fmtLabel:SetText("Format:")
    refs.fmtDD = BE_MakeDropdown(
        content,
        "DoiteBarsEdit_FormatDD",
        baseX + 90,
        y + 6,
        110,
        { "Actual", "Short", "Percent" },
        data.textFormat or "Actual",
        function(picked)
            if not _beKey then return end
            local d = DoiteAurasDB.spells[_beKey]
            if d then
                d.textFormat = picked
                BE_RefreshEditedBar()
            end
        end
    )
    y = y - 30

    -- Text position dropdown
    local posLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    posLabel:SetPoint("TOPLEFT", content, "TOPLEFT", baseX, y)
    posLabel:SetText("Text position:")
    refs.posDD = BE_MakeDropdown(
        content,
        "DoiteBarsEdit_TextPosDD",
        baseX + 90,
        y + 6,
        110,
        {
            "Center", "Left", "Right",
            "TopLeft", "TopRight", "BottomLeft", "BottomRight",
            "OutsideTop", "OutsideBottom",
            "OutsideLeft", "OutsideRight",
            "OutsideTopLeft", "OutsideTopRight",
            "OutsideBottomLeft", "OutsideBottom Right"
        },
        data.textPosition or "Center",
        function(picked)
            if not _beKey then return end
            local d = DoiteAurasDB.spells[_beKey]
            if not d then return end
            d.textPosition = picked
            BE_RefreshEditedBar()
        end
    )
    y = y - 30

    local wantedH = math.abs(y) + 10
    if wantedH < 420 then wantedH = 420 end
    content:SetHeight(wantedH)

    return refs
end

---------------------------------------------------------------
-- UpdateSliderValues : Syncs slider values to current pos
---------------------------------------------------------------
local function BE_UpdateSliderValues(refs, data)
    if refs.cbInCombat then refs.cbInCombat:SetChecked(data.inCombat and 1 or 0) end
    if refs.cbOutCombat then refs.cbOutCombat:SetChecked(data.outCombat and 1 or 0) end
    if refs.cbPowerOnly then refs.cbPowerOnly:SetChecked(data.powerOnly and 1 or 0) end
    if refs.powerCompDD then
        refs.powerCompDD._selectedValue = data.powerComp or ">="
        UIDropDownMenu_SetSelectedValue(refs.powerCompDD, refs.powerCompDD._selectedValue)
        UIDropDownMenu_SetText(refs.powerCompDD._selectedValue, refs.powerCompDD)
        if _GoldifyDD then _GoldifyDD(refs.powerCompDD) end
        if data.powerOnly then refs.powerCompDD:Show() else refs.powerCompDD:Hide() end
    end
    if refs.powerValBox then
        refs.powerValBox:SetText(tostring(tonumber(data.powerValue) or 0))
        if data.powerOnly then refs.powerValBox:Show() else refs.powerValBox:Hide() end
    end
    if refs.powerPctLabel then
        if data.powerOnly then refs.powerPctLabel:Show() else refs.powerPctLabel:Hide() end
    end
    if refs.cbMyHP then refs.cbMyHP:SetChecked(data.hpMode == "my" and 1 or 0) end
    if refs.cbTargetHP then refs.cbTargetHP:SetChecked(data.hpMode == "target" and 1 or 0) end
    if refs.hpCompDD then
        refs.hpCompDD._selectedValue = data.hpComp or ">="
        UIDropDownMenu_SetSelectedValue(refs.hpCompDD, refs.hpCompDD._selectedValue)
        UIDropDownMenu_SetText(refs.hpCompDD._selectedValue, refs.hpCompDD)
        if _GoldifyDD then _GoldifyDD(refs.hpCompDD) end
        if data.hpMode == "my" or data.hpMode == "target" then refs.hpCompDD:Show() else refs.hpCompDD:Hide() end
    end
    if refs.hpValBox then
        refs.hpValBox:SetText(tostring(tonumber(data.hpValue) or 0))
        if data.hpMode == "my" or data.hpMode == "target" then refs.hpValBox:Show() else refs.hpValBox:Hide() end
    end
    if refs.hpPctLabel then
        if data.hpMode == "my" or data.hpMode == "target" then refs.hpPctLabel:Show() else refs.hpPctLabel:Hide() end
    end
    if refs.sliderX then refs.sliderX:SetValue(data.offsetX or 0) end
    if refs.sliderY then refs.sliderY:SetValue(data.offsetY or 0) end
    if refs.sliderW then refs.sliderW:SetValue(data.barWidth or 200) end
    if refs.sliderH then refs.sliderH:SetValue(data.barHeight or 24) end
    BE_UpdateSizeSliderLabels(data)
    if refs.barUseDefault then refs.barUseDefault:SetChecked((data.barR or -1) < 0 and 1 or 0) end
    if refs.bgUseDefault then refs.bgUseDefault:SetChecked(data.bgUseDefault and 1 or 0) end
    if refs.barColorSwatch then
        local sr, sg, sb = data.barR, data.barG, data.barB
        if not sr or sr < 0 then sr, sg, sb = 0, 0.44, 0.87 end
        BE_SetSwatchColor(refs.barColorSwatch, sr, sg, sb, data.barAlpha or 1)
    end
    if refs.bgColorSwatch then
        BE_SetSwatchColor(refs.bgColorSwatch, data.bgR or 0, data.bgG or 0, data.bgB or 0, data.bgAlpha or 0.7)
    end
    -- text
    if refs.sFontSize then refs.sFontSize:SetValue(data.fontSize or 10) end
    if refs.fmtDD and UIDropDownMenu_SetSelectedValue then
        refs.fmtDD._selectedValue = data.textFormat or "Actual"
        UIDropDownMenu_SetSelectedValue(refs.fmtDD, data.textFormat or "Actual")
        UIDropDownMenu_SetText(data.textFormat or "Actual", refs.fmtDD)
        if _GoldifyDD then _GoldifyDD(refs.fmtDD) end
    end
    if refs.posDD and UIDropDownMenu_SetSelectedValue then
        refs.posDD._selectedValue = data.textPosition or "Center"
        UIDropDownMenu_SetSelectedValue(refs.posDD, data.textPosition or "Center")
        UIDropDownMenu_SetText(data.textPosition or "Center", refs.posDD)
        if _GoldifyDD then _GoldifyDD(refs.posDD) end
    end
end

---------------------------------------------------------------
-- DoiteBars.InjectEditControls(cf, key)
-- Public. Called from UpdateCondFrameForKey in DoiteEdit.lua.
---------------------------------------------------------------
function DoiteBars.InjectEditControls(cf, key)
    if not cf or not key then return end

    if cf.HookScript and not cf._daBarsHideHooked then
        cf:HookScript("OnHide", function() BE_HideColorPicker(true) end)
        cf._daBarsHideHooked = true
    end
    if DoiteAurasFrame and DoiteAurasFrame.HookScript and not DoiteAurasFrame._daBarsHideHooked then
        DoiteAurasFrame:HookScript("OnHide", function() BE_HideColorPicker(true) end)
        DoiteAurasFrame._daBarsHideHooked = true
    end

    _beKey = key
    local data = DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key]
    if not data then return end

    if cf.header then
        cf.header:SetText("Edit: " .. (data.displayName or key) .. " |cffd27dff(Bar)|r")
        cf.header:Show()
    end
    if cf.groupTitle then
        cf.groupTitle:SetText("|cff6FA8DCLAYOUT SETTINGS|r")
    end

    if cf.condListContainer then cf.condListContainer:Hide() end
    BE_EnsureTopDropdowns(cf)

    if not cf.BarEditContainer then
        local container, content = BE_BuildContainer(cf)
        cf.BarEditContainer = container
        cf.BarEditContent = content
        cf.beRefs = BE_PopulateContent(content, key)
    end

    BE_UpdateSliderValues(cf.beRefs, data)
    cf.BarEditContainer:Show()

    if cf.beOrientationLabel then cf.beOrientationLabel:Show() end
    if cf.beOrientationDD then
        local opts = { "Horizontal", "Vertical" }
        local cur = data.orientation or "Horizontal"
        UIDropDownMenu_Initialize(cf.beOrientationDD, function()
            local i
            for i = 1, table.getn(opts) do
                local opt = opts[i]
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt
                info.value = opt
                info.checked = (opt == cur)
                info.func = function(button)
                    local picked = (button and button.value) or opt
                    if not _beKey then return end
                    local d = DoiteAurasDB.spells[_beKey]
                    if not d then return end
                    d.orientation = picked
                    d.direction = DA_DefaultDirectionForOrientation(picked)
                    UIDropDownMenu_SetSelectedValue(cf.beOrientationDD, picked)
                    UIDropDownMenu_SetText(picked, cf.beOrientationDD)
                    BE_InitDirectionDropdown(cf.beDirectionDD, d)
                    BE_UpdateSizeSliderLabels(d)
                    BE_RefreshEditedBar()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetSelectedValue(cf.beOrientationDD, cur)
        UIDropDownMenu_SetText(cur, cf.beOrientationDD)
        BE_SetDropdownTextColor(cf.beOrientationDD, 1, 1, 1)
        cf.beOrientationDD:Show()
    end
    if cf.beDirectionLabel then cf.beDirectionLabel:Show() end
    if cf.beDirectionDD then
        BE_InitDirectionDropdown(cf.beDirectionDD, data)
        cf.beDirectionDD:Show()
    end
    if cf.beTextureLabel then cf.beTextureLabel:Show() end
    if cf.beTextureDD then
        BE_InitTextureDropdown(cf.beTextureDD, data)
        cf.beTextureDD:Show()
    end

    if cf.groupTitle3 then cf.groupTitle3:Hide() end
    if cf.sep3 then cf.sep3:Hide() end
    if cf.sliderX then cf.sliderX:Hide() end
    if cf.sliderY then cf.sliderY:Hide() end
    if cf.sliderSize then cf.sliderSize:Hide() end
    if cf.sliderXBox then cf.sliderXBox:Hide() end
    if cf.sliderYBox then cf.sliderYBox:Hide() end
    if cf.sliderSizeBox then cf.sliderSizeBox:Hide() end

    if cf.DoiteGroupUIRefresh then cf:DoiteGroupUIRefresh(key) end
    if cf.dgLine then cf.dgLine:Hide() end
    
    local bf = DoiteBars.GetBarFrame(key)
    if bf then bf:EnableMouse(true) end
end

---------------------------------------------------------------
-- DoiteBars.CleanupCondFrame(cf)
---------------------------------------------------------------
function DoiteBars.CleanupCondFrame(cf)
    if not cf then return end
    BE_HideColorPicker(true)
    
    if cf.BarEditContainer then
        cf.BarEditContainer:Hide()
    end
    if cf.groupTitle then
        cf.groupTitle:SetText("|cff6FA8DCGROUP & LEADER|r")
    end
    if cf.beOrientationLabel then cf.beOrientationLabel:Hide() end
    if cf.beOrientationDD then cf.beOrientationDD:Hide() end
    if cf.beDirectionLabel then cf.beDirectionLabel:Hide() end
    if cf.beDirectionDD then cf.beDirectionDD:Hide() end
    if cf.beTextureLabel then cf.beTextureLabel:Hide() end
    if cf.beTextureDD then cf.beTextureDD:Hide() end
    if cf.beNameLbl then cf.beNameLbl:Hide() end
    if cf.beKindLbl then cf.beKindLbl:Hide() end

    if cf.condListContainer then
        cf.condListContainer:Show()
    end
    if cf.dgLine then
        cf.dgLine:Show()
    end

    if _beKey then
        local bf = DoiteBars.GetBarFrame(_beKey)
        if bf then bf:EnableMouse(false) end
    end
    _beKey = nil
end
