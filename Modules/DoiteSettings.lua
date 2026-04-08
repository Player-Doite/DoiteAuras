---------------------------------------------------------------
-- DoiteSettings.lua
-- Settings UI for DoiteAuras
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

DoiteSettings = DoiteSettings or {}

local settingsFrame
----------------------------------------
-- Local helpers
----------------------------------------
-- Match "top-most" behavior
local function DS_MakeTopMost(frame)
    if not frame then return end
    frame:SetFrameStrata("TOOLTIP")
end

local function DS_CloseOtherWindows()
    local f

    f = _G["DoiteAurasImportFrame"]
    if f and f.IsShown and f:IsShown() then
        f:Hide()
    end

    f = _G["DoiteAurasExportFrame"]
    if f and f.IsShown and f:IsShown() then
        f:Hide()
    end
end

----------------------------------------
-- Frame
----------------------------------------
local function DS_CreateSettingsFrame()
    if settingsFrame then
        return
    end

    local f = CreateFrame("Frame", "DoiteAurasSettingsFrame", UIParent)
    settingsFrame = f

    -- Size similar to Import frame, same style
    f:SetWidth(310)
    f:SetHeight(350)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        this:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
    end)

    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetBackdropColor(0, 0, 0, 1)
    f:SetBackdropBorderColor(1, 1, 1, 1)
    f:SetFrameStrata("TOOLTIP")
    f:Hide()

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -15)
    title:SetText("|cff6FA8DCDoiteSettings|r")

    -- Separator line (same idea as export/import)
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -35)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -35)
    sep:SetTexture(1, 1, 1)
    if sep.SetVertexColor then
        sep:SetVertexColor(1, 1, 1, 0.25)
    end

    -- Close X
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function()
        f:Hide()
    end)
	
	-- Coming soon text (center body)
    local coming = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coming:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -100)
    coming:SetWidth(210)
    coming:SetJustifyH("LEFT")
    coming:SetJustifyV("TOP")
    coming:SetText("Settings coming:\n\n* Soon of CD (Range for sliders & Time)\n* Refresh rate for certain rebuilds (like group)")

    ---------------------------------------------------------------
    -- pfUI border toggle
    ---------------------------------------------------------------
    local pfuiBorderBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    pfuiBorderBtn:SetWidth(135)
    pfuiBorderBtn:SetHeight(20)
    pfuiBorderBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -50)

    local function DS_HasPfUI()
        if type(DoiteAuras_HasPfUI) == "function" then
            return DoiteAuras_HasPfUI() == true
        end
        return false
    end

    local function DS_UpdatePfUIButton()
        local hasPfUI = DS_HasPfUI()

		-- If pfUI exists and the user has no saved choice yet, default ON
		if hasPfUI and DoiteAurasDB and DoiteAurasDB.pfuiBorder == nil then
			DoiteAurasDB.pfuiBorder = true
		end

        -- If pfUI is missing: force OFF first
        if not hasPfUI then
            if DoiteAurasDB then
                DoiteAurasDB.pfuiBorder = false
            end
        end

        -- set label from the final state
        if DoiteAurasDB and DoiteAurasDB.pfuiBorder == true then
            pfuiBorderBtn:SetText("pfUI icons: ON")
        else
            pfuiBorderBtn:SetText("pfUI icons: OFF")
        end

        -- Disable + grey when pfUI missing
        if not hasPfUI then
            if pfuiBorderBtn.Disable then pfuiBorderBtn:Disable() end

            local fs = pfuiBorderBtn.GetFontString and pfuiBorderBtn:GetFontString()
            if fs and fs.SetTextColor then
                fs:SetTextColor(0.6, 0.6, 0.6)
            end
        else
            if pfuiBorderBtn.Enable then pfuiBorderBtn:Enable() end

            local fs = pfuiBorderBtn.GetFontString and pfuiBorderBtn:GetFontString()
            if fs and fs.SetTextColor then
                fs:SetTextColor(1, 0.82, 0)
            end
        end
    end

    pfuiBorderBtn:SetScript("OnClick", function()
        if not DS_HasPfUI() then
            return
        end

        DoiteAurasDB.pfuiBorder = not (DoiteAurasDB.pfuiBorder == true)
        DS_UpdatePfUIButton()

        if type(DoiteAuras_ApplyBorderToAllIcons) == "function" then
            DoiteAuras_ApplyBorderToAllIcons()
        end
        if DoiteAuras_RefreshIcons then
            pcall(DoiteAuras_RefreshIcons)
        end
    end)

    DS_UpdatePfUIButton()

    ---------------------------------------------------------------
    -- Item tooltip toggle
    ---------------------------------------------------------------
    local itemTooltipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    itemTooltipBtn:SetWidth(135)
    itemTooltipBtn:SetHeight(20)
    itemTooltipBtn:SetPoint("TOPLEFT", pfuiBorderBtn, "BOTTOMLEFT", 0, -5)

    local function DS_UpdateItemTooltipButton()
        if not DoiteAurasDB then DoiteAurasDB = {} end

        -- Default ON if unset
        if DoiteAurasDB.showtooltip == nil then
            DoiteAurasDB.showtooltip = true
        end

        if DoiteAurasDB.showtooltip == true then
            itemTooltipBtn:SetText("Item tooltip: ON")
        else
            itemTooltipBtn:SetText("Item tooltip: OFF")
        end

        -- Always enabled, match pfUI button "enabled" color
        if itemTooltipBtn.Enable then itemTooltipBtn:Enable() end
        local fs = itemTooltipBtn.GetFontString and itemTooltipBtn:GetFontString()
        if fs and fs.SetTextColor then
            fs:SetTextColor(1, 0.82, 0)
        end
    end

    itemTooltipBtn:SetScript("OnClick", function()
        if not DoiteAurasDB then DoiteAurasDB = {} end
        DoiteAurasDB.showtooltip = not (DoiteAurasDB.showtooltip == true)
        DS_UpdateItemTooltipButton()

        -- Refresh so mouse handlers/tooltip scripts are updated immediately
        if DoiteAuras_RefreshIcons then
            pcall(DoiteAuras_RefreshIcons)
        end
    end)

    DS_UpdateItemTooltipButton()

    ---------------------------------------------------------------
    -- DEBUG section (bottom-anchored)
    ---------------------------------------------------------------
    local debugHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    debugHeader:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 78)
    debugHeader:SetText("DEBUG")
    if debugHeader.SetTextColor then
        debugHeader:SetTextColor(1, 1, 1)
    end

    local debugSep = f:CreateTexture(nil, "ARTWORK")
    debugSep:SetHeight(1)
    debugSep:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 70)
    debugSep:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 70)
    debugSep:SetTexture(1, 1, 1)
    if debugSep.SetVertexColor then
        debugSep:SetVertexColor(1, 1, 1, 0.25)
    end

    -- Bottom button: Overcap simulation
    local overcapBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    overcapBtn:SetWidth(135)
    overcapBtn:SetHeight(20)
    overcapBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)

    -- Top button: Spell cast debug
    local spellCastDebugBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    spellCastDebugBtn:SetWidth(135)
    spellCastDebugBtn:SetHeight(20)
    spellCastDebugBtn:SetPoint("BOTTOMLEFT", overcapBtn, "TOPLEFT", 0, 5)

    ---------------------------------------------------------------
    -- Live aura count debug (screen overlay + toggles)
    ---------------------------------------------------------------
    local DS_PlayerAuraCountEnabled = false
    local DS_TargetAuraCountEnabled = false

    -- Screen overlay frame (exists even if settings frame is hidden)
    local auraCountOverlay = CreateFrame("Frame", "DoiteSettings_AuraCountOverlay", UIParent)
    auraCountOverlay:Hide()

    -- Two lines, each split into bold blue prefix + normal suffix
    local playerPrefix = auraCountOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    playerPrefix:SetPoint("TOP", UIParent, "TOP", 0, -20)
    playerPrefix:SetText("|cff6FA8DCPLAYER AURAS|r")

    local playerSuffix = auraCountOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    playerSuffix:SetPoint("LEFT", playerPrefix, "RIGHT", 4, -2)
    playerSuffix:SetText("")

    local targetPrefix = auraCountOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    targetPrefix:SetPoint("TOP", playerPrefix, "BOTTOM", 0, -6)
    targetPrefix:SetText("|cff6FA8DCTARGET AURAS|r")

    local targetSuffix = auraCountOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    targetSuffix:SetPoint("LEFT", targetPrefix, "RIGHT", 4, -2)
    targetSuffix:SetText("")

    local function DS_CanReadPlayerAuraCounts()
        return DoitePlayerAuras and type(DoitePlayerAuras.GetAuraCountSummary) == "function"
    end

    local function DS_CanReadTargetAuraCounts()
        return DoiteTargetAuras and type(DoiteTargetAuras.GetAuraCountSummary) == "function"
    end

    local function DS_FormatAuraCountLine(total, visible, hidden)
        return string.format(
            "|cffffffff: |r|cffffff00%d|r|cffffffff (Visible: |r|cffffff00%d|r|cffffffff / Hidden: |r|cffffff00%d|r|cffffffff)|r",
            total or 0, visible or 0, hidden or 0
        )
    end

    local function DS_UpdateAuraCountOverlayOnce()
        local pb, pd, ph, pt
        local tb, td, th, tt

        if DS_PlayerAuraCountEnabled and DS_CanReadPlayerAuraCounts() then
            pb, pd, ph, pt = DoitePlayerAuras.GetAuraCountSummary()
            playerPrefix:Show()
            playerSuffix:Show()
            playerSuffix:SetText(DS_FormatAuraCountLine(pt, (pb + pd), ph))
        else
            playerPrefix:Hide()
            playerSuffix:Hide()
        end

        if DS_TargetAuraCountEnabled and DS_CanReadTargetAuraCounts() then
            tb, td, th, tt = DoiteTargetAuras.GetAuraCountSummary()
            targetPrefix:Show()
            targetSuffix:Show()
            targetSuffix:SetText(DS_FormatAuraCountLine(tt, (tb + td), th))
        else
            targetPrefix:Hide()
            targetSuffix:Hide()
        end

        if DS_PlayerAuraCountEnabled or DS_TargetAuraCountEnabled then
            auraCountOverlay:Show()
        else
            auraCountOverlay:Hide()
        end
    end

    local auraCountElapsed = 0
    local function DS_SetAuraCountOverlayRunning(enable)
        if enable then
            auraCountElapsed = 0
            auraCountOverlay:SetScript("OnUpdate", function()
                auraCountElapsed = auraCountElapsed + arg1
                if auraCountElapsed >= 0.5 then
                    auraCountElapsed = 0
                    DS_UpdateAuraCountOverlayOnce()
                end
            end)
            DS_UpdateAuraCountOverlayOnce()
        else
            auraCountOverlay:SetScript("OnUpdate", nil)
            auraCountOverlay:Hide()
        end
    end

    local playerAuraCountBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    playerAuraCountBtn:SetWidth(135)
    playerAuraCountBtn:SetHeight(20)
    playerAuraCountBtn:SetPoint("LEFT", spellCastDebugBtn, "RIGHT", 5, 0)

    local targetAuraCountBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    targetAuraCountBtn:SetWidth(135)
    targetAuraCountBtn:SetHeight(20)
    targetAuraCountBtn:SetPoint("LEFT", overcapBtn, "RIGHT", 5, 0)

    local function DS_UpdatePlayerAuraCountButton()
        if DS_PlayerAuraCountEnabled then
            playerAuraCountBtn:SetText("# of PlayerAuras: ON")
        else
            playerAuraCountBtn:SetText("# of PlayerAuras: OFF")
        end

        if not DS_CanReadPlayerAuraCounts() then
            if playerAuraCountBtn.Disable then playerAuraCountBtn:Disable() end
            local fs = playerAuraCountBtn.GetFontString and playerAuraCountBtn:GetFontString()
            if fs and fs.SetTextColor then fs:SetTextColor(0.6, 0.6, 0.6) end
        else
            if playerAuraCountBtn.Enable then playerAuraCountBtn:Enable() end
            local fs = playerAuraCountBtn.GetFontString and playerAuraCountBtn:GetFontString()
            if fs and fs.SetTextColor then fs:SetTextColor(1, 0.82, 0) end
        end
    end

    local function DS_UpdateTargetAuraCountButton()
        if DS_TargetAuraCountEnabled then
            targetAuraCountBtn:SetText("# of TargetAuras: ON")
        else
            targetAuraCountBtn:SetText("# of TargetAuras: OFF")
        end

        if not DS_CanReadTargetAuraCounts() then
            if targetAuraCountBtn.Disable then targetAuraCountBtn:Disable() end
            local fs = targetAuraCountBtn.GetFontString and targetAuraCountBtn:GetFontString()
            if fs and fs.SetTextColor then fs:SetTextColor(0.6, 0.6, 0.6) end
        else
            if targetAuraCountBtn.Enable then targetAuraCountBtn:Enable() end
            local fs = targetAuraCountBtn.GetFontString and targetAuraCountBtn:GetFontString()
            if fs and fs.SetTextColor then fs:SetTextColor(1, 0.82, 0) end
        end
    end

    playerAuraCountBtn:SetScript("OnClick", function()
        if not DS_CanReadPlayerAuraCounts() then
            return
        end
        DS_PlayerAuraCountEnabled = not DS_PlayerAuraCountEnabled
        DS_UpdatePlayerAuraCountButton()
        DS_UpdateAuraCountOverlayOnce()
        DS_SetAuraCountOverlayRunning(DS_PlayerAuraCountEnabled or DS_TargetAuraCountEnabled)
    end)

    targetAuraCountBtn:SetScript("OnClick", function()
        if not DS_CanReadTargetAuraCounts() then
            return
        end
        DS_TargetAuraCountEnabled = not DS_TargetAuraCountEnabled
        DS_UpdateTargetAuraCountButton()
        DS_UpdateAuraCountOverlayOnce()
        DS_SetAuraCountOverlayRunning(DS_PlayerAuraCountEnabled or DS_TargetAuraCountEnabled)
    end)

    local function DS_GetSpellCastDebugState()
        if _G["DoiteTrack_NPDebug"] then
            return true
        end
        return false
    end

    local function DS_SetSpellCastDebugState(wantOn)
        local fn = _G["DoiteTrack_SetNPDebug"]
        if type(fn) == "function" then
            fn(wantOn and true or false)
            return true
        end
        return false
    end

    local function DS_UpdateSpellCastDebugButton()
        local on = DS_GetSpellCastDebugState()

        if on then
            spellCastDebugBtn:SetText("Spell cast: ON")
        else
            spellCastDebugBtn:SetText("Spell cast: OFF")
        end

        if type(_G["DoiteTrack_SetNPDebug"]) ~= "function" then
            if spellCastDebugBtn.Disable then spellCastDebugBtn:Disable() end
            local fs = spellCastDebugBtn.GetFontString and spellCastDebugBtn:GetFontString()
            if fs and fs.SetTextColor then
                fs:SetTextColor(0.6, 0.6, 0.6)
            end
        else
            if spellCastDebugBtn.Enable then spellCastDebugBtn:Enable() end
            local fs = spellCastDebugBtn.GetFontString and spellCastDebugBtn:GetFontString()
            if fs and fs.SetTextColor then
                fs:SetTextColor(1, 0.82, 0)
            end
        end
    end

    spellCastDebugBtn:SetScript("OnClick", function()
        local cur = DS_GetSpellCastDebugState()
        local ok = DS_SetSpellCastDebugState(not cur)
        if not ok then
            local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
            if cf then
                cf:AddMessage("|cff6FA8DCDoiteSettings:|r debug toggle not available (DoiteTrack not loaded?).")
            end
            return
        end
        DS_UpdateSpellCastDebugButton()
    end)

    local function DS_GetOvercapSimState()
        local on = false
        if DoitePlayerAuras and DoitePlayerAuras.debugBuffCap then
            on = true
        end
        if DoiteTargetAuras and DoiteTargetAuras.debugBuffCap then
            on = true
        end
        return on
    end

    local function DS_CanToggleOvercapSim()
        if DoitePlayerAuras and type(DoitePlayerAuras.ToggleDebugBuffCap) == "function" then
            return true
        end
        if DoiteTargetAuras and type(DoiteTargetAuras.ToggleDebugBuffCap) == "function" then
            return true
        end
        return false
    end

    local function DS_UpdateOvercapButton()
        local on = DS_GetOvercapSimState()

        if on then
            overcapBtn:SetText("Aura cap. sim.: ON")
        else
            overcapBtn:SetText("Aura cap. sim.: OFF")
        end

        if not DS_CanToggleOvercapSim() then
            if overcapBtn.Disable then overcapBtn:Disable() end
            local fs = overcapBtn.GetFontString and overcapBtn:GetFontString()
            if fs and fs.SetTextColor then
                fs:SetTextColor(0.6, 0.6, 0.6)
            end
        else
            if overcapBtn.Enable then overcapBtn:Enable() end
            local fs = overcapBtn.GetFontString and overcapBtn:GetFontString()
            if fs and fs.SetTextColor then
                fs:SetTextColor(1, 0.82, 0)
            end
        end
    end

    overcapBtn:SetScript("OnClick", function()
        local okAny = false

        if DoitePlayerAuras and type(DoitePlayerAuras.ToggleDebugBuffCap) == "function" then
            DoitePlayerAuras.ToggleDebugBuffCap()
            okAny = true
        end
        if DoiteTargetAuras and type(DoiteTargetAuras.ToggleDebugBuffCap) == "function" then
            DoiteTargetAuras.ToggleDebugBuffCap()
            okAny = true
        end

        if not okAny then
            local cf = (DEFAULT_CHAT_FRAME or ChatFrame1)
            if cf then
                cf:AddMessage("|cff6FA8DCDoiteSettings:|r overcap simulation toggle not available.")
            end
            return
        end

        DS_UpdateOvercapButton()
    end)

    DS_UpdateSpellCastDebugButton()
    DS_UpdateOvercapButton()
    DS_UpdatePlayerAuraCountButton()
    DS_UpdateTargetAuraCountButton()
    DS_SetAuraCountOverlayRunning(false)

    -- OnShow: enforce exclusivity + top-most
    f:SetScript("OnShow", function()
        DS_CloseOtherWindows()
        DS_MakeTopMost(f)
        DS_UpdatePfUIButton()
        DS_UpdateItemTooltipButton()
        DS_UpdateSpellCastDebugButton()
        DS_UpdateOvercapButton()
        DS_UpdatePlayerAuraCountButton()
        DS_UpdateTargetAuraCountButton()
        DS_UpdateAuraCountOverlayOnce()
    end)

    DS_MakeTopMost(f)
end

-- Public entrypoint called by the Settings button in DoiteAuras.lua
function DoiteAuras_ShowSettings()
    if not settingsFrame then
        DS_CreateSettingsFrame()
    end

    -- If Import/Export are open, close them so only one window is visible
    DS_CloseOtherWindows()

    settingsFrame:Show()
end
----------------------------------------
-- End of frame
----------------------------------------
