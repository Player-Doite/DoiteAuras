---------------------------------------------------------------
-- DoiteConditions.lua
-- Evaluates ability and aura conditions to show/hide/update icons
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

local DoiteConditions = {}
_G["DoiteConditions"] = DoiteConditions

if not _G["DoiteAurasDB"] then
    _G["DoiteAurasDB"] = {}
end

DoiteAurasDB = _G["DoiteAurasDB"]
DoiteAurasDB.cache = DoiteAurasDB.cache or {}
DoiteAurasCacheDB = DoiteAurasDB.cache
local IconCache = DoiteAurasDB.cache

local GetTime       = GetTime
local UnitBuff      = UnitBuff
local UnitDebuff    = UnitDebuff
local UnitExists    = UnitExists
local UnitIsFriend  = UnitIsFriend
local UnitCanAttack = UnitCanAttack
local UnitIsUnit    = UnitIsUnit
local UnitClass     = UnitClass
local UnitName      = UnitName
local UnitHealth    = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitMana      = UnitMana
local UnitManaMax   = UnitManaMax
local GetComboPoints = GetComboPoints
local GetNumTalentTabs = GetNumTalentTabs
local GetNumTalents    = GetNumTalents
local GetTalentInfo    = GetTalentInfo
local _GetTime = GetTime
local str_find  = string.find
local str_gsub  = string.gsub
local SpellUsableArgCache = {}

-- Fast frame getter for hot paths (ApplyVisuals / aura scans / time text)
local function _GetIconFrame(k)
    if not k then return nil end

    -- If an external getter exists, prefer it
    if DoiteAuras_GetIconFrame then
        local f = DoiteAuras_GetIconFrame(k)
        if f then return f end
    end

    -- Cache tables live
    local byKey = DoiteConditions._iconFrameByKey
    if not byKey then
        byKey = {}
        DoiteConditions._iconFrameByKey = byKey
        DoiteConditions._iconFrameNameByKey = {}
    end

    local f = byKey[k]
    if f then return f end

    local nameByKey = DoiteConditions._iconFrameNameByKey
    local nm = nameByKey[k]
    if not nm then
        nm = "DoiteIcon_" .. k
        nameByKey[k] = nm
    end

    f = _G[nm]
    if f then
        byKey[k] = f
    end
    return f
end

local function _Now()

  return (_GetTime and _GetTime()) or 0
end

-- Spell index cache (must be defined before any usage)
local SpellIndexCache = {}
_G.DoiteConditions_SpellIndexCache = SpellIndexCache

local _isWarrior = false

local function _GetSpellIndexByName(spellName)
    if not spellName then return nil end

    local cached = SpellIndexCache[spellName]
    if cached ~= nil then
        return (cached ~= false) and cached or nil
    end

    -- Nampower fast path - GetSpellSlotTypeIdForName(spellName)
    if GetSpellSlotTypeIdForName then
        local slot, bookType = GetSpellSlotTypeIdForName(spellName)
        if slot and slot > 0 and bookType == "spell" then
            SpellIndexCache[spellName] = slot
            return slot
        end
    end

    -- Scan fallback
    local i = 1
    while i <= 200 do
        local s = GetSpellName(i, BOOKTYPE_SPELL)
        if not s then break end
        if s == spellName then
            SpellIndexCache[spellName] = i
            return i
        end
        i = i + 1
    end

    SpellIndexCache[spellName] = false
    return nil
end


-- Dirty flags used by the central update loop
local dirty_ability      = false
local dirty_aura         = false
local dirty_target       = false
local dirty_power        = false
local dirty_ability_time = false

-- Coalesced aura scans (set in events; consumed in OnUpdate)
DoiteConditions._pendingAuraScanPlayer      = false
DoiteConditions._pendingAuraScanTarget      = false
DoiteConditions._pendingRebuildPlayerTimers = false

----------------------------------------------------------------
-- One-shot repaint next frame (avoids re-entrancy inside events)
----------------------------------------------------------------

-- Forward declare so functions defined above can capture it as an upvalue
local _RequestImmediateEval

local _DoiteImmediateEval = CreateFrame("Frame", "DoiteImmediateEval")
_DoiteImmediateEval:Hide()
_DoiteImmediateEval._pending = false
_DoiteImmediateEval:SetScript("OnUpdate", function()
    this:Hide()
    this._pending = false

    dirty_ability      = true
    dirty_aura         = true
    dirty_target       = true
    dirty_power        = true
    dirty_ability_time = true

    if DoiteConditions and DoiteConditions.EvaluateAll then
        DoiteConditions:EvaluateAll()
    end

    if DoiteGroup then
        _G["DoiteGroup_NeedReflow"] = true
    end
end)

_RequestImmediateEval = function()
    if _DoiteImmediateEval._pending then return end
    _DoiteImmediateEval._pending = true
    _DoiteImmediateEval:Show()
end

_G.DoiteConditions_RequestImmediateEval = _RequestImmediateEval

local DG = _G["DoiteGlow"]

local function _IsKeyUnderEdit(k)
    if not k then return false end
    local cur = _G["DoiteEdit_CurrentKey"]
    if not cur or cur ~= k then return false end
    local f = _G["DoiteEdit_Frame"] or _G["DoiteEditMain"] or _G["DoiteEdit"]
    if f and f.IsShown then
        return f:IsShown() == 1
    end
    return true
end

local function _IsAnyKeyUnderEdit()
    local cur = _G["DoiteEdit_CurrentKey"]
    if not cur then return false end
    local f = _G["DoiteEdit_Frame"] or _G["DoiteEditMain"] or _G["DoiteEdit"]
    if f and f.IsShown then
        return f:IsShown() == 1
    end
    return false
end

----------------------------------------------------------------
-- Edit-mode heartbeat: force frequent refresh while editor is open (prevents 0.5s delay / "needs a target" when idle)
----------------------------------------------------------------
local _editTick = CreateFrame("Frame", "DoiteEditTick")
local _editAccum = 0

-- Tuning: 0.10 feels instant but is still cheap.
local DOITE_EDIT_TICK = 0.10

_editTick:SetScript("OnUpdate", function()
    if not _IsAnyKeyUnderEdit() then
        _editAccum = 0
        return
    end

	_editAccum = _editAccum + (arg1 or 0)
	if _editAccum < DOITE_EDIT_TICK then return end
	_editAccum = 0

	-- skip if editor hidden or zero visible icons
	local f = _G["DoiteEdit_Frame"]
	if not (f and f:IsShown()) then return end
    _editAccum = 0

    -- Force the normal pipeline to run even when the player is idle.
    dirty_ability      = true
    dirty_aura         = true
    dirty_target       = true
    dirty_power        = true
    dirty_ability_time = true
end)

local function _MaybeResolveSpellIdForEntry(key, data)
    if not data or type(data) ~= "table" then return end

    -- Only touch entries that look like the temporary "Spell ID: ###" displayName
    local dn = data.displayName
    if not dn or dn == "" then return end
    if not str_find(dn, "^Spell ID") then
        return
    end

    local sidStr = data.spellid
    if not sidStr or sidStr == "" then return end
    local sid = tonumber(sidStr)
    if not sid or sid <= 0 then return end

    local name, tex

    -- SuperWoW: SpellInfo(spellId) -> name, rank, texture, ...
    if SpellInfo then
        local n, _, t = SpellInfo(sid)
        if type(n) == "string" and n ~= "" then
            name = n
        end
        if type(t) == "string" and t ~= "" then
            tex = t
        end
    end

    -- Nampower fallback: GetSpellNameAndRankForId(spellId)
    if (not name) and GetSpellNameAndRankForId then
        local n, rank = GetSpellNameAndRankForId(sid)
        if type(n) == "string" and n ~= "" then
            name = n
        end
    end

    -- If still don’t have a real name, bail out without changing anything
    if not name or name == "" then
        return
    end

    ------------------------------------------------------------
    -- Commit to DB: real name + optional texture
    ------------------------------------------------------------
    data.displayName = name
    if not data.name or data.name == "" then
        data.name = name
    end

    if tex and tex ~= "" then
        data.iconTexture = tex

        if IconCache then
            IconCache[name] = tex
        end
        if DoiteAurasDB and DoiteAurasDB.cache then
            DoiteAurasDB.cache[name] = tex
        end

        -- Update live icon frame if it exists
        if key then
            local f = _GetIconFrame(key)
            if f and f.icon and f.icon.SetTexture then
                local cur = f.icon:GetTexture()
                if cur ~= tex then
                    f.icon:SetTexture(tex)
                end
            end
        end
    end
end

local _trackedByName, _trackedBuiltAt = nil, 0

-- Pool list tables to avoid repeated allocations during frequent rebuilds (esp. in editor TTL=0.25)
local _trackedListPool = {}
local _trackedListPoolN = 0

local function _PoolPopList()
    if _trackedListPoolN > 0 then
        local lst = _trackedListPool[_trackedListPoolN]
        _trackedListPool[_trackedListPoolN] = nil
        _trackedListPoolN = _trackedListPoolN - 1
        return lst
    end
    return {}
end

local function _PoolPushList(lst)
    if not lst then return end
    local j
    for j in pairs(lst) do
        lst[j] = nil
    end
    _trackedListPoolN = _trackedListPoolN + 1
    _trackedListPool[_trackedListPoolN] = lst
end

local function _GetTrackedByName()
	local now = GetTime()

	-- While editing, rebuild more aggressively.
	local ttl = _IsAnyKeyUnderEdit() and 0.25 or 5.0

	local dbSize = 0
	if DoiteAurasDB and DoiteAurasDB.spells then
		for _ in pairs(DoiteAurasDB.spells) do
			dbSize = dbSize + 1
		end
	end

	local builtAt = _trackedBuiltAt or 0
	local cachedSize = _trackedByName and _trackedByName._dbSize or nil

	if _trackedByName and (now - builtAt) < ttl and cachedSize == dbSize then
		return _trackedByName
	end

    local t = _trackedByName
    if not t then
        t = {}
    else
        local k, lst
        for k, lst in pairs(t) do
            if type(lst) == "table" then
                _PoolPushList(lst)
            end
            t[k] = nil
        end
    end

    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if data and (data.type == "Buff" or data.type == "Debuff") then
                -- If this aura was added via spellid with a temporary "Spell ID: ###" name, resolve it once here using SuperWoW / Nampower.
                _MaybeResolveSpellIdForEntry(key, data)

                local nm = data.displayName or data.name
                if nm and nm ~= "" then
                    local lst = t[nm]
                    if not lst then
                        lst = _PoolPopList()
                        t[nm] = lst
                    end
                    table.insert(lst, key)
                end
            end
        end
    end

    _trackedByName, _trackedBuiltAt = t, now
	t._dbSize = dbSize
    return t
end

-- === Aura snapshot & single tooltip ===
local DoiteConditionsTooltip = _G["DoiteConditionsTooltip"]
if not DoiteConditionsTooltip then
    DoiteConditionsTooltip = CreateFrame("GameTooltip", "DoiteConditionsTooltip", nil, "GameTooltipTemplate")
    DoiteConditionsTooltip:SetOwner(UIParent, "ANCHOR_NONE")
end

-- Cache tooltip fontstrings once
local _CondTipLeft = {}
do
    local i = 1
    while i <= 15 do
        _CondTipLeft[i] = _G["DoiteConditionsTooltipTextLeft" .. i]
        i = i + 1
    end
end

-- Cache Left1 FS once for aura-name/time reads
local _DoiteCondTipLeft1FS = _G["DoiteConditionsTooltipTextLeft1"]

local auraSnapshot = {
    player = { buffs = {}, debuffs = {}, buffIds = {}, debuffIds = {} },
    target = { buffs = {}, debuffs = {}, buffIds = {}, debuffIds = {} },
}

_G.DoiteConditions_AuraSnapshot = auraSnapshot
-- Per-name remaining-time cache for player auras
local PlayerAuraTimers = { buffs = {}, debuffs = {} }
_G.DoiteConditions_PlayerAuraTimers = PlayerAuraTimers

-- Create hidden tooltip once; don't re-SetOwner every scan
local function _EnsureTooltip()
    if not DoiteConditionsTooltip then
        DoiteConditionsTooltip = CreateFrame("GameTooltip", "DoiteConditionsTooltip", UIParent, "GameTooltipTemplate")
        DoiteConditionsTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        DoiteConditionsTooltip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 0, 0) -- offscreen
        if DoiteConditionsTooltip.SetScript then
            DoiteConditionsTooltip:SetScript("OnTooltipCleared", nil)
            DoiteConditionsTooltip:SetScript("OnHide", nil)
        end
    end
end

-- SuperWoW: UnitBuff/UnitDebuff return auraId, SpellInfo(auraId) gives name/texture.
local _AuraNameTipLeft1FS = nil
local function _GetAuraName(unit, index, isDebuff)
    if not unit or not index or index < 1 then return nil end

    local tex, auraId
    if isDebuff then
        -- SuperWoW: texture, stacks, dtype, spellID
        tex, _, _, auraId = UnitDebuff(unit, index)
    else
        -- SuperWoW: texture, stacks, spellID
        tex, _, auraId = UnitBuff(unit, index)
    end
    if not tex then
        -- No aura at this index: real end-of-list marker
        return nil
    end

    local name

    -- SuperWoW path: auraId -> SpellInfo(id) -> name
    if auraId and SpellInfo then
        local n = SpellInfo(auraId)
        if type(n) == "string" and n ~= "" then
            name = n
        end
    end

    -- Fallback: tooltip name (vanilla / weird auras / bad IDs)
    if not name then
        _EnsureTooltip()
        DoiteConditionsTooltip:ClearLines()

        if isDebuff then
            if DoiteConditionsTooltip.SetUnitDebuff then
                DoiteConditionsTooltip:SetUnitDebuff(unit, index)
            elseif DoiteConditionsTooltip.SetUnitBuff then
                DoiteConditionsTooltip:SetUnitBuff(unit, index, "HARMFUL")
            end
        else
            if DoiteConditionsTooltip.SetUnitBuff then
                DoiteConditionsTooltip:SetUnitBuff(unit, index, "HELPFUL")
            end
        end

        if not _AuraNameTipLeft1FS then
            _AuraNameTipLeft1FS = _G["DoiteConditionsTooltipTextLeft1"]
        end
        local fs = _AuraNameTipLeft1FS
        if fs and fs.GetText then
            local t = fs:GetText()
            if t and t ~= "" then
                name = t
            end
        end
    end

    -- return a non-nil sentinel so callers don't think the list ended.
    if not name then
        return ""
    end

    return name
end

-- Tooltip-only fallback used by _ScanUnitAuras() - already have tex/auraId.
local _DoiteCondTipLeft1FS = nil
local function _GetAuraName_TooltipOnly(unit, index, isDebuff)
	if not unit or not index or index < 1 then return "" end

	_EnsureTooltip()
	DoiteConditionsTooltip:ClearLines()

	if isDebuff then
		if DoiteConditionsTooltip.SetUnitDebuff then
			DoiteConditionsTooltip:SetUnitDebuff(unit, index)
		elseif DoiteConditionsTooltip.SetUnitBuff then
			DoiteConditionsTooltip:SetUnitBuff(unit, index, "HARMFUL")
		end
	else
		if DoiteConditionsTooltip.SetUnitBuff then
			DoiteConditionsTooltip:SetUnitBuff(unit, index, "HELPFUL")
		end
	end

	if not _DoiteCondTipLeft1FS then
		_DoiteCondTipLeft1FS = _G["DoiteConditionsTooltipTextLeft1"]
	end

	local fs = _DoiteCondTipLeft1FS
	if fs and fs.GetText then
		local t = fs:GetText()
		if t and t ~= "" then
			return t
		end
	end

	-- Non-nil sentinel (matches _GetAuraName() behavior for “couldn’t resolve name”)
	return ""
end

local function _ScanUnitAuras(unit)
    -- Use cached lookup: auraName -> { list of keys that track this name }
    local trackedByName = _GetTrackedByName()

	local snap = auraSnapshot[unit]
	if not snap then return end

	local prevBuffs, prevDebuffs = snap.buffCount or 0, snap.debuffCount or 0

	-- UnitBuff/UnitDebuff: grabbing only first return (texture) is intentional here.
	local curBuffTex   = UnitBuff(unit, 1)
	local curDebuffTex = UnitDebuff(unit, 1)

	-- If previously there were no auras and there still are none, skip the scan.
	if (not curBuffTex and prevBuffs == 0) and (not curDebuffTex and prevDebuffs == 0) then
		return
	end

	local buffs,   debuffs   = snap.buffs,   snap.debuffs
	local buffIds, debuffIds = snap.buffIds, snap.debuffIds
	if not buffs or not debuffs then return end

	
	-- Track how many slots are actually occupied
    local buffCount   = 0
    local debuffCount = 0

	-- Clear previous snapshot
	for k in pairs(buffs)     do buffs[k]     = nil end
	for k in pairs(debuffs)   do debuffs[k]   = nil end
	if buffIds then
		for k in pairs(buffIds)   do buffIds[k]   = nil end
	end
	if debuffIds then
		for k in pairs(debuffIds) do debuffIds[k] = nil end
	end

    local cache = IconCache

    ----------------------------------------------------------------
    -- BUFFS
    ----------------------------------------------------------------
	local i = 1
	while true do
		-- SuperWoW: texture, stacks, spellID
		local tex, _, auraId = UnitBuff(unit, i)
		if not tex then break end
		buffCount = buffCount + 1

		-- Resolve name once: SpellInfo(id) fast path, tooltip-only fallback if needed
		local name = nil
		if auraId and SpellInfo then
			name = SpellInfo(auraId)
		end
		if (not name) or name == "" then
			local n2 = _GetAuraName_TooltipOnly(unit, i, false)
			if n2 and n2 ~= "" then
				name = n2
			end
		end

		if name and name ~= "" then
			buffs[name] = true
			if buffIds and auraId then
				buffIds[auraId] = true
			end

			local list = trackedByName and trackedByName[name]
			if list and type(list) == "table" then
				-- Cache sync (but never gate live updates on cache)
				if tex and cache[name] ~= tex then
					cache[name] = tex
					if DoiteAurasDB and DoiteAurasDB.cache then
						DoiteAurasDB.cache[name] = tex
					end
				end

				local count = table.getn(list)
				local auraIdStr = nil
				for j = 1, count do
					local key = list[j]

					-- 1) Update DB icon always
					if key and DoiteAurasDB and DoiteAurasDB.spells then
						local s = DoiteAurasDB.spells[key]
						if s then
							if tex and tex ~= "" then
								s.iconTexture = tex
							end
							if auraId and (not s.spellid or s.spellid == "") then
								if not auraIdStr then
									auraIdStr = tostring(auraId)
								end
								s.spellid = auraIdStr
							end
							if (not s.displayName or s.displayName == "") then
								s.displayName = name
							end
						end
					end

					-- 2) Update live icon frame even if cache already had it
					local f = _GetIconFrame(key)
					if f and f.icon and tex and f.icon.GetTexture and f.icon.SetTexture then
						if f.icon:GetTexture() ~= tex then
							f.icon:SetTexture(tex)
						end
					end
				end
			end
		end

		i = i + 1
	end

    ----------------------------------------------------------------
    -- DEBUFFS
    ----------------------------------------------------------------
	i = 1
	while true do
		-- SuperWoW: texture, stacks, dtype, spellID
		local tex, _, _, auraId = UnitDebuff(unit, i)
		if not tex then
			break
		end

        debuffCount = debuffCount + 1

		local name = nil
		if auraId and SpellInfo then
			name = SpellInfo(auraId)
		end
		if (not name) or name == "" then
			local n2 = _GetAuraName_TooltipOnly(unit, i, true)
			if n2 ~= nil and n2 ~= "" then
				name = n2
			end
		end

		if type(name) == "string" and name ~= "" then
			debuffs[name] = true
			if debuffIds and auraId then
				debuffIds[auraId] = true
			end

			local list = trackedByName and trackedByName[name]
			if list and type(list) == "table" then
				if tex and cache[name] ~= tex then
					cache[name] = tex
					DoiteAurasDB.cache[name] = tex
				end

				local count = table.getn(list)
				local auraIdStr = nil
				for j = 1, count do
					local key = list[j]
					if key and DoiteAurasDB.spells then
						local s = DoiteAurasDB.spells[key]
						if s then
							if tex and tex ~= "" then
								s.iconTexture = tex
							end
							if auraId and (not s.spellid or s.spellid == "") then
								if not auraIdStr then
									auraIdStr = tostring(auraId)
								end
								s.spellid = auraIdStr
							end
							if (not s.displayName or s.displayName == "") then
								s.displayName = name
							end
						end
					end

					local f = _GetIconFrame(key)
					if f and f.icon and tex and f.icon:GetTexture() ~= tex then
						f.icon:SetTexture(tex)
					end
				end
			end
		end

		i = i + 1
	end
	
	-- Remember how many buff/debuff slots were actually used
    snap.buffCount   = buffCount
    snap.debuffCount = debuffCount
end

---------------------------------------------------------------
-- Local helpers
---------------------------------------------------------------

-- Global alias so update loop can call it without capturing the loc
_G.DoiteConditions_ScanUnitAuras = _ScanUnitAuras

local function InCombat()
    return UnitAffectingCombat("player") == 1
end

-- Power percent (0..100)
local function GetPowerPercent()
    local max = UnitManaMax("player")
    if not max or max <= 0 then return 0 end
    local cur = UnitMana("player")
    return (cur * 100) / max
end

-- === Remaining-time helpers ===

-- Compare helper: returns true if rem (seconds) passes comp vs target (seconds)
local function _RemainingPasses(rem, comp, target)
    if not rem or not comp or target == nil then return true end
    if comp == ">=" then
        return rem >= target
    elseif comp == "<=" then
        return rem <= target
    elseif comp == "==" then
        return rem == target
    end
    return true
end

-- Ability cooldown remaining (in seconds) for a spellbook index; nil if not on CD
local function _AbilityRemainingSeconds(spellIndex, bookType)
    if not spellIndex then return nil end
    local start, dur, enable = GetSpellCooldown(spellIndex, bookType or BOOKTYPE_SPELL)
    if start and dur and start > 0 and dur > 0 then
        local rem = (start + dur) - GetTime()
        if rem and rem > 0 then return rem end
    end
    return nil
end

-- Remaining time by spell *name* (searches spellbook, then calls _AbilityRemainingSeconds)
local function _AbilityRemainingByName(spellName)
    if not spellName then return nil end
    local idx = _GetSpellIndexByName(spellName)
    return _AbilityRemainingSeconds(idx, BOOKTYPE_SPELL)
end

-- Cooldown (remaining, totalDuration) by spell name; nil,nil if not in book
local function _AbilityCooldownByName(spellName)
    if not spellName then return nil, nil end
    local idx = _GetSpellIndexByName(spellName)
    if not idx then return nil, nil end

    local start, dur = GetSpellCooldown(idx, BOOKTYPE_SPELL)
    if start and dur and start > 0 and dur > 0 then
        local rem = (start + dur) - GetTime()
        if rem < 0 then rem = 0 end
        return rem, dur
    else
        return 0, dur or 0
    end
end

-- Spell cooldown check (treats GCD-only as "not on cooldown")
local function _IsSpellOnCooldown(spellIndex, bookType)
    if not spellIndex then return false end
    local start, dur = GetSpellCooldown(spellIndex, bookType or BOOKTYPE_SPELL)
    return (start and start > 0 and dur and dur > 1.5) and true or false
end

-- Nampower-accelerated cache: spellName -> spellId (max rank)
local SpellUsableIdCache = {}

-- NamPower-safe wrapper around IsSpellUsable.
local function _SafeSpellUsable(spellNameBase, spellIndex, bookType)
    if not IsSpellUsable or not spellNameBase then
        return 1, 0
    end

    ----------------------------------------------------------------
    -- 1) Fast path: Nampower present -> spellId + IsSpellUsable(id)
    ----------------------------------------------------------------
    if GetSpellIdForName then
        local sid = SpellUsableIdCache[spellNameBase]

        if sid == nil then
            sid = GetSpellIdForName(spellNameBase)
            SpellUsableIdCache[spellNameBase] = sid or false
        end

        if sid and sid ~= 0 then
            local ok, u, noMana = pcall(IsSpellUsable, sid)
            if ok and u ~= nil then
                return u, noMana
            end
        end
        -- fall through to legacy if no valid id / pcall fail
    end

    ----------------------------------------------------------------
    -- 2) Legacy fallback: old string-based behaviour (rarely used)
    ----------------------------------------------------------------
    local bt  = bookType or BOOKTYPE_SPELL
    local arg = spellNameBase

	if GetSpellName and spellIndex then
		local cached = SpellUsableArgCache[spellIndex]
		if cached and cached.base == spellNameBase then
			arg = cached.arg
		else
			local idxForRank = spellIndex
			local i = spellIndex + 1
			while i <= 200 do
				local n = GetSpellName(i, bt)
				if not n or n ~= spellNameBase then break end
				idxForRank = i
				i = i + 1
			end

			local n, r = GetSpellName(idxForRank, bt)
			if n and r and r ~= "" then
				arg = n .. "(" .. r .. ")"
			else
				arg = spellNameBase
			end

			SpellUsableArgCache[spellIndex] = { base = spellNameBase, arg = arg }
		end
	end

    -- 2a) Preferred legacy call
    local ok, u, noMana = pcall(IsSpellUsable, arg)
    if ok and u ~= nil then
        return u, noMana
    end

    -- 2b) Last resort: plain name (old behaviour)
    ok, u, noMana = pcall(IsSpellUsable, spellNameBase)
    if ok and u ~= nil then
        return u, noMana
    end

    -- 3) Ultimate fallback: treat as usable so icon doesn’t die forever
    return 1, 0
end

-- === Item helpers (inventory / bag lookup & cooldown) =======================
local INV_SLOT_TRINKET1 = 13
local INV_SLOT_TRINKET2 = 14
local INV_SLOT_MAINHAND = 16
local INV_SLOT_OFFHAND  = 17
local INV_SLOT_RANGED   = 18

local function _SlotIndexForName(name)
    if name == "TRINKET1"      then return INV_SLOT_TRINKET1 end
    if name == "TRINKET2"      then return INV_SLOT_TRINKET2 end
    if name == "MAINHAND"      then return INV_SLOT_MAINHAND end
    if name == "OFFHAND"       then return INV_SLOT_OFFHAND end
    if name == "RANGED"        then return INV_SLOT_RANGED end
    return nil
end

-- Per-key memory for TRINKET_FIRST: "first ready wins" and stays the winner
local _TrinketFirstMemory = {}

local function _ClearTrinketFirstMemory()
    for k in pairs(_TrinketFirstMemory) do
        _TrinketFirstMemory[k] = nil
    end
end
_G.DoiteConditions_ClearTrinketFirstMemory = _ClearTrinketFirstMemory

-- Parse itemID and [Name] out of a WoW item link
local function _ParseItemLink(link)
    if not link then return nil, nil end

    local itemId
    local _, _, idStr = str_find(link, "item:(%d+)")
    if idStr then
        itemId = tonumber(idStr)
    end

    local name
    local _, _, nameStr = str_find(link, "%[(.+)%]")
    if nameStr and nameStr ~= "" then
        name = nameStr
    end

    return itemId, name
end

-- Scan player inventory + bags for the configured item
local _ItemScanCache = {}
local _ItemScanGen   = 0
local _ItemScanTTL   = 0.50

local function _InvalidateItemScanCache()
    _ItemScanGen = _ItemScanGen + 1
    -- Keep gen bounded (paranoid)
    if _ItemScanGen > 1000000 then
        _ItemScanGen = 1
        for k in pairs(_ItemScanCache) do
            _ItemScanCache[k] = nil
        end
    end
end

local function _ScanPlayerItemInstances(data)
    if not data then return false, false, nil, nil, 0, 0 end

    local expectedId = data.itemId or data.itemID
    if expectedId then expectedId = tonumber(expectedId) end
    local expectedName = data.itemName or data.displayName or data.name

    -- Cache key
    local cacheKey = nil
    if expectedId then
        cacheKey = "id:" .. expectedId
    elseif expectedName and expectedName ~= "" then
        cacheKey = "name:" .. expectedName
    end

    if cacheKey then
        local c = _ItemScanCache[cacheKey]
        if c then
            local now = GetTime()
            if (c.gen == _ItemScanGen) and c.t and ((now - c.t) < _ItemScanTTL) then
                return c.hasEquipped, c.hasBag, c.eqSlot, c.bagLoc, c.eqCount, c.bagCount
            end
        end
    end

    local hasEquipped, hasBag = false, false
    local firstEquippedSlot   = nil
    local firstBagBag         = nil
    local firstBagSlot        = nil
    local eqCount, bagCount   = 0, 0

    -- Equipped slots (1..19 is enough; trinkets/weapons are in here)
    local slot = 1
    while slot <= 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local id, name = _ParseItemLink(link)
            local match = false
            if expectedId and id then
                match = (id == expectedId)
            elseif expectedName and name then
                match = (name == expectedName)
            end
            if match then
                hasEquipped = true
                if not firstEquippedSlot then
                    firstEquippedSlot = slot
                end

                -- count stack size / charges for this equipped item
                local ccount = 1
                if GetInventoryItemCount then
                    local n = GetInventoryItemCount("player", slot)
                    if n and n > 0 then
                        ccount = n
                    end
                end
                eqCount = eqCount + ccount
            end
        end
        slot = slot + 1
    end

    -- Bags 0..4
    local bag = 0
    while bag <= 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            local bslot = 1
            while bslot <= numSlots do
                local link = GetContainerItemLink(bag, bslot)
                if link then
                    local id, name = _ParseItemLink(link)
                    local match = false
                    if expectedId and id then
                        match = (id == expectedId)
                    elseif expectedName and name then
                        match = (name == expectedName)
                    end
                    if match then
                        hasBag = true
                        if (not firstBagBag) then
                            firstBagBag  = bag
                            firstBagSlot = bslot
                        end

                        -- count items in this bag slot
                        local ccount = 1
                        if GetContainerItemInfo then
                            local _, n = GetContainerItemInfo(bag, bslot)
                            if n and n > 0 then
                                ccount = n
                            end
                        end
                        bagCount = bagCount + ccount
                    end
                end
                bslot = bslot + 1
            end
        end
        bag = bag + 1
    end

    local firstBagLoc = nil
    if firstBagBag ~= nil then
        firstBagLoc = { bag = firstBagBag, slot = firstBagSlot }
    end

    -- Store in cache (reusing bagLoc table)
    if cacheKey then
        local c = _ItemScanCache[cacheKey]
        if not c then
            c = {}
            _ItemScanCache[cacheKey] = c
        end

        c.gen        = _ItemScanGen
        c.t          = GetTime()
        c.hasEquipped = hasEquipped
        c.hasBag      = hasBag
        c.eqSlot      = firstEquippedSlot
        c.eqCount     = eqCount
        c.bagCount    = bagCount

        if firstBagLoc then
            if not c.bagLoc then c.bagLoc = {} end
            c.bagLoc.bag  = firstBagLoc.bag
            c.bagLoc.slot = firstBagLoc.slot
        else
            c.bagLoc = nil
        end

        return c.hasEquipped, c.hasBag, c.eqSlot, c.bagLoc, c.eqCount, c.bagCount
    end

    return hasEquipped, hasBag, firstEquippedSlot, firstBagLoc, eqCount, bagCount
end

-- Single inventory slot: does it have an item and is that item on cooldown?
-- Returns: hasItem, onCooldown, rem, dur, isUseItem
local function _GetInventorySlotState(slot)
    if not slot then return false, false, 0, 0, false end
    local link = GetInventoryItemLink("player", slot)
    if not link then return false, false, 0, 0, false end

    local start, dur, enable = GetInventoryItemCooldown("player", slot)
    local rem, onCd = 0, false
    if start and dur and start > 0 and dur > 1.5 then
        rem = (start + dur) - GetTime()
        if rem < 0 then rem = 0 end
        onCd = (rem > 0)
    else
        dur = dur or 0
    end

    -- Detect usable / "Use:"-style items via tooltip text. Cache per exact item link to avoid repeated string.lower() allocations.
    local useCache = DoiteConditions._itemUseCache
    if not useCache then
        useCache = {}
        DoiteConditions._itemUseCache = useCache
    end

    local isUse = useCache[link]
    if isUse == nil then
        _EnsureTooltip()
        DoiteConditionsTooltip:ClearLines()
        DoiteConditionsTooltip:SetInventoryItem("player", slot)

        isUse = false
        local i = 1
        while i <= 15 do
            local fs = _CondTipLeft[i]
            if not fs or not fs.GetText then break end
            local txt = fs:GetText()
            if txt and txt ~= "" then
                local lower = string.lower(txt)
                if str_find(lower, "use:") or str_find(lower, "use ")
                   or str_find(lower, "consume") then
                    isUse = true
                    break
                end
            end
            i = i + 1
        end

        useCache[link] = isUse
    end

    return true, onCd, rem, dur or 0, isUse
end

-- Core item state used by both condition checks and text overlays
local _ItemStateScratch = {
    hasItem        = false,
    isMissing      = false,
    passesWhere    = true,
    modeMatches    = true,
    rem            = nil,
    dur            = nil,

    -- stack/amount tracking
    eqCount        = 0,   -- total amount in equipped gear
    bagCount       = 0,   -- total amount in bags (0..4)
    totalCount     = 0,   -- eqCount + bagCount
    effectiveCount = 0,   -- count restricted by whereBag/whereEquipped
}

local function _ResetItemState(state)
    state.hasItem        = false
    state.isMissing      = false
    state.passesWhere    = true
    state.modeMatches    = true
    state.rem            = nil
    state.dur            = nil

    -- reset counts
    state.eqCount        = 0
    state.bagCount       = 0
    state.totalCount     = 0
    state.effectiveCount = 0
end


local function _EvaluateItemCoreState(data, c)
    local state = _ItemStateScratch
    _ResetItemState(state)

    if not data or not c then
        return state
    end

    local invSlotName = c.inventorySlot

    -- --------------------------------------------------------------------
    -- 1) Synthetic inventory-slot entries (equipped trinkets / weapons)
    -- --------------------------------------------------------------------
    if invSlotName and invSlotName ~= "" then
        local mode = c.mode or ""
        local key  = data and data.key

        -- Direct 1:1 slot bindings (TRINKET1 / TRINKET2 / MAINHAND / OFFHAND / RANGED)
        if invSlotName == "TRINKET1" or invSlotName == "TRINKET2"
           or invSlotName == "MAINHAND" or invSlotName == "OFFHAND"
           or invSlotName == "RANGED" then

            local idx = _SlotIndexForName(invSlotName)
            local hasItem, onCd, rem, dur = _GetInventorySlotState(idx)
            state.hasItem   = hasItem
            state.isMissing = not hasItem
            state.rem       = rem
            state.dur       = dur

            if mode == "oncd" then
                state.modeMatches = (hasItem and onCd)
            elseif mode == "notcd" then
                state.modeMatches = (hasItem and (not onCd))
            else
                state.modeMatches = true
            end

        -- Composite “equipped trinkets” synthetic entries
        elseif invSlotName == "TRINKET_FIRST" or invSlotName == "TRINKET_BOTH" then
            local has1, on1, rem1, dur1, isUse1 = _GetInventorySlotState(INV_SLOT_TRINKET1)
            local has2, on2, rem2, dur2, isUse2 = _GetInventorySlotState(INV_SLOT_TRINKET2)

            local use1 = has1 and isUse1
            local use2 = has2 and isUse2

            -- If none are usable / have a use-effect, never show
            if not use1 and not use2 then
                state.hasItem     = false
                state.isMissing   = true
                state.modeMatches = false
                state.passesWhere = true

                -- counts for synthetic entries
                state.eqCount        = 0
                state.bagCount       = 0
                state.totalCount     = 0
                state.effectiveCount = 0

                return state
            end

            state.hasItem   = (use1 or use2)
            state.isMissing = not state.hasItem

            if invSlotName == "TRINKET_FIRST" then
                -- “First ready” semantics with memory per key:
                local prevSlot = key
                                  and _TrinketFirstMemory[key]
                                  and _TrinketFirstMemory[key].slot
                                  or nil
                local winner = prevSlot

                if mode == "notcd" then
                    -- A slot is “ready” if it is a usable trinket and not on cooldown.
                    local function slotReady(useFlag, onCdFlag)
                        return useFlag and (not onCdFlag)
                    end

                    -- Drop previous winner if it stopped being ready/usable.
                    if winner == INV_SLOT_TRINKET1
                       and not slotReady(use1, on1) then
                        winner = nil
                    elseif winner == INV_SLOT_TRINKET2
                       and not slotReady(use2, on2) then
                        winner = nil
                    end

                    if not winner then
                        if slotReady(use1, on1) then
                            winner = INV_SLOT_TRINKET1
                        elseif slotReady(use2, on2) then
                            winner = INV_SLOT_TRINKET2
                        end
                    end

                    if winner == INV_SLOT_TRINKET1 then
                        state.modeMatches = slotReady(use1, on1)
                        state.rem = rem1
                        state.dur = dur1
                    elseif winner == INV_SLOT_TRINKET2 then
                        state.modeMatches = slotReady(use2, on2)
                        state.rem = rem2
                        state.dur = dur2
                    else
                        state.modeMatches = false
                    end

                    if key then
                        if winner then
                            _TrinketFirstMemory[key] = _TrinketFirstMemory[key] or {}
                            _TrinketFirstMemory[key].slot = winner
                        else
                            _TrinketFirstMemory[key] = nil
                        end
                    end

                elseif mode == "oncd" then
                    -- On-CD mode: any usable trinket on cooldown passes; pick the one
                    local found, bestRem, bestDur = false, nil, nil

                    if use1 and on1 then
                        found   = true
                        bestRem = rem1
                        bestDur = dur1
                        winner  = INV_SLOT_TRINKET1
                    end
                    if use2 and on2 then
                        if (not found) or (rem2 < bestRem) then
                            found   = true
                            bestRem = rem2
                            bestDur = dur2
                            winner  = INV_SLOT_TRINKET2
                        end
                    end

                    state.modeMatches = found
                    state.rem = bestRem
                    state.dur = bestDur

                    if key then
                        if winner then
                            _TrinketFirstMemory[key] = _TrinketFirstMemory[key] or {}
                            _TrinketFirstMemory[key].slot = winner
                        else
                            _TrinketFirstMemory[key] = nil
                        end
                    end
                else
                    -- No explicit mode: just report presence of any usable trinket.
                    state.modeMatches = (use1 or use2)
                    state.rem = nil
                    state.dur = nil
                end

            else
                -- TRINKET_BOTH: Require all equipped use-trinkets to be in the requested state.
                if mode == "oncd" then
                    local ok = true
                    if use1 and not on1 then ok = false end
                    if use2 and not on2 then ok = false end
                    state.modeMatches = ok
                    if ok then
                        local r1 = (use1 and rem1) or 0
                        local r2 = (use2 and rem2) or 0
                        state.rem = (r1 > r2) and r1 or r2
                        state.dur = dur1 or dur2
                    end
                elseif mode == "notcd" then
                    local ok = true
                    if use1 and on1 then ok = false end
                    if use2 and on2 then ok = false end
                    state.modeMatches = ok
                    if ok then
                        state.rem = 0
                        state.dur = dur1 or dur2
                    end
                else
                    state.modeMatches = true
                end
            end
        end

        -- No Whereabouts for synthetic entries; treat as pass
        state.passesWhere = true

        -- for synthetic entries, treat "stack count" as 1 if an item exists
        if state.hasItem then
            state.eqCount        = 1
            state.bagCount       = 0
            state.totalCount     = 1
            state.effectiveCount = 1
        else
            state.eqCount        = 0
            state.bagCount       = 0
            state.totalCount     = 0
            state.effectiveCount = 0
        end

        return state
    end

    -- --------------------------------------------------------------------
    -- 2) Normal items (Whereabouts: equipped / bag / missing)
    -- --------------------------------------------------------------------
    local hasEquipped, hasBag, eqSlot, bagLoc, eqCount, bagCount = _ScanPlayerItemInstances(data)
    local missing = (not hasEquipped and not hasBag)

    state.hasItem   = not missing
    state.isMissing = missing

    -- raw counts
    state.eqCount    = eqCount or 0
    state.bagCount   = bagCount or 0
    state.totalCount = (state.eqCount or 0) + (state.bagCount or 0)

    local passWhere = false
    if c.whereEquipped and hasEquipped then passWhere = true end
    if c.whereBag      and hasBag      then passWhere = true end
    if c.whereMissing  and missing     then passWhere = true end
    state.passesWhere = passWhere

    -- effective count only from selected whereabouts
    local eff = 0
    if c.whereEquipped and state.eqCount and state.eqCount > 0 then
        eff = eff + state.eqCount
    end
    if c.whereBag and state.bagCount and state.bagCount > 0 then
        eff = eff + state.bagCount
    end
    -- If only whereMissing is set, eff stays 0; DoiteEdit hides stack UI there.
    state.effectiveCount = eff

    if not passWhere then
        return state
    end

    -- prefer equipped if present, otherwise first bag occurrence
    local kind, loc = nil, nil
    if eqSlot then
        kind = "inv"
        loc  = eqSlot
    elseif bagLoc then
        kind = "bag"
        loc  = bagLoc
    end

    if kind and loc then
        local hasItem, onCd, rem, dur
        if kind == "inv" then
            local link = GetInventoryItemLink("player", loc)
            hasItem = (link ~= nil)
            local start, dur0, enable = GetInventoryItemCooldown("player", loc)
            if start and dur0 and start > 0 and dur0 > 1.5 then
                rem = (start + dur0) - GetTime()
                if rem < 0 then rem = 0 end
                onCd = (rem > 0)
                dur  = dur0
            else
                onCd = false
                rem  = 0
                dur  = dur0 or 0
            end
        else
            local link = GetContainerItemLink(loc.bag, loc.slot)
            hasItem = (link ~= nil)
            local start, dur0, enable = GetContainerItemCooldown(loc.bag, loc.slot)
            if start and dur0 and start > 0 and dur0 > 1.5 then
                rem = (start + dur0) - GetTime()
                if rem < 0 then rem = 0 end
                onCd = (rem > 0)
                dur  = dur0
            else
                onCd = false
                rem  = 0
                dur  = dur0 or 0
            end
        end

        if not state.hasItem and hasItem then
            state.hasItem   = true
            state.isMissing = false
        end

        state.rem = rem
        state.dur = dur

        local mode = c.mode or ""
        if mode == "oncd" then
            state.modeMatches = (hasItem and onCd)
        elseif mode == "notcd" then
            state.modeMatches = (hasItem and (not onCd))
        else
            state.modeMatches = true
        end
    else
        -- No instance at all (no eqSlot/bagLoc)
        if missing and c.whereMissing then
            state.modeMatches = true
            state.rem = 0
            state.dur = 0
        else
            local mode = c.mode or ""
            if mode == "oncd" or mode == "notcd" then
                state.modeMatches = false
            end
        end
    end

    return state
end

-- =================================================================
-- Lightweight Combat Log Watcher
-- =================================================================

-- For slider gating: which spells have we actually seen cast?
_G["Doite_SliderSeen"] = _G["Doite_SliderSeen"] or {}
local _SliderSeen = _G["Doite_SliderSeen"]

local _SliderNoCastWhitelist = {
    -- Druid
    ["Hurricane"]   = true,
    ["Tranquility"] = true,

    -- Hunter
    ["Volley"]      = true,

    -- Shaman (totem-based AoE nukes)
    ["Fire Nova Totem"] = true,

    -- Warlock
    ["Inferno"]      = true,
}

local function _MarkSliderSeen(spellName)
    if not spellName or spellName == "" then return end
    _SliderSeen[spellName] = GetTime() or 0
end

-- ============================================================
-- Proc-window timers (NOT cooldown timers)
-- ============================================================
_G.DoiteConditions_ProcWindowDurations = _G.DoiteConditions_ProcWindowDurations or {
    ["Overpower"]       = 4.0,
    ["Revenge"]         = 4.0,
    ["Surprise Attack"] = 4.0,
    ["Arcane Surge"]    = 4.0,
}
local _PROC_DUR = _G.DoiteConditions_ProcWindowDurations

-- SpellName -> absolute endTime (GetTime() + duration)
_G.DoiteConditions_ProcUntil = _G.DoiteConditions_ProcUntil or {}
local _ProcUntil = _G.DoiteConditions_ProcUntil

-- Per-icon rising-edge detector for "usable proc" icons
_G.DoiteConditions_ProcLastShowByKey = _G.DoiteConditions_ProcLastShowByKey or {}
local _ProcLastShowByKey = _G.DoiteConditions_ProcLastShowByKey

local function _ProcWindowDuration(spellName)
    if not spellName then return nil end
    local d = _PROC_DUR and _PROC_DUR[spellName]
    if type(d) == "number" and d > 0 then return d end
    return nil
end

local function _ProcWindowSet(spellName, endTime)
    if not spellName or not endTime then return end
    _ProcUntil[spellName] = endTime

    dirty_ability_time = true
    dirty_ability      = true

    _RequestImmediateEval()
end

local function _ProcWindowRemaining(spellName)
    if not spellName then return nil end
    local untilT = _ProcUntil and _ProcUntil[spellName]
    if untilT then
        local rem = untilT - (_Now() or 0)
        if rem and rem > 0 then return rem end
    end
    return nil
end

-- Keep warrior-specific state for target-matching
local _OP_until, _OP_target = 0, nil
local _REV_until            = 0

-- Canonical ability name resolver (spellbook name preferred)
local function _GetCanonicalSpellNameFromData(data)
    if not data or type(data) ~= "table" then return nil end
    if data.name and data.name ~= "" then
        -- This is the canonical spellbook name (what GetSpellName sees)
        return data.name
    end
    if data.displayName and data.displayName ~= "" then
        return data.displayName
    end
    return nil
end

-- =================================================================
-- SuperWoW: UNIT_CASTEVENT -> cooldown ownership (PLAYER ONLY)
-- =================================================================
local _playerGUID_cached = nil

-- SuperWoW: UnitExists(unit) -> exists, guid
local function _GetUnitGuid(unit)
    if not unit or not UnitExists then return nil end
    local exists, guid = UnitExists(unit)
    if exists and guid and guid ~= "" then
        return guid
    end
    return nil
end

local function _GetPlayerGUID()
    if _playerGUID_cached then
        return _playerGUID_cached
    end
    local guid = _GetUnitGuid("player")
    if guid and guid ~= "" then
        _playerGUID_cached = guid
        return guid
    end
    return nil
end

local _daCast = CreateFrame("Frame", "DoiteCast")
_daCast:RegisterEvent("UNIT_CASTEVENT")
_daCast:SetScript("OnEvent", function()
    local casterGUID = arg1
    local evType     = arg3
    local spellId    = arg4

    -- ONLY use this for slider ownership: only completed SPELL casts
    if evType ~= "CAST" then
        return
    end

    -- Critical: ignore other units' casts
    local pg = _GetPlayerGUID()
    if pg and casterGUID and casterGUID ~= pg then
        return
    end

    if not spellId or not SpellInfo then
        return
    end

    local name = SpellInfo(spellId)
    if type(name) ~= "string" or name == "" then
        return
    end

    _MarkSliderSeen(name)
end)

-- Check class and register only the events we need for reactive procs
local _daClassCL = CreateFrame("Frame", "DoiteClassCL")
local _daClassCL2 = CreateFrame("Frame", "DoiteClassCL2")

do
	local _, cls = UnitClass("player")
	cls = cls and string.upper(cls) or ""

	if cls == "WARRIOR" then
		-- Overpower: needs dodge detection
		_daClassCL:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")

		_daClassCL:SetScript("OnEvent", function()
			local line = arg1
			if not line or line == "" then return end

			-- Overpower: target dodged you
			local tgt
			local _, _, t1 = str_find(line, "You attack%.%s+(.+)%s+dodges")
			if t1 then
				tgt = t1
			else
				local _, _, t2 = str_find(line, "Your%s+.+%s+was%s+dodged%s+by%s+(.+)")
				tgt = t2
			end

			if tgt then
				tgt = str_gsub(tgt, "%s*[%.!%?]+%s*$", "")
				_OP_target = tgt

				local now = _Now()
				local dur = _ProcWindowDuration("Overpower") or 4.0
				_OP_until = now + dur
				_ProcWindowSet("Overpower", _OP_until)
			end
		end)

		-- Revenge: needs incoming hits/blocks/parries/dodges
		_daClassCL2:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
		_daClassCL2:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")

		_daClassCL2:SetScript("OnEvent", function()
			local line = arg1
			if not line or line == "" then return end

			-- Revenge: you dodged/parried/blocked
			if str_find(line, "You dodge")
			   or str_find(line, "You parry")
			   or str_find(line, "You block")
			   or ((str_find(line, " hits you for ") or str_find(line, " crits you for "))
				   and str_find(line, " blocked)")) then

				local now = _Now()
				local dur = _ProcWindowDuration("Revenge") or 4.0
				_REV_until = now + dur
				_ProcWindowSet("Revenge", _REV_until)

				dirty_ability = true
			end
		end)

	elseif cls == "ROGUE" then
		-- Surprise Attack: needs dodge detection
		_daClassCL:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")

		_daClassCL:SetScript("OnEvent", function()
			local line = arg1
			if not line or line == "" then return end

			-- Surprise Attack: target dodged you
			local dodged = false
			local _, _, t1 = str_find(line, "You attack%.%s+(.+)%s+dodges")
			if t1 then
				dodged = true
			else
				local _, _, t2 = str_find(line, "Your%s+.+%s+was%s+dodged%s+by%s+(.+)")
				if t2 then
					dodged = true
				end
			end

			if dodged then
				local dur = _ProcWindowDuration("Surprise Attack")
				if dur then
					local now = _Now()
					_ProcWindowSet("Surprise Attack", now + dur)
					dirty_ability = true
				end
			end
		end)

	elseif cls == "MAGE" then
		-- Arcane Surge: needs resist detection
		_daClassCL:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")

		_daClassCL:SetScript("OnEvent", function()
			local line = arg1
			if not line or line == "" then return end

			-- Arcane Surge: spell was resisted (fully or partially)
			if str_find(line, " was resisted")
			   or str_find(line, " resisted%)")
			   or str_find(line, " resisted by")
			   or str_find(line, " resists your ") then

				local dur = _ProcWindowDuration("Arcane Surge")
				if dur then
					local now = _Now()
					_ProcWindowSet("Arcane Surge", now + dur)
					dirty_ability = true
				end
			end
		end)
	end
end

-- Helpers consumed by ability-usable override
local function _Warrior_Overpower_OK()
    if (_Now() > _OP_until) then return false end
    if not UnitExists("target") then return false end
    local tname = UnitName("target")
    return (tname ~= nil and _OP_target ~= nil and tname == _OP_target)
end

local function _Warrior_Revenge_OK()
    return _Now() <= _REV_until
end

-- Remaining proc-window time for Overpower / Revenge (seconds), or nil if no proc
local function _WarriorProcRemainingForSpell(spellName)
    -- Back-compat name: now uses the shared proc-window store.
    return _ProcWindowRemaining(spellName)
end


----------------------------------------------------------------
-- DoiteAuras Slide Manager
----------------------------------------------------------------
local SlideMgr = {
    active = {},
}
_G.DoiteConditions_SlideMgr = SlideMgr

local _slideTick = CreateFrame("Frame", "DoiteSlideTick")
_slideTick:Hide()
_slideTick:SetScript("OnUpdate", function()
    local now = GetTime()
    local anyActive = false

    for key, s in pairs(SlideMgr.active) do
        if now >= s.endTime then
            SlideMgr.active[key] = nil
        else
            anyActive = true
        end
    end

    -- While sliding, force abilities to re-paint frequently so positions update smoothly.
    if anyActive then
        dirty_ability = true
    else
        this:Hide()
    end
end)

-- Begin or refresh an animation for 'key'
-- endTime = GetTime() + remaining  (cap remaining inside caller)
function SlideMgr:StartOrUpdate(key, dir, baseX, baseY, endTime)
    local st  = self.active[key]
    local now = GetTime()

    if not endTime then
        endTime = now
    end

    if not st then
        st = {
            dir     = dir or "center",
            baseX   = baseX or 0,
            baseY   = baseY or 0,
            endTime = endTime,
        }

        -- Capture the length of this slide window once so that
        -- t runs cleanly from 1 → 0 and center alpha from 0 → 1.
        local total = st.endTime - now
        if not total or total <= 0 then
            total = 0.01
        end
        st.total = total

        self.active[key] = st
    else
        st.dir   = dir   or st.dir
        st.baseX = baseX or st.baseX
        st.baseY = baseY or st.baseY

        local curEnd = st.endTime or now
        local newEnd = endTime

        local curRem = curEnd - now
        local newRem = newEnd - now
        if curRem < 0 then curRem = 0 end
        if newRem < 0 then newRem = 0 end

        -- Anti-jitter:
        if (newRem > 0.10) and (newRem <= 1.60) and (curRem > 1.60) then
            newEnd = curEnd
            newRem = curRem
        else
            -- Ignore tiny backwards jitter (micro refresh noise)
            if (newEnd < curEnd) and ((curEnd - newEnd) < 0.20) then
                newEnd = curEnd
                newRem = curRem
            end
        end

        -- Hard cap: while sliding, the caller should NOT extend the slide
        local total = st.total or 0
        if total and total > 0 then
            local maxEnd = now + total
            if newEnd > maxEnd then
                newEnd = maxEnd
            end
        end

        if newEnd > curEnd then
            local grow = newEnd - now
            if grow > (st.total or 0) and grow <= 3.05 then
                st.total = grow
            end
        end

        st.endTime = newEnd
        -- NOTE: st.total is intentionally stable (except the small "grow" fix above)
    end

    _slideTick:Show()
end

function SlideMgr:Stop(key)
    self.active[key] = nil
end

-- Query current offsets/alpha. Returns:
-- active:boolean, dx:number, dy:number, alpha:number, suppressGlow:boolean, suppressGrey:boolean
function SlideMgr:Get(key)
    local st = self.active[key]
    if not st then
        return false, 0, 0, 1, false, false
    end

    local now   = GetTime()
    local total = st.total or 3.0
    if total <= 0 then total = 0.01 end

    local remaining = (st.endTime or now) - now
    if remaining < 0 then remaining = 0 end

    -- if endTime drifted beyond the slide window, pull it back.
    if remaining > total then
        if remaining > (total + 0.25) then
            st.endTime = now + total
        end
        remaining = total
    end

    -- t goes from 1 → 0 over the slide window
    local t = remaining / total
    if t < 0 then t = 0 elseif t > 1 then t = 1 end

    local farX, farY = 0, 0
    if     st.dir == "left"  then farX, farY = -80,  0
    elseif st.dir == "right" then farX, farY =  80,  0
    elseif st.dir == "up"    then farX, farY =   0, 80
    elseif st.dir == "down"  then farX, farY =   0,-80
    else
        farX, farY = 0, 0
    end

    local dx = farX * t
    local dy = farY * t

    local alpha
    if st.dir == "center" then
        alpha = 1.0 - t
    else
        alpha = 1.0
    end
    if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end

    return true, dx, dy, alpha, true, true
end

-- For ApplyVisuals to get latest base anchoring while sliding
function SlideMgr:UpdateBase(key, baseX, baseY)
    local st = self.active[key]
    if st then
        st.baseX = baseX or st.baseX
        st.baseY = baseY or st.baseY
    end
end

-- For ApplyVisuals to read current base (even if not sliding)
function SlideMgr:GetBase(key)
    local st = self.active[key]
    if st then return st.baseX or 0, st.baseY or 0 end
    return 0, 0
end

-- Read the baseline (saved) XY for an icon (matches CreateOrUpdateIcon layout precedence)
local function _GetBaseXY(key, dataTbl)
    -- defaults
    local x, y = 0, 0

    -- primary source: DoiteAurasDB.spells
    if DoiteAurasDB and DoiteAurasDB.spells and key and DoiteAurasDB.spells[key] then
        local s = DoiteAurasDB.spells[key]
        x = s.offsetX or s.x or x
        y = s.offsetY or s.y or y
    end

    -- optional override: legacy DoiteDB.icons layout (if present)
    if DoiteDB and DoiteDB.icons and key and DoiteDB.icons[key] then
        local L = DoiteDB.icons[key]
        x = (L.posX or L.offsetX or x)
        y = (L.posY or L.offsetY or y)
    end

    return x, y
end

-- Player-only aura remaining (seconds); nil if not timed / not found.
local function _PlayerAuraRemainingSeconds(auraName)
    if not auraName then return nil end
    if not GetPlayerBuff or not GetPlayerBuffTimeLeft then
        return nil
    end

    _EnsureTooltip()

    local function scan(kind)
        local i = 0
        -- Do NOT break on empty slots; player buff indices can shift.
        while i <= 31 do
            local idx = GetPlayerBuff(i, kind)
            if idx and idx >= 0 then
                DoiteConditionsTooltip:ClearLines()
                DoiteConditionsTooltip:SetPlayerBuff(idx)

                if not _AuraNameTipLeft1FS then
                    _AuraNameTipLeft1FS = _G["DoiteConditionsTooltipTextLeft1"]
                end
                local fs   = _AuraNameTipLeft1FS
                local name = fs and fs:GetText()

                if name and name == auraName then
                    local r = GetPlayerBuffTimeLeft(idx)
                    if r and r > 0 then
                        return r
                    end
                    return nil
                end
            end
            i = i + 1
        end
        return nil
    end

    local r = scan("HELPFUL")
    if r and r > 0 then return r end
    return scan("HARMFUL")
end


local function _DoiteTrackAuraOwnership(spellName, unit)
    if not DoiteTrack or not spellName or not unit then
        return nil, false, nil, false, false, false
    end

    -- Hard dependency on the consolidated helper
    if not DoiteTrack.GetAuraOwnershipByName then
        return nil, false, nil, false, false, false
    end

    local rem, recording, sid, isMine, isOther, ownerKnown =
        DoiteTrack:GetAuraOwnershipByName(spellName, unit)

    -- Normalize booleans
    isMine  = (isMine  == true)
    isOther = (isOther == true)

    local known = (ownerKnown == true) or isMine or isOther

    -- Normalise remaining time
    if rem ~= nil and rem <= 0 then
        rem = nil
    end

    -- For non-player units, if ownership is known and it's NOT mine, don't expose remaining
    if known and unit ~= "player" and (not isMine) then
        rem       = nil
        recording = false
    end

    return rem, recording, sid, isMine, isOther, known
end

-- Unified remaining-time provider used by existing call sites (DoiteTrack only).
local function _DoiteTrackAuraRemainingSeconds(spellName, unit)
    if not DoiteTrack or not spellName or not unit then
        return nil
    end

    if DoiteTrack.GetAuraRemainingSecondsByName then
        local rem = DoiteTrack:GetAuraRemainingSecondsByName(spellName, unit)
        if rem and rem > 0 then
            return rem
        end
    end

	if DoiteTrack.GetAuraRemainingOrRecordingByName then
		local rem2 = DoiteTrack:GetAuraRemainingOrRecordingByName(spellName, unit)
		if rem2 and rem2 > 0 then
			return rem2
		end
	end

    return nil
end


-- Use DoiteTrack to evaluate a remaining-time comparison on a unit.
local function _DoiteTrackRemainingPass(spellName, unit, comp, threshold)
    if not DoiteTrack or not spellName or not unit or not comp or threshold == nil then
        return nil
    end

    if DoiteTrack.RemainingPassesByName then
        -- Add-on helper handles comparison internally
        return DoiteTrack:RemainingPassesByName(spellName, unit, comp, threshold)
    end

    -- Fallback within DoiteTrack: if no helper, compare using numeric remaining
    local rem = _DoiteTrackAuraRemainingSeconds(spellName, unit)
    if rem and rem > 0 then
        return _RemainingPasses(rem, comp, threshold)
    end

    return nil
end

-- For debuff checks only: if all debuff slots are full and the name exists in buffs, treat it as a debuff hit
local function _UnitHasOverflowDebuff(unit, auraName)
    if not unit or not auraName then return false end

    local snap = auraSnapshot[unit]
    if not snap then return false end

    local debuffs = snap.debuffs
    if debuffs and debuffs[auraName] == true then
        return true
    end

    local count = snap.debuffCount or 0
    if count < 16 then
        -- Debuff bar not "full", so don't risk treating a real buff as debuff.
        return false
    end

    local buffs = snap.buffs
    if buffs and buffs[auraName] == true then
        return true
    end

    return false
end

local function _AuraConditions_UnitHasAura(unit, auraName, wantDebuff)
    if not unit or not auraName then return false end
    if unit == "target" and (not UnitExists("target")) then
        return false
    end

    local snap = auraSnapshot[unit]
    if not snap then return false end

    if wantDebuff then
        -- Debuff checks: first real debuffs, then overflow in buffs.
        return _UnitHasOverflowDebuff(unit, auraName)
    else
        local b = snap.buffs
        return b and b[auraName] == true
    end
end

-- Talent helpers for auraConditions (Known / Not known)
local function _TalentIsKnownByName(talentName)
    if not talentName or talentName == "" then
        return false
    end
    if not GetNumTalentTabs or not GetNumTalents or not GetTalentInfo then
        return false
    end

    local numTabs = GetNumTalentTabs()
    if not numTabs or numTabs <= 0 then
        return false
    end

    local tab = 1
    while tab <= numTabs do
        local numTalents = GetNumTalents(tab) or 0
        local idx = 1
        while idx <= numTalents do
            local name, _, _, _, rank = GetTalentInfo(tab, idx)
            if name == talentName then
                return (rank and rank > 0)
            end
            idx = idx + 1
        end
        tab = tab + 1
    end

    return false
end

---------------------------------------------------------------
-- Array compaction helpers (prevents auraConditions nil-holes)
---------------------------------------------------------------
local function _ArrayMaxIndex(t)
    if not t then return 0 end
    local m = 0
    for k in pairs(t) do
        if type(k) == "number" and k > m then
            m = k
        end
    end
    return m
end

local function _CompactArrayInPlace(t)
    if not t then return end

    local max = _ArrayMaxIndex(t)
    if max <= 0 then return end

    local write = 1
    local i = 1
    while i <= max do
        local v = t[i]
        if v ~= nil then
            if write ~= i then
                t[write] = v
                t[i] = nil
            end
            write = write + 1
        end
        i = i + 1
    end

    -- Ensure any trailing numeric slots are nil
    i = write
    while i <= max do
        t[i] = nil
        i = i + 1
    end
end

local function _AuraConditions_CheckEntry(entry)
    if not entry or not entry.buffType or not entry.mode then
        return true
    end
    local name = entry.name
    if not name or name == "" then
        return true
    end

    -- ABILITY branch: use cooldown by spell name
    if entry.buffType == "ABILITY" then
        if entry.mode == "notcd" or entry.mode == "oncd" then
            local rem, dur = _AbilityCooldownByName(name)
            if rem == nil then
                -- Ability not in spellbook => cannot satisfy this condition
                return false
            end

            -- Treat pure global cooldown (very short duration) as "not really on cooldown" to avoid flickering auraConditions when other spells trigger the GCD.
            local onCd = false
            if rem and rem > 0 then
                if dur and dur > 1.5 then
                    onCd = true
                else
                    onCd = false
                end
            end

            if entry.mode == "notcd" then
                return (not onCd)
            else -- "oncd"
                return onCd
            end
        else
            -- Unsupported mode for ABILITY; ignore rather than fail
            return true
        end
    end

-- Cache TALENT mode normalization by raw string to avoid per-eval lower/gsub allocations
local _DA_TalentModeKeyByRaw = _DA_TalentModeKeyByRaw or {}

    -- TALENT CONDITION BRANCH (Known / Not known)
    if entry.buffType == "TALENT" then
        local modeRaw = entry.mode or ""
        local modeKey = _DA_TalentModeKeyByRaw[modeRaw]
        if not modeKey then
            modeKey = string.lower(modeRaw)
            -- Normalize: "Not Known", "not known", "notknown" -> "notknown"
            modeKey = str_gsub(modeKey, "%s+", "")
            _DA_TalentModeKeyByRaw[modeRaw] = modeKey
        end

        local isKnown = _TalentIsKnownByName(name)

        if modeKey == "known" then
            return isKnown
        elseif modeKey == "notknown" then
            return (not isKnown)
        else
            -- Unknown mode => do not fail the whole list
            return true
        end
    end
    -- === END TALENT CONDITION BRANCH (Known / Not known) ===

    -- BUFF / DEBUFF branch: check unit auras
    local unit = entry.unit or "player"
    if unit ~= "player" and unit ~= "target" then
        unit = "player"
    end

    -- If explicitly target "target" but have no target, do not pass
    if unit == "target" and (not UnitExists("target")) then
        return false
    end

    local wantDebuff = (entry.buffType == "DEBUFF")
    local hasAura    = _AuraConditions_UnitHasAura(unit, name, wantDebuff)

    if entry.mode == "found" then
        return hasAura
    elseif entry.mode == "missing" then
        return (not hasAura)
    end

    -- Unknown mode => do not fail the whole list
    return true
end

local function _EvaluateAuraConditionsList(list)
    if not list then
        return true
    end

    -- Critical: remove nil holes so neither table.getn() nor DoiteLogic._len() truncates the list.
    _CompactArrayInPlace(list)

    local n = table.getn(list)
    if n == 0 then
        return true
    end

    local DL = _G["DoiteLogic"]
    if DL and DL.EvaluateAuraList then
        return DL.EvaluateAuraList(list, _AuraConditions_CheckEntry)
    end

    -- Fallback: original strict AND semantics
    local i = 1
    while i <= n do
        if not _AuraConditions_CheckEntry(list[i]) then
            return false
        end
        i = i + 1
    end
    return true
end

-- Global wrapper to reduce upvalues in big condition functions
function DoiteConditions_EvaluateAuraConditionsList(list)
    return _EvaluateAuraConditionsList(list)
end

-- === Stacks helpers ===

-- Compare: returns true if 'cnt' satisfies 'comp' vs 'target'
local function _StacksPasses(cnt, comp, target)
    if not cnt or not comp or target == nil then return true end
    if comp == ">=" then
        return cnt >= target
    elseif comp == "<=" then
        return cnt <= target
    elseif comp == "==" then
        return cnt == target
    end
    return true
end

-- Get stack count for a named aura on a unit (works for player/target) if all debuff slots are full and the debuff has overflown into the buff list, also read stacks from UnitBuff.
local function _GetAuraStacksOnUnit(unit, auraName, wantDebuff)
    if not unit or not auraName then return nil end

    ----------------------------------------------------------------
    -- 1) Primary scan: normal BUFF / DEBUFF list (unchanged)
    ----------------------------------------------------------------
    local i = 1
    while i <= 40 do
        local tex, applications, auraId
        if wantDebuff then
            -- texture, stacks, dtype, spellID
            tex, applications, _, auraId = UnitDebuff(unit, i)
        else
            -- texture, stacks, spellID
            tex, applications, auraId = UnitBuff(unit, i)
        end
        if not tex then
            break
        end

        local name
        if auraId and SpellInfo then
            name = SpellInfo(auraId)
        end

        if name == auraName then
            return applications or 1
        end

        i = i + 1
    end


    -- If debuff bar is "full" (>=16) and the aura name is present in the BUFF snapshot, treat it as an overflowed debuff and read stacks from UnitBuff.
    if wantDebuff then
        local snap = auraSnapshot[unit]
        if snap then
            local debCount = snap.debuffCount or 0
            local buffs    = snap.buffs

            if debCount >= 16 and buffs and buffs[auraName] then
                -- First try a SpellInfo-based pass (mirrors main loop)
                local j = 1
                while j <= 40 do
                    local tex2, applications2, auraId2 = UnitBuff(unit, j)
                    if not tex2 then
                        break
                    end

                    local name2
                    if auraId2 and SpellInfo then
                        name2 = SpellInfo(auraId2)
                    end

                    if name2 == auraName then
                        return applications2 or 1
                    end

                    j = j + 1
                end

                -- Fallback: tooltip-based name resolution via _GetAuraName, then a second UnitBuff call to read stacks.
                j = 1
                while j <= 40 do
                    local n = _GetAuraName(unit, j, false)
                    if n == nil then
                        break
                    end
                    if n ~= "" and n == auraName then
                        local _, applications3 = UnitBuff(unit, j)
                        return applications3 or 1
                    end
                    j = j + 1
                end
            end
        end
    end

    return nil
end

-- Fast check: does unit have ANY of the named buffs?
local function _UnitHasAnyBuffName(unit, names)
    if not unit or not names then return false end

    local snap = auraSnapshot[unit]
    local b = snap and snap.buffs
    if not b then return false end

    local n = table.getn(names)
    for i = 1, n do
        if b[names[i]] then
            return true
        end
    end
    return false
end


-- === Health / Combo Points / Formatting helpers ===

-- Percent HP (0..100) for unit; returns nil if unit invalid or no maxhp
local function _HPPercent(unit)
    if not unit or not UnitExists(unit) then return nil end
    local cur = UnitHealth(unit)
    local max = UnitHealthMax(unit)
    if not cur or not max or max <= 0 then return nil end
    return (cur * 100) / max
end

-- Compare helper: returns true if 'val' satisfies 'comp' vs 'target'
local function _ValuePasses(val, comp, target)
    if val == nil or comp == nil or target == nil then return true end
    if comp == ">=" then
        return val >= target
    elseif comp == "<=" then
        return val <= target
    elseif comp == "==" then
        return val == target
    end
    return true
end

-- Combo points reader
local function _GetComboPointsSafe()
    if not UnitExists("target") then return 0 end
    local cp = GetComboPoints("player", "target")
    if not cp then return 0 end
    return cp
end

-- Class that uses combo points
local function _PlayerUsesComboPoints()
    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    return (cls == "ROGUE" or cls == "DRUID")
end

-- === Target Distance / AoE / Unit Type helpers ==========================
-- Mapping used by the editor labels ("1. Humanoid", "Multi: 1+2", etc.)
local UNIT_TYPE_INDEX_MAP = {
    [1] = "Humanoid",
    [2] = "Beast",
    [3] = "Dragonkin",
    [4] = "Undead",
    [5] = "Demon",
    [6] = "Giant",
    [7] = "Mechanical",
    [8] = "Elemental",
}

-- Normalizes "Any"/nil/"" → nil (meaning "no restriction")
local function _NormalizeTargetField(val)
    if not val or val == "" or val == "Any" then
        return nil
    end
    return val
end

-- Optional: spell range in yards from DBC ("rangeMax" is yards * 10)
local function _GetSpellMaxRangeYds(spellName)
    if not spellName or not GetSpellIdForName or not GetSpellRecField then
        return nil
    end
    local sid = GetSpellIdForName(spellName)
    if not sid or sid <= 0 then return nil end

    local raw = GetSpellRecField(sid, "rangeMax")
    if not raw or raw <= 0 then return nil end

    return raw / 10
end

---------------------------------------------------------------
-- Spell range overrides and resurrection spell list
---------------------------------------------------------------

-- Spells whose IsSpellInRange return values are unreliable; treat them as explicit melee or ranged for distance checks instead of trusting API.
local _SpellRangeOverrideByClass = {
    WARRIOR = {
        ["Heroic Strike"] = "melee",
        ["Cleave"]        = "melee",
        -- Add more warrior spells here if needed.
    },
    -- Add other classes here if I discover more broken spells.
}

local _SpellRangeOverrideCache = {}
local _playerClass = nil

local function _GetPlayerClassToken()
    if _playerClass and _playerClass ~= "" then
        return _playerClass
    end
    if UnitClass then
        local _, cls = UnitClass("player")
        _playerClass = cls and string.upper(cls) or ""
    else
        _playerClass = ""
    end
    return _playerClass
end

local function _GetSpellRangeOverrideMode(spellName)
    if not spellName then return nil end

    local cached = _SpellRangeOverrideCache[spellName]
    if cached ~= nil then
        return (cached ~= false) and cached or nil
    end

    local cls = _GetPlayerClassToken()
    local mode = nil
    local byClass = _SpellRangeOverrideByClass[cls]
    if byClass then
        mode = byClass[spellName]
    end

    if mode then
        _SpellRangeOverrideCache[spellName] = mode
        return mode
    end

    _SpellRangeOverrideCache[spellName] = false
    return nil
end

-- Resurrection spells that are allowed to do distance checks on dead friendly targets.
local _ResurrectionSpellByName = {
    ["Rebirth"]          = true, -- Druid
    ["Redemption"]       = true, -- Paladin
    ["Resurrection"]     = true, -- Priest
    ["Ancestral Spirit"] = true, -- Shaman
}

local function _IsResurrectionSpell(spellName)
    if not spellName then return false end
    return _ResurrectionSpellByName[spellName] == true
end

-- These are NOT yards, they are xp3's normalized melee meter.
_G.DoiteConditions_MeleeRangeByRace = _G.DoiteConditions_MeleeRangeByRace or {
    -- Small hitbox races
    GNOME      = 0.20,
    GOBLIN     = 0.20,

    -- "Normal" body size races
    HUMAN      = 0.23,
    ORC        = 0.23,
    TROLL      = 0.23,
    DWARF      = 0.23,
    NIGHTELF   = 0.23,
    BLOODELF   = 0.23,
    SCOURGE    = 0.23,

    -- Big bois
    TAUREN     = 0.30,
}

_G.DoiteConditions_MeleeRangeDefault = _G.DoiteConditions_MeleeRangeDefault or 0.23

local _playerMeleeThreshold = nil

local function _GetPlayerMeleeThreshold()
    if _playerMeleeThreshold then
        return _playerMeleeThreshold
    end

    local byRace = _G.DoiteConditions_MeleeRangeByRace or {}

    local raceName, raceFile
    if UnitRace then
        raceName, raceFile = UnitRace("player")
    end

    local key = nil
    if raceFile and raceFile ~= "" then
        -- Stable, non-localized token: "Goblin","Tauren","NightElf","Scourge", etc.
        key = string.upper(raceFile)
    elseif raceName and raceName ~= "" then
        -- Fallback: strip spaces and upper-case
        key = string.upper(string.gsub(raceName, "%s+", ""))
    end

    local thr = _G.DoiteConditions_MeleeRangeDefault or 0.23
    if key and byRace[key] then
        thr = byRace[key]
    end

    _playerMeleeThreshold = thr
    return thr
end

local function _RefreshPlayerMeleeThreshold()
    _playerMeleeThreshold = nil
    _GetPlayerMeleeThreshold()
end

-- Generic distance in yards from player to unit; optional "mode" tuning for UnitXP
local function _GetUnitDistanceYds(unit, mode)
    if type(UnitXP) ~= "function" or not UnitExists then
        return nil
    end
    local exists = UnitExists(unit)
    if not exists then return nil end

    local ok, dist
    if mode == "melee" then
        ok, dist = pcall(UnitXP, "distanceBetween", "player", unit, "meleeAutoAttack")
    elseif mode == "aoe" then
        ok, dist = pcall(UnitXP, "distanceBetween", "player", unit, "AoE")
    else
        ok, dist = pcall(UnitXP, "distanceBetween", "player", unit)
    end

    if not ok or type(dist) ~= "number" or dist < 0 then
        return nil
    end
    return dist
end

-- Nampower-safe IsSpellInRange wrapper; returns true/false or nil if unknown
local function _IsSpellInRangeSafe(spellName, unit)
    if not spellName or not unit or type(IsSpellInRange) ~= "function" then
        return nil
    end

    local sid = nil
    if GetSpellIdForName then
        sid = GetSpellIdForName(spellName)
    end

    local ok, res
    if sid and sid ~= 0 then
        ok, res = pcall(IsSpellInRange, sid, unit)
    else
        ok, res = pcall(IsSpellInRange, spellName, unit)
    end
    if not ok then return nil end

    if res == 1 then
        return true
    elseif res == 0 then
        return false
    end
    return nil
end

-- Generic "In range" threshold (non-spell icons) in default UnitXP distance units.
_G.DoiteConditions_GenericInRangeThreshold = _G.DoiteConditions_GenericInRangeThreshold or 1.5

-- Ranged-override threshold (yards) when treating a spell as pure ranged.
_G.DoiteConditions_RangedOverrideThresholdYds = _G.DoiteConditions_RangedOverrideThresholdYds or 30

-- Main "targetDistance" eval
local function _PassesTargetDistance(condTbl, unit, spellName)
    if not condTbl or not unit then return true end

    local val = _NormalizeTargetField(condTbl.targetDistance)
    if not val then
        return true
    end
    if not UnitExists or not UnitExists(unit) then
        return true
    end

    local isDead    = UnitIsDead and UnitIsDead(unit) == 1
    local isFriend  = UnitIsFriend and UnitIsFriend("player", unit)
    local canAttack = UnitCanAttack and UnitCanAttack("player", unit)
    local isHostile = canAttack and (not isFriend)

    -- Positional checks first
    if val == "Behind" then
        if type(UnitXP) == "function" then
            local ok, behind = pcall(UnitXP, "behind", "player", unit)
            if ok then
                return (behind == true)
            end
        end
        return true

    elseif val == "In front" then
        if type(UnitXP) == "function" then
            local okB, behind  = pcall(UnitXP, "behind",  "player", unit)
            local okS, inSight = pcall(UnitXP, "inSight", "player", unit)
            if not okB then behind  = false end
            if not okS then inSight = true  end
            return (not behind) and (inSight ~= false)
        end
        return true
    end

    -- Dead-target guard for range-based checks
    if val == "In range" or val == "Not in range" or val == "Melee range" then
        if isDead then
            local allowRes = false
            if spellName and isFriend and (not isHostile) then
                if _IsResurrectionSpell(spellName) then
                    allowRes = true
                end
            end

            -- Harmful dead or friendly dead with non-res spell: distance condition should simply NOT pass
            if not allowRes then
                return false
            end
        end
    end

    ----------------------------------------------------------------
    -- Range-based checks ("In range", "Not in range", "Melee range")
    ----------------------------------------------------------------
    local inRange = nil
    local overrideMode = nil

    if spellName then
        overrideMode = _GetSpellRangeOverrideMode(spellName)
    end

    -- Prefer IsSpellInRange when knowing which spell this icon represents
    if spellName and overrideMode == nil then
        inRange = _IsSpellInRangeSafe(spellName, unit)
    end

    -- Fallback when IsSpellInRange isn't usable
    if inRange == nil then
        if spellName then
            if overrideMode == "melee" then
                local dist = _GetUnitDistanceYds(unit, "melee") or _GetUnitDistanceYds(unit, nil)
                if not dist then
                    inRange = true
                else
                    local thr = _GetPlayerMeleeThreshold()
                    inRange = (dist <= thr)
                end

            elseif overrideMode == "range" then
                -- Broken spell flagged as ranged: use a fixed yard threshold.
                local dist = _GetUnitDistanceYds(unit, nil)
                if not dist then
                    inRange = true
                else
                    local thr = _G.DoiteConditions_RangedOverrideThresholdYds or 30
                    inRange = (dist <= thr)
                end

            else
                -- No override: assume "melee-ish" ability when the addon can't do a proper range check
                local dist = _GetUnitDistanceYds(unit, "melee") or _GetUnitDistanceYds(unit, nil)
                if not dist then
                    -- No distance info at all: don't kill the icon.
                    inRange = true
                else
                    local thr = _GetPlayerMeleeThreshold()
                    inRange = (dist <= thr)
                end
            end
        else
            -- Generic "In range" (e.g. items/auras) – tuneable threshold in xp3 units.
            local dist = _GetUnitDistanceYds(unit, nil)
            if not dist then
                inRange = true
            else
                local generic = _G.DoiteConditions_GenericInRangeThreshold or 1.5
                inRange = (dist <= generic)
            end
        end
    end

    if val == "In range" then
        return inRange

    elseif val == "Not in range" then
        return not inRange

    elseif val == "Melee range" then
        -- already blocked dead targets above; this is only for living units.
        local dist = _GetUnitDistanceYds(unit, "melee") or _GetUnitDistanceYds(unit, nil)
        if not dist then
            return true
        end
        local thr = _GetPlayerMeleeThreshold()
        return (dist <= thr)
    end

    return true
end

-- Global wrapper to reduce upvalues in big condition functions
function DoiteConditions_PassesTargetDistance(condTbl, unit, spellName)
    return _PassesTargetDistance(condTbl, unit, spellName)
end

-- Simple "target alive / dead" helper
local function _PassesTargetStatus(condTbl, unit)
    if not condTbl or not unit then return true end

    local wantAlive = (condTbl.targetAlive == true)
    local wantDead  = (condTbl.targetDead  == true)

    -- If neither flag is set, do not gate.
    if not wantAlive and not wantDead then
        return true
    end

    if not UnitExists or not UnitExists(unit) then
        -- No real target: don't kill the icon purely on this.
        return true
    end

    local isDead = (UnitIsDead and UnitIsDead(unit) == 1) and true or false

    -- UI should keep these mutually exclusive, but be robust anyway.
    if wantAlive and wantDead then
        return true
    elseif wantAlive then
        return (not isDead)
    elseif wantDead then
        return isDead
    end

    return true
end

-- Global wrapper to reduce upvalues in big condition functions
function DoiteConditions_PassesTargetStatus(condTbl, unit)
    return _PassesTargetStatus(condTbl, unit)
end

-- Parse "Multi: 1+2+3" → { "Humanoid","Beast","Dragonkin" }
local function _ParseMultiUnitTypes(val)
    local wanted, seen = {}, {}
    local d
    for d in string.gfind(val, "(%d)") do
        local idx = tonumber(d)
        local name = idx and UNIT_TYPE_INDEX_MAP[idx] or nil
        if name and not seen[name] then
            table.insert(wanted, name)
            seen[name] = true
        end
    end
    return wanted
end

-- Main "targetUnitType" eval
local function _PassesTargetUnitType(condTbl, unit)
    if not condTbl or not unit then return true end

    local val = _NormalizeTargetField(condTbl.targetUnitType)
    if not val then
        return true
    end
    if not UnitExists or not UnitExists(unit) then
        return true
    end

    if val == "Players" then
        if UnitIsPlayer and UnitIsPlayer(unit) then
            return true
        end
        return false
    elseif val == "NPC" then
        if UnitIsPlayer and UnitIsPlayer(unit) then
            return false
        end
        return true
    end

    local creatureType = UnitCreatureType and UnitCreatureType(unit) or nil
    if not creatureType or creatureType == "" then
        -- No type info; don't kill the icon
        return true
    end

    -- Single type "1. Humanoid"
    local _, _, num, label = str_find(val, "^(%d+)%s*%.%s*(.+)$")
    if num and label and label ~= "" then
        return (creatureType == label)
    end

    -- Multi: "Multi: 1+2+3"
    if string.find(val, "Multi:") then
        local wanted = _ParseMultiUnitTypes(val)
        if table.getn(wanted) == 0 then
            return true
        end
        local i
        for i = 1, table.getn(wanted) do
            if creatureType == wanted[i] then
                return true
            end
        end
        return false
    end

    -- Fallback: allow exact string match if someone typed the raw type
    if creatureType == val then
        return true
    end

    -- Default: don't fail on unknown label
    return true
end

-- Global wrapper to reduce upvalues in big condition functions
function DoiteConditions_PassesTargetUnitType(condTbl, unit)
    return _PassesTargetUnitType(condTbl, unit)
end

-- === Weapon filter helpers (Two-Hand / Shield / Dual-Wield) =============

local function _ClassifyEquippedSlot(slot)
    if not slot or not GetInventoryItemLink or type(GetItemInfo) ~= "function" then
        return nil
    end

    local link = GetInventoryItemLink("player", slot)
    if not link then
        return nil
    end

    -- Use the same itemID
    local itemId
    local _, _, idStr = str_find(link, "item:(%d+)")
    if idStr then
        itemId = tonumber(idStr)
    end
    if not itemId then
        return { hasItem = true }
    end

    -- xp3-style GetItemInfo: name, link, quality, level, itemType, itemSubType, stack
    local _, _, _, _, itemType, itemSubType = GetItemInfo(itemId)
    if not itemType or itemType == "" then
        -- ItemInfo not cached yet; treat as "unknown weapon state"
        return { hasItem = true }
    end

    local isShield  = false
    local isTwoHand = false
    local isWeapon  = false

    -- Shields are Armor / Shields
    if itemType == "Armor" and itemSubType == "Shields" then
        isShield = true
    end

    -- All actual weapons share itemType == "Weapon"
    if itemType == "Weapon" then
        isWeapon = true

        if itemSubType then
            -- “Two-Handed Maces”, “Two-Handed Swords”, etc.
            if str_find(itemSubType, "Two%-Handed") then
                isTwoHand = true
            -- 2H melee families that don’t carry the “Two-Handed” prefix
            elseif itemSubType == "Staves"
               or itemSubType == "Polearms"
               or itemSubType == "Fishing Poles" then
                isTwoHand = true
            end
        end
    end

    return {
        hasItem  = true,
        isShield = isShield,
        isTwoHand = isTwoHand,
        isWeapon = isWeapon,
    }
end

local function _GetEquippedWeaponState()
    -- Returns hasTwoHand, hasShieldOffhand, isDualWield; nil,nil,nil if cannot inspect inventory at all.
    if not GetInventoryItemLink or type(GetItemInfo) ~= "function" then
        return nil, nil, nil
    end

    local main = _ClassifyEquippedSlot(INV_SLOT_MAINHAND)
    local off  = _ClassifyEquippedSlot(INV_SLOT_OFFHAND)

    if not main and not off then
        return nil, nil, nil
    end

    local hasTwoHand = false
    local hasShield  = false
    local isDual     = false

    if main and main.isTwoHand then
        hasTwoHand = true
    end

    if off and off.isShield then
        hasShield = true
    end

    -- Dual wield = both hands have real weapons, and offhand is not a shield
    if main and main.isWeapon and off and off.isWeapon and not off.isShield then
        isDual = true
    end

    return hasTwoHand, hasShield, isDual
end

-- Cache weapon filter normalization by raw string to avoid repeated lower/gsub allocations
local _DA_WeaponFilterNormByRaw = {}
local function _NormalizeWeaponFilter(mode)
    if not mode or mode == "" then return nil end

    local cached = _DA_WeaponFilterNormByRaw[mode]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local s = string.lower(mode)
    s = string.gsub(s, "%s+", "")
    s = string.gsub(s, "%-", "")

    local out = nil
    -- Accept "Two-Hand", "Two hand", "2 hand", "2H", etc.
    if s == "twohand" or s == "2hand" or s == "2h" then
        out = "2H"
    -- Accept "Shield", "shield"
    elseif s == "shield" or s == "sh" then
        out = "SH"
    -- Accept "Dual-Wield", "Dual wield", "DW", etc.
    elseif s == "dualwield" or s == "dual" or s == "dw" then
        out = "DW"
    end

    -- Store false sentinel for nil results
    if out then
        _DA_WeaponFilterNormByRaw[mode] = out
        return out
    end
    _DA_WeaponFilterNormByRaw[mode] = false
    return nil
end

local function _PassesWeaponFilter(condTbl)
    if not condTbl then return true end

    local norm = _NormalizeWeaponFilter(condTbl.weaponFilter)
    if not norm then
        -- No filter configured or unknown label -> don't gate
        return true
    end

    -- Only meaningful for Warrior / Paladin / Shaman
    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    if cls ~= "WARRIOR" and cls ~= "PALADIN" and cls ~= "SHAMAN" then
        return true
    end

    local hasTwoHand, hasShield, isDual = _GetEquippedWeaponState()
    if hasTwoHand == nil and hasShield == nil and isDual == nil then
        -- Inventory APIs unavailable; don't kill icons
        return true
    end

    if norm == "2H" then
        return hasTwoHand
    elseif norm == "SH" then
        return hasShield
    elseif norm == "DW" then
        return isDual
    end

    return true
end

-- Global wrapper to reduce upvalues in big condition functions
function DoiteConditions_PassesWeaponFilter(condTbl)
    return _PassesWeaponFilter(condTbl)
end

-- Time remaining formatter for overlay text:
--  >= 3600s -> "#h"
--  >=   60s -> "#m"
--  <    10s -> "#.#s" (tenths)
local function _FmtRem(remSec)
    if not remSec or remSec <= 0 then return nil end
    if remSec >= 3600 then
        return math.floor(remSec / 3600) .. "+h"
    elseif remSec >= 60 then
        return math.floor(remSec / 60) .. "+m"
    elseif remSec < 1.6 then
	      -- only show tenths when under 1.6s left
        -- Stabilize tenths by truncating, not rounding up (matches old behavior)
        local t10 = math.floor(remSec * 10)
        local whole = math.floor(t10 / 10)
        local dec = t10 - (whole * 10)
        return whole .. "." .. dec
    else
        return math.ceil(remSec)
    end
end


-- === Form / Stance evaluation (no fallbacks) ===
local function _ActiveFormMap()
    local map = DoiteConditions._activeFormMap
    if not map then
        map = {}
        DoiteConditions._activeFormMap = map
    else
        for k in pairs(map) do
            map[k] = nil
        end
    end

    for i = 1, 10 do
        local _, name, active = GetShapeshiftFormInfo(i)
        if not name then break end
        map[name] = (active and active == 1) and true or false
    end
    return map
end

local function _AnyActive(map, names)
    for _, n in ipairs(names) do
        if map[n] then return true end
    end
    return false
end

local function _DruidNoForm(map)
    -- No Bear/Cat/Aquatic/Travel/Swift Travel/Moonkin/Tree is active
    local any = _AnyActive(map, {
        "Dire Bear Form","Bear Form","Cat Form","Aquatic Form",
        "Travel Form","Swift Travel Form","Moonkin Form","Tree of Life Form"
    })
    return not any
end

local function _DruidStealth(auraSnap)
    -- Strictly via aura (Prowl) per spec
    local s = auraSnap and auraSnap.player
    local buffs = s and s.buffs
    return buffs and buffs["Prowl"] == true
end

-- Normalize editor labels so logic is robust to wording differences
local function _NormalizeFormLabel(s)
    if not s or s == "" then return "All" end
    s = str_gsub(s, "^%s+", "")
    s = str_gsub(s, "%s+$", "")
    -- unify "All ..." variants (editor may say "All Auras", "All stances", etc.)
    if s == "All" or s == "All forms" or s == "All stances" or s == "All Auras" then
        return "All"
    end
    -- unify the druid "no form(s)" label
    if s == "0. No form" or s == "0. No forms" then
        return "0. No form"
    end
    return s
end

-- Paladin: no aura selected in the shapeshift bar
local function _PaladinNoAura(map)
    return not _AnyActive(map, {
        "Devotion Aura","Retribution Aura","Concentration Aura",
        "Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura","Sanctity Aura"
    })
end

local function _PassesFormRequirement(formStr, auraSnap)
    formStr = _NormalizeFormLabel(formStr)
    if not formStr or formStr == "All" then return true end

    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    local map = _ActiveFormMap()

    -- WARRIOR
    if cls == "WARRIOR" then
        if formStr == "1. Battle"    then return map["Battle Stance"]    == true end
        if formStr == "2. Defensive" then return map["Defensive Stance"] == true end
        if formStr == "3. Berserker" then return map["Berserker Stance"] == true end
		if formStr == "Multi: 1+2"   then return (map["Battle Stance"] == true) or (map["Defensive Stance"] == true) end
        if formStr == "Multi: 1+3"   then return (map["Battle Stance"] == true) or (map["Berserker Stance"] == true) end
        if formStr == "Multi: 2+3"   then return (map["Defensive Stance"] == true) or (map["Berserker Stance"] == true) end
        return true
    end

    -- ROGUE
    if cls == "ROGUE" then
        if formStr == "1. Stealth"    then return map["Stealth"] == true end
        if formStr == "0. No Stealth" then return map["Stealth"] ~= true end
        return true
    end

    -- PRIEST
    if cls == "PRIEST" then
        if formStr == "1. Shadowform" then return map["Shadowform"] == true end
        if formStr == "0. No form"    then return map["Shadowform"] ~= true end
        return true
    end

    -- DRUID  (accepts both "0. No form" and "0. No forms")
    if cls == "DRUID" then
        if formStr == "0. No form"    then return _DruidNoForm(map) end
        if formStr == "1. Bear"       then return _AnyActive(map, {"Dire Bear Form","Bear Form"}) end
        if formStr == "2. Aquatic"    then return map["Aquatic Form"] == true end
        if formStr == "3. Cat"        then return map["Cat Form"] == true end
        if formStr == "4. Travel"     then return _AnyActive(map, {"Travel Form","Swift Travel Form"}) end
        if formStr == "5. Moonkin"    then return map["Moonkin Form"] == true end
        if formStr == "6. Tree"       then return map["Tree of Life Form"] == true end
        -- stealth variants use aura state
        if formStr == "7. Stealth"    then return _DruidStealth(auraSnap) end
        if formStr == "8. No Stealth" then return not _DruidStealth(auraSnap) end
        -- multis
        if formStr == "Multi: 0+5"     then return _DruidNoForm(map) or (map["Moonkin Form"] == true) end
        if formStr == "Multi: 0+6"     then return _DruidNoForm(map) or (map["Tree of Life Form"] == true) end
        if formStr == "Multi: 1+3"     then return _AnyActive(map, {"Dire Bear Form","Bear Form","Cat Form"}) end
        if formStr == "Multi: 3+7"     then return (map["Cat Form"] == true) or _DruidStealth(auraSnap) end
        if formStr == "Multi: 3+8"     then return (map["Cat Form"] == true) and (not _DruidStealth(auraSnap)) end
        if formStr == "Multi: 5+6"     then return _AnyActive(map, {"Moonkin Form","Tree of Life Form"}) end
        if formStr == "Multi: 0+5+6"   then return _DruidNoForm(map) or _AnyActive(map, {"Moonkin Form","Tree of Life Form"}) end
        if formStr == "Multi: 1+3+8"   then return _AnyActive(map, {"Dire Bear Form","Bear Form","Cat Form"}) and (not _DruidStealth(auraSnap)) end
        return true
    end

    -- PALADIN (treat auras as shapeshift forms via GetShapeshiftFormInfo)
    if cls == "PALADIN" then
        -- Editor options: "All Auras", "No Aura", "1. Devotion" .. "7. Sanctity" + multis
        if formStr == "No Aura"                 then return _PaladinNoAura(map) end
        if formStr == "1. Devotion"             then return map["Devotion Aura"]          == true end
        if formStr == "2. Retribution"          then return map["Retribution Aura"]       == true end
        if formStr == "3. Concentration"        then return map["Concentration Aura"]     == true end
        if formStr == "4. Shadow Resistance"    then return map["Shadow Resistance Aura"] == true end
        if formStr == "5. Frost Resistance"     then return map["Frost Resistance Aura"]  == true end
        if formStr == "6. Fire Resistance"      then return map["Fire Resistance Aura"]   == true end
        if formStr == "7. Sanctity"             then return map["Sanctity Aura"]          == true end

        -- multis (logical OR among the listed auras)
        if formStr == "Multi: 1+2"               then return _AnyActive(map, {"Devotion Aura","Retribution Aura"}) end
        if formStr == "Multi: 1+3"               then return _AnyActive(map, {"Devotion Aura","Concentration Aura"}) end
        if formStr == "Multi: 1+4+5+6"           then return _AnyActive(map, {"Devotion Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 1+7"               then return _AnyActive(map, {"Devotion Aura","Sanctity Aura"}) end
        if formStr == "Multi: 1+2+3"             then return _AnyActive(map, {"Devotion Aura","Retribution Aura","Concentration Aura"}) end
        if formStr == "Multi: 1+2+3+4+5+6"       then return _AnyActive(map, {"Devotion Aura","Retribution Aura","Concentration Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 2+3"               then return _AnyActive(map, {"Retribution Aura","Concentration Aura"}) end
        if formStr == "Multi: 2+4+5+6"           then return _AnyActive(map, {"Retribution Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 2+7"               then return _AnyActive(map, {"Retribution Aura","Sanctity Aura"}) end
        if formStr == "Multi: 2+3+4+5+6"         then return _AnyActive(map, {"Retribution Aura","Concentration Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 3+4+5+6"           then return _AnyActive(map, {"Concentration Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 3+7"               then return _AnyActive(map, {"Concentration Aura","Sanctity Aura"}) end
        if formStr == "Multi: 4+5+6+7"           then return _AnyActive(map, {"Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura","Sanctity Aura"}) end

        return true
    end

    return true
end

-- Global wrapper to reduce upvalues in big condition functions
function DoiteConditions_PassesFormRequirement(formStr, auraSnap)
    return _PassesFormRequirement(formStr, auraSnap)
end

local function _EnsureAbilityTexture(frame, data)
    if not frame or not frame.icon or not data then return end
    if frame.icon:GetTexture() then return end

    local spellName = data.displayName or data.name
    if not spellName then return end

    local idx = _GetSpellIndexByName(spellName)
    if idx then
        local tex = GetSpellTexture(idx, BOOKTYPE_SPELL)
        if tex then
            frame.icon:SetTexture(tex)
            IconCache[spellName] = tex -- persist
        end
    end
end


-- Ensure a Buff/Debuff icon has a texture (player/target, then fallback via spellbook)
local function _EnsureAuraTexture(frame, data)
    -- Hard guards: must have a real frame, real icon, real data
	if not frame then return end
	local icon = frame.icon
	if not icon or not icon.GetTexture or not icon.SetTexture then
		return
	end
    if not data or type(data) ~= "table" then return end

    local c    = data.conditions and data.conditions.aura
    local name = data.displayName or data.name
    if not c or not name or name == "" then return end
	
	-- 0) If this entry already has a stored iconTexture, use it immediately.
	if data.iconTexture and data.iconTexture ~= "" then
		local cur = icon:GetTexture()
		if cur ~= data.iconTexture then
			icon:SetTexture(data.iconTexture)
		end

		IconCache[name] = data.iconTexture
		if DoiteAurasDB and DoiteAurasDB.cache then
			DoiteAurasDB.cache[name] = data.iconTexture
		end
		return
	end

    -- 0a) If config already has a spellid, trust SpellInfo(spellid) first.
    if data.spellid and SpellInfo then
        local sid = tonumber(data.spellid)
        if sid and sid > 0 then
            local _, _, tex = SpellInfo(sid)
            if tex and tex ~= "" then
                local cur = icon:GetTexture()
                if cur ~= tex then
                    icon:SetTexture(tex)
                end

                IconCache[name] = tex
                if DoiteAurasDB and DoiteAurasDB.cache then
                    DoiteAurasDB.cache[name] = tex
                end
                if DoiteAurasDB and DoiteAurasDB.spells and data.key and DoiteAurasDB.spells[data.key] then
                    DoiteAurasDB.spells[data.key].iconTexture = tex
                end
                return
            end
        end
    end

    -- 0b) If Nampower is present and this spell exists in player spellbook, resolve name -> spellId -> texture even if no one has the aura up.
    if GetSpellIdForName and SpellInfo then
        local sid = GetSpellIdForName(name)
        if sid and sid > 0 then
            local _, _, tex = SpellInfo(sid)
            if tex and tex ~= "" then
                local cur = icon:GetTexture()
                if cur ~= tex then
                    icon:SetTexture(tex)
                end

                IconCache[name] = tex
                if DoiteAurasDB and DoiteAurasDB.cache then
                    DoiteAurasDB.cache[name] = tex
                end
                if DoiteAurasDB and DoiteAurasDB.spells and data.key and DoiteAurasDB.spells[data.key] then
                    local s = DoiteAurasDB.spells[data.key]
                    s.iconTexture = tex
                    if not s.spellid then
                        s.spellid = tostring(sid)
                    end
                end
                return
            end
        end
    end

    -- 1) Existing cache / placeholder logic (unchanged)
    local curTex  = icon:GetTexture()
    local cached  = IconCache and IconCache[name] or nil
    local isPlaceholder = (curTex == nil)
                        or (type(curTex) == "string" and str_find(curTex, "INV_Misc_QuestionMark"))

    -- If already have a cached real texture for this aura name, just use it.
    if cached and (not curTex or curTex ~= cached) then
        icon:SetTexture(cached)
        return
    end

    -- If the icon already has a non-placeholder texture and nothing cached,
    if (not isPlaceholder) and curTex then
        return
    end

	-- 2) Decide which unit(s) to scan for live aura textures. Use the SAME flags the rest of this file uses: targetSelf/targetHelp/targetHarm.
	local checkSelf, checkTarget = false, false

	local flagSelf = (c.targetSelf == true)
	local flagHelp = (c.targetHelp == true)
	local flagHarm = (c.targetHarm == true)

	-- If none selected, default to self (matches CheckAuraConditions / overlay logic)
	if (not flagSelf) and (not flagHelp) and (not flagHarm) then
		flagSelf = true
	end

	if flagSelf then
		checkSelf = true
	end
	if flagHelp or flagHarm then
		checkTarget = true
	end

	-- Back-compat: if legacy c.target exists ("self"/"target"/"both"), let it override.
	if c.target and type(c.target) == "string" then
		if c.target == "self" then
			checkSelf = true
			checkTarget = false
		elseif c.target == "target" then
			checkSelf = false
			checkTarget = true
		elseif c.target == "both" then
			checkSelf = true
			checkTarget = true
		end
	end

    local function tryUnit(unit)
        -- 1) BUFFS: confirm NAME via SpellInfo/tooltip, then take TEXTURE from UnitBuff
        local i = 1
        while i <= 40 do
            local n = _GetAuraName(unit, i, false)
            if n == nil then
                break
            end
            if n ~= "" and n == name then
                local tex = UnitBuff(unit, i)
                if tex and (isPlaceholder or curTex ~= tex) then
                    icon:SetTexture(tex)
                    IconCache[name] = tex
                    if DoiteAurasDB and DoiteAurasDB.cache then
                        DoiteAurasDB.cache[name] = tex
                    end
                end
                return true
            end
            i = i + 1
        end

        -- 2) DEBUFFS: confirm NAME via SpellInfo/tooltip, then take TEXTURE from UnitDebuff
        i = 1
        while i <= 40 do
            local n = _GetAuraName(unit, i, true)
            if n == nil then
                break
            end
            if n ~= "" and n == name then
                local tex = UnitDebuff(unit, i)
                if tex and (isPlaceholder or curTex ~= tex) then
                    icon:SetTexture(tex)
                    IconCache[name] = tex
                    if DoiteAurasDB and DoiteAurasDB.cache then
                        DoiteAurasDB.cache[name] = tex
                    end
                end
                return true
            end
            i = i + 1
        end

        return false
    end

    local got = false
    if checkSelf then
        got = tryUnit("player")
    end
    if (not got) and checkTarget and UnitExists("target") then
        got = tryUnit("target")
    end

    -- Fallback to spellbook texture
    if not got then
        local i = 1
        while i <= 200 do
            local s = GetSpellName(i, BOOKTYPE_SPELL)
            if not s then break end
            if s == name then
                local tex = GetSpellTexture(i, BOOKTYPE_SPELL)
                if tex and (isPlaceholder or curTex ~= tex) then
                    icon:SetTexture(tex)
                    IconCache[name] = tex
                    if DoiteAurasDB and DoiteAurasDB.cache then
                        DoiteAurasDB.cache[name] = tex
                    end
                end
                break
            end
            i = i + 1
        end
        -- Nudge the next regular update, but don't re-enter recursively
        dirty_aura = true
        return
    end
end

-- Ensure a synthetic Item slot icon (equipped trinkets / weapons) has a real texture
local function _EnsureItemTexture(frame, data)
    if not frame or not frame.icon or not data then return end
    if not data.conditions or not data.conditions.item then return end

    local c           = data.conditions.item
    local invSlotName = c.inventorySlot
    if not invSlotName or invSlotName == "" then return end

    local nameKey = data.displayName or data.name
    if not nameKey or nameKey == "" then return end

    local slot = nil

    if invSlotName == "TRINKET1" or invSlotName == "TRINKET2"
       or invSlotName == "MAINHAND" or invSlotName == "OFFHAND"
       or invSlotName == "RANGED" then

        slot = _SlotIndexForName(invSlotName)

    elseif invSlotName == "TRINKET_FIRST" then
        -- Prefer the remembered winner for this key if exist
        if data.key and _TrinketFirstMemory[data.key]
           and _TrinketFirstMemory[data.key].slot then
            slot = _TrinketFirstMemory[data.key].slot
        else
            -- Fallback: whichever trinket slot currently has an item (1, then 2)
            local has1 = GetInventoryItemLink("player", INV_SLOT_TRINKET1) ~= nil
            local has2 = GetInventoryItemLink("player", INV_SLOT_TRINKET2) ~= nil
            if has1 then
                slot = INV_SLOT_TRINKET1
            elseif has2 then
                slot = INV_SLOT_TRINKET2
            end
        end

    elseif invSlotName == "TRINKET_BOTH" then
        -- Cosmetic choice: prefer trinket #1's icon if present, else trinket #2
        local has1 = GetInventoryItemLink("player", INV_SLOT_TRINKET1) ~= nil
        local has2 = GetInventoryItemLink("player", INV_SLOT_TRINKET2) ~= nil
        if has1 then
            slot = INV_SLOT_TRINKET1
        elseif has2 then
            slot = INV_SLOT_TRINKET2
        end
    end

    if not slot then return end

    local tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slot)
    if not tex then return end

    local curTex = frame.icon:GetTexture()
    if curTex ~= tex then
        frame.icon:SetTexture(tex)
    end

    IconCache[nameKey] = tex
    DoiteAurasDB.cache[nameKey] = tex
    if DoiteAurasDB.spells and data.key and DoiteAurasDB.spells[data.key] then
        DoiteAurasDB.spells[data.key].iconTexture = tex
    end
end

-- === Time-logic helpers (for heartbeat pruning) =================

-- Does an Ability icon use any time-based features?
local function _IconHasTimeLogic_Ability(data)
    if not data or not data.conditions or not data.conditions.ability then
        return false
    end
    local c = data.conditions.ability

    -- Existing reasons
    if c.textTimeRemaining == true then
        return true
    end
    if c.remainingEnabled == true then
        return true
    end

    -- proc-window spells should tick (ONLY when mode == "usable")
    if c.mode == "usable" then
        local spellName = _GetCanonicalSpellNameFromData(data)
        if spellName and _ProcWindowDuration(spellName) then
            return true
        end
    end

    return false
end


-- Does an Item icon use any time-based features?
local function _IconHasTimeLogic_Item(data)
    if not data or not data.conditions or not data.conditions.item then
        return false
    end
    local c = data.conditions.item

    if c.mode == "oncd" or c.mode == "notcd" then
        return true
    end

    if c.textTimeRemaining == true then
        return true
    end
    if c.remainingEnabled == true then
        return true
    end
    return false
end

-- Does a Buff/Debuff icon use any time-based features?
local function _IconHasTimeLogic_Aura(data)
    if not data or not data.conditions or not data.conditions.aura then
        return false
    end
    local c = data.conditions.aura
    if c.textTimeRemaining == true then
        return true
    end
    if c.remainingEnabled == true then
        return true
    end
    return false
end

-- Global flag: have ANY ability/item icons that need the 0.5s heartbeat?
local _hasAnyAbilityTimeLogic = false
-- Global flag: have ANY aura icons that need the 0.5s heartbeat?
local _hasAnyAuraTimeLogic    = false
-- Global flag: do we have ANY reason to track target auras at all?
local _hasAnyTargetAuraUsage  = true

-- ------------------------------------------------------------
-- Coalesced aura scan + timer rebuild (reduces UNIT_AURA bursts)
-- Stored as DoiteConditions methods to avoid adding more file-scope locals.
-- ------------------------------------------------------------

function DoiteConditions:_ClearTargetAuraSnapshot()
    local s = auraSnapshot and auraSnapshot.target
    if s then
        local b, d = s.buffs, s.debuffs
        if b then for k in pairs(b) do b[k] = nil end end
        if d then for k in pairs(d) do d[k] = nil end end
    end
end

function DoiteConditions:_RebuildPlayerAuraTimers()
    if not _hasAnyAuraTimeLogic then return end

    local timers = PlayerAuraTimers
    if not timers then return end

    for k in pairs(timers.buffs)   do timers.buffs[k]   = nil end
    for k in pairs(timers.debuffs) do timers.debuffs[k] = nil end

    if GetPlayerBuff and GetPlayerBuffTimeLeft
       and DoiteConditionsTooltip
       and DoiteConditionsTooltip.SetPlayerBuff then

        -- HELPFUL (buffs)
        for i = 0, 31 do
            local idx = GetPlayerBuff(i, "HELPFUL")
            if idx and idx >= 0 then
                DoiteConditionsTooltip:ClearLines()
                DoiteConditionsTooltip:SetPlayerBuff(idx)
                local tn = DoiteConditionsTooltipTextLeft1
                           and DoiteConditionsTooltipTextLeft1:GetText()
                if tn and tn ~= "" then
                    local tl = GetPlayerBuffTimeLeft(idx)
                    if tl and tl > 0 then
                        timers.buffs[tn] = GetTime() + tl
                    end
                end
            end
        end

        -- HARMFUL (debuffs)
        for i = 0, 31 do
            local idx = GetPlayerBuff(i, "HARMFUL")
            if idx and idx >= 0 then
                DoiteConditionsTooltip:ClearLines()
                DoiteConditionsTooltip:SetPlayerBuff(idx)
                local tn = DoiteConditionsTooltipTextLeft1
                           and DoiteConditionsTooltipTextLeft1:GetText()
                if tn and tn ~= "" then
                    local tl = GetPlayerBuffTimeLeft(idx)
                    if tl and tl > 0 then
                        timers.debuffs[tn] = GetTime() + tl
                    end
                end
            end
        end
    end
end

function DoiteConditions:ProcessPendingAuraScans()
    -- Player: scan once, then rebuild timers once (if requested)
    if self._pendingAuraScanPlayer then
        self._pendingAuraScanPlayer = false
        _ScanUnitAuras("player")

        if self._pendingRebuildPlayerTimers then
            self._pendingRebuildPlayerTimers = false
            self:_RebuildPlayerAuraTimers()
        end
    elseif self._pendingRebuildPlayerTimers then
        -- Defensive: keep timers consistent even if flags get set oddly.
        self._pendingRebuildPlayerTimers = false
        self:_RebuildPlayerAuraTimers()
    end

    -- Target: scan if (and only if) target aura tracking is in use; else keep snapshot empty.
    if self._pendingAuraScanTarget then
        self._pendingAuraScanTarget = false

        if _hasAnyTargetAuraUsage and UnitExists and UnitExists("target") then
            _ScanUnitAuras("target")
        else
            self:_ClearTargetAuraSnapshot()
        end
    end
end

-- Target facts cache
local _DA_TargetFacts = { exists = false, isSelf = false, isFriend = false, canAttack = false }

local function _DA_GetTargetFacts()
    local tf = _DA_TargetFacts
    local exists = UnitExists("target")
    tf.exists = exists and true or false

    if exists then
        tf.isSelf    = UnitIsUnit("player", "target") and true or false
        tf.isFriend  = UnitIsFriend("player", "target") and true or false
        tf.canAttack = UnitCanAttack("player", "target") and true or false
    else
        tf.isSelf, tf.isFriend, tf.canAttack = false, false, false
    end

    return tf
end

-- Cached key lists (rebuilt via *_Rebuild*HeartbeatFlag / DoiteConditions_RequestEvaluate).
-- Purpose: avoid scanning every icon table on the 0.5s heartbeat and avoid per-call closure allocations.
-- NOTE: These are runtime-only caches (not saved vars).
local _timeKeysAbilityItem_live = {}
local _timeKeysAbilityItem_edit = {}
local _timeKeysAura_live        = {}
local _timeKeysAura_edit        = {}

local function _WipeArray(t)
    local n = table.getn(t)
    while n > 0 do
        t[n] = nil
        n = n - 1
    end
end

local function _RebuildAbilityTimeHeartbeatFlag()
    _hasAnyAbilityTimeLogic = false

    -- Rebuild runtime-only key lists so 0.5s heartbeat passes don't scan every icon.
    _WipeArray(_timeKeysAbilityItem_live)
    _WipeArray(_timeKeysAbilityItem_edit)

    -- 1) Runtime icons
    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if type(data) == "table" and data.type then
                if data.type == "Ability" then
                    if _IconHasTimeLogic_Ability(data) then
                        _hasAnyAbilityTimeLogic = true
                        table.insert(_timeKeysAbilityItem_live, key)
                    end
                elseif data.type == "Item" then
                    if _IconHasTimeLogic_Item(data) then
                        _hasAnyAbilityTimeLogic = true
                        table.insert(_timeKeysAbilityItem_live, key)
                    end
                end
            end
        end
    end

    -- 2) Editor icons (may overlap live keys; evaluation loops will skip live keys when needed)
    if DoiteDB and DoiteDB.icons then
        local key, data
        for key, data in pairs(DoiteDB.icons) do
            if type(data) == "table" and data.type then
                if data.type == "Ability" then
                    if _IconHasTimeLogic_Ability(data) then
                        _hasAnyAbilityTimeLogic = true
                        table.insert(_timeKeysAbilityItem_edit, key)
                    end
                elseif data.type == "Item" then
                    if _IconHasTimeLogic_Item(data) then
                        _hasAnyAbilityTimeLogic = true
                        table.insert(_timeKeysAbilityItem_edit, key)
                    end
                end
            end
        end
    end
end

local function _RebuildAuraTimeHeartbeatFlag()
    _hasAnyAuraTimeLogic = false

    -- Rebuild runtime-only key lists so 0.5s text/remaining updates don't scan every icon.
    _WipeArray(_timeKeysAura_live)
    _WipeArray(_timeKeysAura_edit)

    -- 1) Runtime icons
    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if type(data) == "table" and (data.type == "Buff" or data.type == "Debuff") then
                if _IconHasTimeLogic_Aura(data) then
                    _hasAnyAuraTimeLogic = true
                    table.insert(_timeKeysAura_live, key)
                end
            end
        end
    end

    -- 2) Editor icons (may overlap live keys; UpdateTimeText already skips live keys for editor set)
    if DoiteDB and DoiteDB.icons then
        local key, data
        for key, data in pairs(DoiteDB.icons) do
            if type(data) == "table" and (data.type == "Buff" or data.type == "Debuff") then
                if _IconHasTimeLogic_Aura(data) then
                    _hasAnyAuraTimeLogic = true
                    table.insert(_timeKeysAura_edit, key)
                end
            end
        end
    end
end

local function _RebuildAuraUsageFlags()
    _hasAnyTargetAuraUsage = false

    -- 1) Live icons
    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if type(data) == "table" then
                -- Any explicit Buff/Debuff icon that can ever point at target?
                if data.type == "Buff" or data.type == "Debuff" then
                    local c = data.conditions and data.conditions.aura
                    if c and (c.targetHarm or c.targetHelp) then
                        _hasAnyTargetAuraUsage = true
                        return
                    end
                end

                -- Any ability auraConditions that can check target?
                local ca = data.conditions and data.conditions.ability
                if ca and ca.auraConditions and (ca.targetHarm or ca.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end

                -- Any item auraConditions that can check target?
                local ci = data.conditions and data.conditions.item
                if ci and ci.auraConditions and (ci.targetHarm or ci.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end
            end
        end
    end

    -- 2) Editor-only icons
    if DoiteDB and DoiteDB.icons then
        local key, data
        for key, data in pairs(DoiteDB.icons) do
            if type(data) == "table" then
                if data.type == "Buff" or data.type == "Debuff" then
                    local c = data.conditions and data.conditions.aura
                    if c and (c.targetHarm or c.targetHelp) then
                        _hasAnyTargetAuraUsage = true
                        return
                    end
                end

                local ca = data.conditions and data.conditions.ability
                if ca and ca.auraConditions and (ca.targetHarm or ca.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end

                local ci = data.conditions and data.conditions.item
                if ci and ci.auraConditions and (ci.targetHarm or ci.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end
            end
        end
    end
end

-- Global flags: do we have ANY icons that use targetDistance / targetUnitType?
local _hasAnyTargetMods_Ability = false
local _hasAnyTargetMods_Aura    = false

local function _IconHasTargetMods_AbilityOrItem(data)
    if not data or not data.conditions then return false end
    local c = data.conditions.ability or data.conditions.item
    if not c then return false end

    local td = _NormalizeTargetField(c.targetDistance)
    local tu = _NormalizeTargetField(c.targetUnitType)

    return (td ~= nil) or (tu ~= nil)
end

local function _IconHasTargetMods_Aura(data)
    if not data or not data.conditions or not data.conditions.aura then
        return false
    end
    local c = data.conditions.aura

    local td = _NormalizeTargetField(c.targetDistance)
    local tu = _NormalizeTargetField(c.targetUnitType)

    return (td ~= nil) or (tu ~= nil)
end

local function _RebuildTargetModsFlags()
    _hasAnyTargetMods_Ability = false
    _hasAnyTargetMods_Aura    = false

    -- 1) Live icons
    if DoiteAurasDB and DoiteAurasDB.spells then
        for key, data in pairs(DoiteAurasDB.spells) do
            if type(data) == "table" and data.type then
                if (data.type == "Ability" or data.type == "Item")
                   and _IconHasTargetMods_AbilityOrItem(data) then
                    _hasAnyTargetMods_Ability = true
                end
                if (data.type == "Buff" or data.type == "Debuff")
                   and _IconHasTargetMods_Aura(data) then
                    _hasAnyTargetMods_Aura = true
                end
                if _hasAnyTargetMods_Ability and _hasAnyTargetMods_Aura then
                    return
                end
            end
        end
    end

    -- 2) Editor-only icons
    if DoiteDB and DoiteDB.icons then
        for key, data in pairs(DoiteDB.icons) do
            if type(data) == "table" and data.type then
                if (data.type == "Ability" or data.type == "Item")
                   and _IconHasTargetMods_AbilityOrItem(data) then
                    _hasAnyTargetMods_Ability = true
                end
                if (data.type == "Buff" or data.type == "Debuff")
                   and _IconHasTargetMods_Aura(data) then
                    _hasAnyTargetMods_Aura = true
                end
                if _hasAnyTargetMods_Ability and _hasAnyTargetMods_Aura then
                    return
                end
            end
        end
    end
end

---------------------------------------------------------------
-- Ability condition evaluation
---------------------------------------------------------------
local _DA_SWIFTMEND_NEEDS = { "Rejuvenation", "Regrowth" }

local function CheckAbilityConditions(data)
    if not data or not data.conditions or not data.conditions.ability then
        return true -- if no conditions, always show
    end
    local c = data.conditions.ability
	    -- Precompute target flags (used by Swiftmend guard and generic target gating)
    local allowHelp = (c.targetHelp == true)
    local allowHarm = (c.targetHarm == true)
    local allowSelf = (c.targetSelf == true)

	    -- While editing this key, force conditions to pass (always show). Keeps group reflow and any "show"-based logic consistent.
    if _IsKeyUnderEdit(data.key) then
        local glow = (c.glow and true) or false
        local grey = (c.greyscale and true) or false
        return true, glow, grey
    end

    local show = true

    -- === 1. Cooldown / usability ===
    local spellName  = _GetCanonicalSpellNameFromData(data)
    local spellIndex = _GetSpellIndexByName(spellName)
    local bookType = BOOKTYPE_SPELL
    local foundInBook = (spellIndex ~= nil)

    if not foundInBook then
        return false
    end

    if c.mode == "usable" and spellIndex then
        local _, cls = UnitClass("player"); cls = cls and string.upper(cls) or ""
        local onCooldown = _IsSpellOnCooldown(spellIndex, bookType)

        -- === WARRIOR override for Overpower/Revenge ===
        if cls == "WARRIOR" and (spellName == "Overpower" or spellName == "Revenge") then
            if onCooldown then
                show = false
            else
                local rage = UnitMana("player") or 0
                if rage < 5 then
                    show = false
                else
                    if spellName == "Overpower" then
                        -- Require current target to be the dodger, window <= 5s
                        show = _Warrior_Overpower_OK()
                    else -- "Revenge"
                        -- Any target OK, window <= 5s
                        show = _Warrior_Revenge_OK()
                    end
                end
            end
		else
			-- ===== Normal usable logic (all other classes/spells) =====
			local usable, noMana = _SafeSpellUsable(spellName, spellIndex, bookType)

			if (usable ~= 1) or (noMana == 1) or onCooldown then
				show = false
			else
				-- === Usable special cases (guards) ===
				if cls == "DRUID" and spellName == "Swiftmend" then
					local needs = _DA_SWIFTMEND_NEEDS
					local ok = false

					if allowHelp and not allowSelf then
						if UnitExists("target")
						   and UnitIsFriend("player","target")
						   and (not UnitIsUnit("player","target")) then
							ok = _UnitHasAnyBuffName("target", needs)
						else
							ok = false
						end

					elseif allowSelf and not (allowHelp or allowHarm) then
						ok = _UnitHasAnyBuffName("player", needs)

					else
						if UnitExists("target") then
							if UnitIsUnit("player","target") then
								ok = _UnitHasAnyBuffName("player", needs)
							elseif UnitIsFriend("player","target") then
								ok = _UnitHasAnyBuffName("target", needs)
							else
								ok = false
							end
						else
							ok = false
						end
					end

					if not ok then
						show = false
					end
				end
			end
		end


    elseif c.mode == "notcd" and spellIndex then
        if _IsSpellOnCooldown(spellIndex, bookType) then show = false end

    elseif c.mode == "oncd" and spellIndex then
        if not _IsSpellOnCooldown(spellIndex, bookType) then show = false end
    end

    -- === Combat state ===
    local inCombatFlag  = (c.inCombat == true)
    local outCombatFlag = (c.outCombat == true)

    -- If both are checked, always allowed
    if not (inCombatFlag and outCombatFlag) then
        if inCombatFlag and not InCombat() then show = false end
        if outCombatFlag and InCombat() then show = false end
    end

	-- Cache target facts once per evaluation
	local tf = _DA_GetTargetFacts()

	-- If nothing selected, do NOT gate on target at all.
	local ok = true
	if allowHelp or allowHarm or allowSelf then
		ok = false

		-- Self: must be explicitly targeting player
		if allowSelf and tf.exists and tf.isSelf then
			ok = true
		end

		-- Help: friendly target (EXCLUDING self), requires a target
		if (not ok) and allowHelp and tf.exists and tf.isFriend and (not tf.isSelf) then
			ok = true
		end

		-- Harm: hostile/attackable and not friendly, requires a target
		if (not ok) and allowHarm and tf.exists and tf.canAttack and (not tf.isFriend) then
			ok = true
		end
	end

    if not ok then
        show = false
    end

    -- === Target status / Distance / UnitType (ability) ===================
	if show and (c.targetDistance or c.targetUnitType or c.targetAlive or c.targetDead) then
		local unitForTarget = nil
		if tf.exists then
			unitForTarget = "target"
		end

		if unitForTarget then
            -- 1) Alive / dead requirement (if configured)
            if not DoiteConditions_PassesTargetStatus(c, unitForTarget) then
                show = false
            -- 2) Range filter (if configured)
            elseif not DoiteConditions_PassesTargetDistance(c, unitForTarget, spellName) then
                show = false
            -- 3) Unit-type filter (if configured)
            elseif not DoiteConditions_PassesTargetUnitType(c, unitForTarget) then
                show = false
            end
        end
    end

    -- === Form / Stance requirement (if set)
    if show and c.form and c.form ~= "All" then
        if not DoiteConditions_PassesFormRequirement(c.form, auraSnapshot) then
            show = false
        end
    end

    -- === Weapon filter (Two-Hand / Shield / Dual-Wield) ===
    if show and c.weaponFilter and c.weaponFilter ~= "" then
        if not DoiteConditions_PassesWeaponFilter(c) then
            show = false
        end
    end

	    -- === HP threshold (% of max) — player or target
    if show and c.hpComp and c.hpVal and c.hpMode and c.hpMode ~= "" then
        local hpTarget = nil
        if c.hpMode == "my" then
            hpTarget = "player"
			elseif c.hpMode == "target" then
				-- Gate by target kind if user also set targetHelp/targetHarm/targetSelf
				if tf.exists then
					-- Use already-computed allowHelp/allowHarm/allowSelf from above
					if (allowHelp or allowHarm or allowSelf) then
						local okHP = true
						if allowSelf then
							okHP = tf.isSelf
						elseif allowHelp then
							okHP = tf.isFriend and (not tf.isSelf)
						elseif allowHarm then
							okHP = tf.canAttack and (not tf.isFriend)
						end

						if not okHP then
							hpTarget = nil
						else
							hpTarget = "target"
						end
					else
						hpTarget = "target"
					end
				end
			end

        if hpTarget then
            local pct = _HPPercent(hpTarget)
            local thr = tonumber(c.hpVal)
            if thr and not _ValuePasses(pct, c.hpComp, thr) then
                show = false
            end
        end
    end

	    -- === Combo Points (Rogue/Druid only) ===
    if show and c.cpEnabled == true and _PlayerUsesComboPoints() then
        local cp = _GetComboPointsSafe()
        local thr = tonumber(c.cpVal)
        if thr and c.cpComp and c.cpComp ~= "" then
            if not _ValuePasses(cp, c.cpComp, thr) then
                show = false
            end
        end
    end


    -- === Power threshold (% of max) ===
	if show and c.powerEnabled
	   and c.powerComp ~= nil and c.powerComp ~= ""
	   and c.powerVal  ~= nil and c.powerVal  ~= "" then

        local valPct    = GetPowerPercent()
        local targetPct = tonumber(c.powerVal) or 0
        local comp      = c.powerComp

        local pass = true
        if comp == ">=" then
            pass = (valPct >= targetPct)
        elseif comp == "<=" then
            pass = (valPct <= targetPct)
        elseif comp == "==" then
            pass = (valPct == targetPct)
        end

        if not pass then
            show = false
        end
    end

    -- === Remaining (cooldown time left) ===
	if show and c.remainingEnabled
	   and c.remainingComp and c.remainingComp ~= ""
	   and c.remainingVal  ~= nil and c.remainingVal  ~= "" then

        local threshold = tonumber(c.remainingVal)
        if threshold then
            local rem = _AbilityRemainingSeconds(spellIndex, bookType)

            -- the real remaining cooldown for this spellbook entry.
            if rem and rem > 0 then
                if not _RemainingPasses(rem, c.remainingComp, threshold) then
                    show = false
                end
            end
        end
    end

    -- === Aura Conditions (extra ability gating) ===========================
    if show and c.auraConditions and table.getn(c.auraConditions) > 0 then
        if not DoiteConditions_EvaluateAuraConditionsList(c.auraConditions) then
            show = false
        end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false

    return show, glow, grey
end


---------------------------------------------------------------
-- Item condition evaluation
---------------------------------------------------------------
local function CheckItemConditions(data)
    if not data or not data.conditions or not data.conditions.item then
        return true, false, false
    end
    local c = data.conditions.item

    -- While editing this key, force conditions to pass (always show)
    if _IsKeyUnderEdit(data.key) then
        local glow = (c.glow and true) or false
        local grey = (c.greyscale and true) or false
        return true, glow, grey
    end

    local show = true

	-- Shared target flags
	local allowHelp = (c.targetHelp == true)
	local allowHarm = (c.targetHarm == true)
	local allowSelf = (c.targetSelf == true)

	-- Cache target facts once per evaluation (1 local only; avoids Lua 5.0 local limit)
	local tf = _DA_GetTargetFacts()

    -- --------------------------------------------------------------------
    -- 1. Core item state (Whereabouts / inventorySlot + mode / cooldown)
    -- --------------------------------------------------------------------
    local state = _EvaluateItemCoreState(data, c)

    -- Whereabouts / inventorySlot gating
    if not state.passesWhere then
        local glow = c.glow and true or false
        local grey = c.greyscale and true or false
        return false, glow, grey
    end

    -- Mode ("oncd" / "notcd") gating
    if state.modeMatches == false then
        local glow = c.glow and true or false
        local grey = c.greyscale and true or false
        return false, glow, grey
    end

    -- --------------------------------------------------------------------
    -- 2. Combat state
    -- --------------------------------------------------------------------
    local inCombatFlag  = (c.inCombat == true)
    local outCombatFlag = (c.outCombat == true)

    if not (inCombatFlag and outCombatFlag) then
        if inCombatFlag and not InCombat() then show = false end
        if outCombatFlag and InCombat() then show = false end
    end

    -- --------------------------------------------------------------------
    -- 3. Target gating (same semantics as abilities)
    -- --------------------------------------------------------------------
	if show and (allowHelp or allowHarm or allowSelf) then
		local ok = false

		if allowSelf and tf.exists and tf.isSelf then
			ok = true
		end

		if (not ok) and allowHelp and tf.exists and tf.isFriend and (not tf.isSelf) then
			ok = true
		end

		if (not ok) and allowHarm and tf.exists and tf.canAttack and (not tf.isFriend) then
			ok = true
		end

		if not ok then
			show = false
		end
	end
	
	-- --------------------------------------------------------------------
    -- Target status / Distance / UnitType (items)
    -- --------------------------------------------------------------------
    if show and (c.targetDistance or c.targetUnitType or c.targetAlive or c.targetDead) then
        local unitForTarget = nil

		if tf.exists then
			unitForTarget = "target"
		end

        if unitForTarget then
            -- Alive / dead requirement (if configured)
            if not DoiteConditions_PassesTargetStatus(c, unitForTarget) then
                show = false
            elseif not DoiteConditions_PassesTargetDistance(c, unitForTarget, nil) then
                show = false
            elseif not DoiteConditions_PassesTargetUnitType(c, unitForTarget) then
                show = false
            end
        end
    end

    -- --------------------------------------------------------------------
    -- Weapon filter (Two-Hand / Shield / Dual-Wield)
    -- --------------------------------------------------------------------
    if show and c.weaponFilter and c.weaponFilter ~= "" then
        if not DoiteConditions_PassesWeaponFilter(c) then
            show = false
        end
    end

    -- --------------------------------------------------------------------
    -- Form / stance requirement
    -- --------------------------------------------------------------------
    if show and c.form and c.form ~= "All" then
        if not DoiteConditions_PassesFormRequirement(c.form, auraSnapshot) then
            show = false
        end
    end

    -- --------------------------------------------------------------------
    -- 5. HP threshold (my / target) – same logic as abilities
    -- --------------------------------------------------------------------
    if show and c.hpComp and c.hpVal and c.hpMode and c.hpMode ~= "" then
        local hpTarget = nil
        if c.hpMode == "my" then
            hpTarget = "player"
        elseif c.hpMode == "target" then
			if tf.exists then
				if allowSelf then
					if tf.isSelf then
						hpTarget = "target"
					end
				elseif allowHelp and allowHarm then
					if not tf.isSelf then
						hpTarget = "target"
					end
				elseif allowHelp then
					if tf.isFriend and (not tf.isSelf) then
						hpTarget = "target"
					end
				elseif allowHarm then
					if tf.canAttack and (not tf.isFriend) then
						hpTarget = "target"
					end
				else
					hpTarget = "target"
				end
			end
        end

        if hpTarget then
            local pct = _HPPercent(hpTarget)
            local thr = tonumber(c.hpVal)
            if thr and not _ValuePasses(pct, c.hpComp, thr) then
                show = false
            end
        end
    end

    -- --------------------------------------------------------------------
    -- 6. Combo points (Rogue/Druid only) – same as abilities
    -- --------------------------------------------------------------------
    if show and c.cpEnabled == true and _PlayerUsesComboPoints() then
        local cp  = _GetComboPointsSafe()
        local thr = tonumber(c.cpVal)
        if thr and c.cpComp and c.cpComp ~= "" then
            if not _ValuePasses(cp, c.cpComp, thr) then
                show = false
            end
        end
    end

    -- --------------------------------------------------------------------
    -- 7. Power (resource) threshold – same semantics as abilities
    -- --------------------------------------------------------------------
    if show and c.powerEnabled
       and c.powerComp ~= nil and c.powerComp ~= ""
       and c.powerVal  ~= nil and c.powerVal  ~= "" then

        local valPct    = GetPowerPercent()
        local targetPct = tonumber(c.powerVal) or 0
        local comp      = c.powerComp

        if not _ValuePasses(valPct, comp, targetPct) then
            show = false
        end
    end

    -- --------------------------------------------------------------------
    -- 8. Stack / amount threshold (bags + equipped, respecting Whereabouts)
    -- --------------------------------------------------------------------
    if show and c.stacksEnabled
       and c.stacksComp and c.stacksComp ~= ""
       and c.stacksVal  ~= nil and c.stacksVal  ~= "" then

        local threshold = tonumber(c.stacksVal)
        if threshold and state then
            local cnt = state.effectiveCount or 0
            if not _StacksPasses(cnt, c.stacksComp, threshold) then
                show = false
            end
        end
    end

    -- --------------------------------------------------------------------
    -- 9. Remaining (item cooldown time left)
    --     Editor only allows this when mode == "oncd" and not whereMissing.
    -- --------------------------------------------------------------------
    if show and c.remainingEnabled
       and c.remainingComp and c.remainingComp ~= ""
       and c.remainingVal  ~= nil and c.remainingVal  ~= "" then

        local threshold = tonumber(c.remainingVal)
        if threshold and state.rem and state.rem > 0 then
            if not _RemainingPasses(state.rem, c.remainingComp, threshold) then
                show = false
            end
        end
    end

    -- === Aura Conditions (extra item gating) ==============================
    if show and c.auraConditions and table.getn(c.auraConditions) > 0 then
        if not DoiteConditions_EvaluateAuraConditionsList(c.auraConditions) then
            show = false
        end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false
    return show, glow, grey
end

---------------------------------------------------------------
-- Aura condition evaluation (with caching)
---------------------------------------------------------------
local function CheckAuraConditions(data)
    if not data or not data.conditions or not data.conditions.aura then
        return true, false, false
    end
    local c = data.conditions.aura

    -- While editing this key, force conditions to pass (always show).
    if _IsKeyUnderEdit(data.key) then
        local glow = (c.glow and true) or false
        local grey = (c.greyscale and true) or false
        return true, glow, grey
    end

    local name = data.displayName or data.name
    if not name then return false, false, false end

    -- Enforce correct aura type
    local wantBuff   = (data.type == "Buff")
    local wantDebuff = (data.type == "Debuff")
    if not wantBuff and not wantDebuff then
        -- Back-compat: if type missing, allow either
        wantBuff, wantDebuff = true, true
    end

    -- multi-select booleans
    local allowHelp = (c.targetHelp == true)
    local allowHarm = (c.targetHarm == true)
    local allowSelf = (c.targetSelf == true)

    -- If none selected, default to Self
    if (not allowHelp) and (not allowHarm) and (not allowSelf) then
        allowSelf = true
    end

	-- Self is exclusive with Help/Harm
	if allowSelf then
		allowHelp, allowHarm = false, false
	end

	-- Cache target facts once per evaluation (1 local only; avoids Lua 5.0 local limit)
	local tf = _DA_GetTargetFacts()
	
    local ownerFilter = nil
    local wantMine   = (c.onlyMine   == true)
    local wantOthers = (c.onlyOthers == true)

    if wantMine and not wantOthers then
        ownerFilter = "mine"
    elseif wantOthers and not wantMine then
        ownerFilter = "others"
    else
        ownerFilter = nil
    end

    -- === Target gating (OR semantics for help/harm) ===
    local requiresTarget = (allowHelp or allowHarm) and (not allowSelf)
	if requiresTarget then
		if not tf.exists then
			return false, false, false
		end

		local isFriend  = tf.isFriend
		local canAttack = tf.canAttack

        local matchesAny = false

		if allowHelp then
			if isFriend then
				-- allow friendly targets including self
				matchesAny = true
			end
		end

        if (not matchesAny) and allowHarm then
            if canAttack and (not isFriend) then
                matchesAny = true
            end
        end

        if not matchesAny then
            return false, false, false
        end
    end

    local found = false

    -- Self auras — aura on player, regardless of target
    if (not found) and allowSelf then
        local s   = auraSnapshot.player
        local hit = false

        if s then
            -- Buffs: unchanged.
            if wantBuff and s.buffs[name] then
                hit = true
            -- Debuffs: overflow-aware.
            elseif wantDebuff and _UnitHasOverflowDebuff("player", name) then
                hit = true
            end
        end

        if hit then
            found = true
        else
            -- light live probe if snapshot missed it
            local i = 1
            local liveHit = false
            if wantBuff then
                while i <= 40 do
                    local n = _GetAuraName("player", i, false)
                    if n == nil then
                        break  -- real end of list
                    end
                    if n ~= "" and n == name then
                        liveHit = true
                        break
                    end
                    i = i + 1
                end
            end
            if (not liveHit) and wantDebuff then
                i = 1
                while i <= 40 do
                    local n = _GetAuraName("player", i, true)
                    if n == nil then
                        break
                    end
                    if n ~= "" and n == name then
                        liveHit = true
                        break
                    end
                    i = i + 1
                end
            end
            if liveHit then found = true end
        end
    end

    -- Target (help) — requires friendly target (already gated above)
    if (not found) and allowHelp then
        local s = auraSnapshot.target
        if s then
            local hit = false

            -- Buff-type icons: unchanged.
            if wantBuff and s.buffs[name] then
                hit = true
            -- Debuff-type icons: overflow-aware.
            elseif wantDebuff and _UnitHasOverflowDebuff("target", name) then
                hit = true
            end

            if hit then
                found = true
            end
        end
    end

    -- Target (harm) — requires hostile target (already gated above)
    if (not found) and allowHarm then
        local s = auraSnapshot.target
        if s then
            local hit = false

            -- Buff-type icons: unchanged.
            if wantBuff and s.buffs[name] then
                hit = true
            -- Debuff-type icons: overflow-aware.
            elseif wantDebuff and _UnitHasOverflowDebuff("target", name) then
                hit = true
            end

            if hit then
                found = true
            end
        end
    end

    -- === DoiteTrack aura owner filter ("My Aura" / "Others Aura") ===
	if found and ownerFilter and DoiteTrack then
		local ownerUnit = nil

		if allowSelf then
			ownerUnit = "player"
		elseif (allowHelp or allowHarm) and UnitExists("target") then
			ownerUnit = "target"
		end

		if ownerUnit then
			local _, _, _, isMine, isOther, mineKnown = _DoiteTrackAuraOwnership(name, ownerUnit)

			if mineKnown then
				if ownerFilter == "mine" and not isMine then
					found = false
				elseif ownerFilter == "others" and not isOther then
					found = false
				end
			end
		end
	end

    -- Decide show based on mode first
    local show
    if c.mode == "missing" then
        show = (not found)
    else -- default and "found"
        show = found
    end

    -- Combat state
    local inCombatFlag  = (c.inCombat == true)
    local outCombatFlag = (c.outCombat == true)
    if not (inCombatFlag and outCombatFlag) then
        if inCombatFlag and not InCombat() then show = false end
        if outCombatFlag and InCombat() then show = false end
    end

    -- === Form / Stance requirement (if set)
    if c.form and c.form ~= "All" then
        if not DoiteConditions_PassesFormRequirement(c.form, auraSnapshot) then
            show = false
        end
    end

    -- === Weapon filter (Two-Hand / Shield / Dual-Wield) ===
    if show and c.weaponFilter and c.weaponFilter ~= "" then
        if not DoiteConditions_PassesWeaponFilter(c) then
            show = false
        end
    end

    -- === Power threshold (% of max) — same semantics as abilities
    if show and c.powerEnabled
       and c.powerComp and c.powerComp ~= ""
       and c.powerVal  and c.powerVal  ~= "" then

        local valPct    = GetPowerPercent()
        local targetPct = tonumber(c.powerVal) or 0
        local comp      = c.powerComp

        local pass = true
        if comp == ">=" then
            pass = (valPct >= targetPct)
        elseif comp == "<=" then
            pass = (valPct <= targetPct)
        elseif comp == "==" then
            pass = (valPct == targetPct)
        end
        if not pass then show = false end
    end

    -- === HP threshold (% of max) — respects target flags
    if show and c.hpComp and c.hpVal and c.hpMode and c.hpMode ~= "" then
        local hpTarget = nil
        if c.hpMode == "my" then
            hpTarget = "player"
        elseif c.hpMode == "target" then
            local allowHelp = (c.targetHelp == true)
            local allowHarm = (c.targetHarm == true)
            local allowSelf = (c.targetSelf == true)

            if UnitExists("target") then
                if allowSelf then
                    hpTarget = "target"

                elseif allowHelp and allowHarm then
                    -- Both: any non-self target (friendly or hostile)
                    if not UnitIsUnit("player","target") then
                        hpTarget = "target"
                    end
                elseif allowHelp then
                    if UnitIsFriend("player","target")
                       and (not UnitIsUnit("player","target")) then
                        hpTarget = "target"
                    end
                elseif allowHarm then
                    if UnitCanAttack("player","target")
                       and (not UnitIsFriend("player","target")) then
                        hpTarget = "target"
                    end
                else
                    hpTarget = "target"
                end
            end
        end

        if hpTarget then
            local pct = _HPPercent(hpTarget)
            local thr = tonumber(c.hpVal)
            if thr and not _ValuePasses(pct, c.hpComp, thr) then
                show = false
            end
        end
    end

    -- === Combo Points (Rogue/Druid only) ===
    if show and c.cpEnabled == true and _PlayerUsesComboPoints() then
        local cp = _GetComboPointsSafe()
        local thr = tonumber(c.cpVal)
        if thr and c.cpComp and c.cpComp ~= "" then
            if not _ValuePasses(cp, c.cpComp, thr) then
                show = false
            end
        end
    end

    -- === Remaining-time condition ==========================================
    if c.remainingEnabled
       and c.remainingComp and c.remainingComp ~= ""
       and c.remainingVal  ~= nil and c.remainingVal  ~= "" then

        if c.mode ~= "missing" and show then
            local unitForRem

            local allowHelp = (c.targetHelp == true)
            local allowHarm = (c.targetHarm == true)
            local allowSelf = (c.targetSelf == true)

            -- If none selected, default to Self (match stacks + time-text behavior)
            if (not allowHelp) and (not allowHarm) and (not allowSelf) then
                allowSelf = true
            end

            if allowSelf then
                unitForRem = "player"
            else
                if UnitExists("target") and (allowHelp or allowHarm) then
                    local isFriend  = UnitIsFriend("player","target")
                    local canAttack = UnitCanAttack("player","target")

                    if allowHelp and allowHarm then
                        -- Both: any non-self target (friendly or hostile)
                        if not UnitIsUnit("player","target") then
                            unitForRem = "target"
                        end
                    elseif allowHelp then
                        -- Friendly target, excluding self
                        if isFriend and (not UnitIsUnit("player","target")) then
                            unitForRem = "target"
                        end
                    elseif allowHarm then
                        -- Hostile target
                        if canAttack and (not isFriend) then
                            unitForRem = "target"
                        end
                    end
                end
            end

            local threshold = tonumber(c.remainingVal)
            if unitForRem and threshold then
                local comp = c.remainingComp
                local pass = true

                if unitForRem == "player" then
                    -- PLAYER/SELF remaining time must reflect the actual visible aura time (vanilla API)
                    local rem = _PlayerAuraRemainingSeconds(name)

                    if rem and rem > 0 then
                        pass = _RemainingPasses(rem, comp, threshold)
                    else
                        pass = false
                    end
                else

                    if ownerFilter == "mine" and DoiteTrack then
						local rpass = _DoiteTrackRemainingPass(name, unitForRem, comp, threshold)
						if rpass == nil then
							pass = false
						else
							pass = rpass
						end
                    else
                        -- No target-based remaining gating in all other cases
                        pass = true
                    end
                end

                if not pass then
                    show = false
                end
            end
        end
    end


       -- === Stacks (aura applications) ===
    if c.stacksEnabled
       and c.stacksComp and c.stacksComp ~= ""
       and c.stacksVal  ~= nil and c.stacksVal  ~= ""
       and c.mode ~= "missing"
       and show then

        local threshold = tonumber(c.stacksVal)
        if threshold then
            local unitToCheck = nil

            -- Use the same target semantics as main aura gating
            local allowHelp = (c.targetHelp == true)
            local allowHarm = (c.targetHarm == true)
            local allowSelf = (c.targetSelf == true)

            -- If none selected, default to Self
            if (not allowHelp) and (not allowHarm) and (not allowSelf) then
                allowSelf = true
            end

            if allowSelf then
                -- Explicit or implied self: always read stacks from player
                unitToCheck = "player"
            elseif tf and tf.exists and (allowHelp or allowHarm) then
                -- Use cached target facts (no extra UnitIsFriend/UnitCanAttack calls)
                local isFriend  = tf.isFriend
                local canAttack = tf.canAttack

                -- Help: friendly targets including self
                if allowHelp and isFriend then
                    unitToCheck = "target"
                -- Harm: hostile, non-friendly targets
                elseif allowHarm and canAttack and (not isFriend) then
                    unitToCheck = "target"
                end
            end

            if unitToCheck then
                local cnt = _GetAuraStacksOnUnit(unitToCheck, name, wantDebuff)
                if cnt and (not _StacksPasses(cnt, c.stacksComp, threshold)) then
                    show = false
                end
            end
        end
    end

    -- === Target status / Distance / UnitType (auras) ======================
    if show and (c.targetDistance or c.targetUnitType or c.targetAlive or c.targetDead) then
        -- For aura icons only apply these when looking at a real target (help/harm). Pure self-aura icons usually don't care about range.
        local unitForTargetMods = nil
        local allowHelp = (c.targetHelp == true)
        local allowHarm = (c.targetHarm == true)
        local allowSelf = (c.targetSelf == true)

		if tf and tf.exists and (allowHelp or allowHarm) then
			unitForTargetMods = "target"
		end

        if unitForTargetMods then
            -- Alive / dead requirement (if configured)
            if not DoiteConditions_PassesTargetStatus(c, unitForTargetMods) then
                show = false
            elseif not DoiteConditions_PassesTargetDistance(c, unitForTargetMods, nil) then
                show = false
            elseif not DoiteConditions_PassesTargetUnitType(c, unitForTargetMods) then
                show = false
            end
        end
    end

    -- === Aura Conditions (extra aura-icon gating) =========================
    if show and c.auraConditions and table.getn(c.auraConditions) > 0 then
        if not DoiteConditions_EvaluateAuraConditionsList(c.auraConditions) then
            show = false
        end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false
    return show, glow, grey
end

---------------------------------------------------------------
-- Main update
---------------------------------------------------------------
function DoiteConditions:EvaluateAll()
	local editingAny = _IsAnyKeyUnderEdit()
    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

    local key, data

    -- 1) Live icons (runtime set)
    if live then
        for key, data in pairs(live) do
            -- Defensive: skip and clean up any corrupted entries so they
            -- can't break the evaluation loop.
            if type(data) ~= "table" then
                live[key] = nil
            elseif data.type then
                data.key = key

                if data.type == "Ability" or data.type == "Item" then
                    local show, glow, grey
                    if data.type == "Ability" then
                        show, glow, grey = CheckAbilityConditions(data)
                    else
                        show, glow, grey = CheckItemConditions(data)
                    end
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)

                elseif data.type == "Buff" or data.type == "Debuff" then
                    local show, glow, grey = CheckAuraConditions(data)
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)
                end
            end
        end
    end

    -- 2) Any extra editor-only icons (keys not in live)
    if edit then
        for key, data in pairs(edit) do
            if (not live) or (not live[key]) then
                if type(data) ~= "table" then
                    edit[key] = nil
                elseif data.type then
                    data.key = key

                    if data.type == "Ability" or data.type == "Item" then
                        local show, glow, grey
                        if data.type == "Ability" then
                            show, glow, grey = CheckAbilityConditions(data)
                        else
                            show, glow, grey = CheckItemConditions(data)
                        end
                        DoiteConditions:ApplyVisuals(key, show, glow, grey)

                    elseif data.type == "Buff" or data.type == "Debuff" then
                        local show, glow, grey = CheckAuraConditions(data)
                        DoiteConditions:ApplyVisuals(key, show, glow, grey)
                    end
                end
            end
        end
    end
end

-- Centralized overlay updater: remaining-time text + stacks.
-- Used by both ApplyVisuals (logic passes) and the light timer ticker.
-- Cache small integer -> string to avoid repeated tostring() churn (stacks/items)
local _DA_NumStrCache = {}
local function _DA_NumToStr(n)
    if not n then return "" end
    local s = _DA_NumStrCache[n]
    if not s then
        s = tostring(n)
        _DA_NumStrCache[n] = s
    end
    return s
end

local function _Doite_UpdateOverlayForFrame(frame, key, dataTbl, slideActive)
    if not frame or not dataTbl then return end

    -- Ensure a dedicated top layer so text always renders above any glow frames
    if not frame._daTextLayer then
        local tl = CreateFrame("Frame", nil, frame)
        frame._daTextLayer = tl
        tl:SetAllPoints(frame)
    end

    -- Keep this child well above siblings (incl. typical glow frames)
    do
        local baseLevel = frame:GetFrameLevel() or 0
        frame._daTextLayer:SetFrameStrata(frame:GetFrameStrata() or "MEDIUM")
        frame._daTextLayer:SetFrameLevel(baseLevel + 50)
    end

    -- Lazy-create fontstrings parented to the text layer
    if not frame._daTextRem then
        local fs = frame._daTextLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetJustifyH("CENTER")
        fs:SetJustifyV("MIDDLE")
        frame._daTextRem = fs
    end
    if not frame._daTextStacks then
        local fs2 = frame._daTextLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs2:SetJustifyH("RIGHT")
        fs2:SetJustifyV("BOTTOM")
        frame._daTextStacks = fs2
        frame._daLastTextSize = 0
    end

    -- Only resize if changed
    local w = frame:GetWidth() or 36
    local last = frame._daLastTextSize or 0
    if math.abs(w - last) >= 1 then
        frame._daLastTextSize = w
        local remSize   = math.max(10, math.floor(w * 0.42))
        local stackSize = math.max(8,  math.floor(w * 0.28))
        frame._daTextRem:SetFont(GameFontHighlight:GetFont(), remSize, "OUTLINE")
        frame._daTextStacks:SetFont(GameFontNormalSmall:GetFont(), stackSize, "OUTLINE")
    end

    -- Anchor (relative to the icon frame; parented to _daTextLayer)
    frame._daTextRem:ClearAllPoints()
    frame._daTextRem:SetPoint("CENTER", frame, "CENTER", 0, 0)

    frame._daTextStacks:ClearAllPoints()
    frame._daTextStacks:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)

    -- Defaults hidden (avoid redundant SetText allocations)
    if frame._daLastRemText ~= "" then
        frame._daLastRemText = ""
        frame._daTextRem:SetText("")
    end
    frame._daTextRem:Hide()

    if frame._daLastStacksText ~= "" then
        frame._daLastStacksText = ""
        frame._daTextStacks:SetText("")
    end
    frame._daTextStacks:Hide()

    -- Reset per-evaluation sort remaining time (used by group "time" mode)
    frame._daSortRem = nil

    -- ========== Remaining Time ==========
    local wantRem = false
    local remText = nil
	local itemState = nil

    -- Decide if show time text for abilities
    local function _ShowAbilityTime(ca, rem, dur, slide)
        if not rem or rem <= 0 then return false end
        dur = dur or 0

        -- 1) ON COOLDOWN: always show for the entire real cooldown.
        if ca.mode == "oncd" then
            return (dur > 0)
        end

        -- 2) USABLE / NOTCD with slider: slide can override the 1.6s/GCD filter
        if (ca.mode == "usable" or ca.mode == "notcd") and ca.slider == true then
            if slide then
                return true
            end
            local maxWindow = math.min(3.0, (dur or 0) * 0.6)
            return rem <= maxWindow and (dur > 1.6)
        end

        -- Default (paranoid): late window + real cooldown
        local maxWindow = math.min(3.0, (dur or 0) * 0.6)
        return (dur > 1.6) and (rem <= maxWindow)
    end

    if dataTbl then
        ----------------------------------------------------------------
        -- Ability remaining-time text
        ----------------------------------------------------------------
        if dataTbl.type == "Ability"
           and dataTbl.conditions
           and dataTbl.conditions.ability then

            local ca = dataTbl.conditions.ability

            local spellName     = _GetCanonicalSpellNameFromData(dataTbl)
            local remCD, durCD  = _AbilityCooldownByName(spellName)
            local remShown, durShown = nil, nil

            -- 1) Normal cooldown remaining text (ONLY when user enabled it)
            if ca.textTimeRemaining == true then
                if remCD and remCD > 0 and _ShowAbilityTime(ca, remCD, durCD, slideActive) then
                    remShown = remCD
                    durShown = durCD
                end
            end

            -- 2) Proc-window remaining text (ONLY for mode == "usable")
            if (not remShown) and spellName and (ca.mode == "usable") then
                local procDur = _ProcWindowDuration(spellName)
                if procDur then
                    local realCd = false
                    if remCD and remCD > 0 and durCD and durCD > 1.6 then
                        realCd = true
                    end

                    if not realCd then
                        local remProc = _ProcWindowRemaining(spellName)
                        if remProc and remProc > 0 then
                            remShown = remProc
                            durShown = procDur
                        end
                    end
                end
            end

            if remShown and remShown > 0 then
                remText = _FmtRem(remShown)
                wantRem = (remText ~= nil)
                frame._daSortRem = remShown
            end

        ----------------------------------------------------------------
        -- Item remaining-time text
        ----------------------------------------------------------------
        elseif (dataTbl.type == "Item")
           and dataTbl.conditions
           and dataTbl.conditions.item then

            local ci = dataTbl.conditions.item

            if ci.textTimeRemaining == true then
                -- Reuse this later for stack counter too
                itemState = _EvaluateItemCoreState(dataTbl, ci)

                local remItem = itemState and itemState.rem or nil
                local durItem = itemState and itemState.dur or 0

                -- Ignore ultra-short junk cooldowns; only show real cooldowns
                if remItem and remItem > 0 and durItem and durItem > 1.5 then
                    remText = _FmtRem(remItem)
                    wantRem = (remText ~= nil)
                    frame._daSortRem = remItem
                end
            end

        ----------------------------------------------------------------
        -- Aura remaining-time text
        ----------------------------------------------------------------
        elseif (dataTbl.type == "Buff" or dataTbl.type == "Debuff")
           and dataTbl.conditions
           and dataTbl.conditions.aura then

            local ca = dataTbl.conditions.aura

            if ca.textTimeRemaining == true then
                local auraName = dataTbl.displayName or dataTbl.name
                local unitForRem = nil

                local allowHelp = (ca.targetHelp == true)
                local allowHarm = (ca.targetHarm == true)
                local allowSelf = (ca.targetSelf == true)

                -- If none selected, default to Self (matches CheckAuraConditions)
                if (not allowHelp) and (not allowHarm) and (not allowSelf) then
                    allowSelf = true
                end

                if allowSelf then
                    unitForRem = "player"
                elseif (allowHelp or allowHarm) then
                    local tf = _DA_GetTargetFacts()
                    if tf and tf.exists then
                        local isFriend  = tf.isFriend
                        local canAttack = tf.canAttack

                        if allowHelp and isFriend then
                            unitForRem = "target"
                        elseif allowHarm and canAttack and (not isFriend) then
                            unitForRem = "target"
                        end
                    end
                end

                local remAura = nil

				if unitForRem == "player" then
					-- PLAYER/SELF remaining-time text must reflect the actual visible aura time (vanilla/tooltip scan), never DoiteTrack. Ownership filtering (onlyMine/onlyOthers) belongs in the condition logic.
					remAura = _PlayerAuraRemainingSeconds(auraName)

				elseif unitForRem == "target" then
					-- Target remaining time relies on DoiteTrack (vanilla target auras don't expose durations).
					remAura = _DoiteTrackAuraRemainingSeconds(auraName, "target")
				end

                if remAura and remAura > 0 then
                    remText = _FmtRem(remAura)
                    wantRem = (remText ~= nil)
                    frame._daSortRem = remAura
                end
            end
        end
    end

    if wantRem and remText then
        if remText ~= frame._daLastRemText then
            frame._daLastRemText = remText
            frame._daTextRem:SetText(remText)
        end
        frame._daTextRem:SetTextColor(1, 1, 1, 1)
        frame._daTextRem:Show()
    end

    -- ========== Stack Counter (auras only) ==========
    if dataTbl
       and (dataTbl.type == "Buff" or dataTbl.type == "Debuff")
       and dataTbl.conditions
       and dataTbl.conditions.aura then

        local ca = dataTbl.conditions.aura
        if ca.textStackCounter == true then
            local auraName   = dataTbl.displayName or dataTbl.name
            local wantDebuff = (dataTbl.type == "Debuff")

            -- Resolve which unit to read stacks from (same semantics as CheckAuraConditions)
            local unitToCheck = nil
            local allowHelp   = (ca.targetHelp == true)
            local allowHarm   = (ca.targetHarm == true)
            local allowSelf   = (ca.targetSelf == true)

            -- If nothing selected, default to Self
            if (not allowHelp) and (not allowHarm) and (not allowSelf) then
                allowSelf = true
            end

            if allowSelf then
                unitToCheck = "player"
            elseif (allowHelp or allowHarm) then
                -- Cache target facts once
                local tf = _DA_GetTargetFacts()
                if tf.exists then
                    -- Help: friendly targets including self
                    if allowHelp and tf.isFriend then
                        unitToCheck = "target"
                    -- Harm: hostile, non-friendly targets
                    elseif allowHarm and tf.canAttack and (not tf.isFriend) then
                        unitToCheck = "target"
                    end
                end
            end

            if unitToCheck then
                local cnt = _GetAuraStacksOnUnit(unitToCheck, auraName, wantDebuff)
                if cnt and cnt >= 1 then
                    local s = _DA_NumToStr(cnt)
                    if s ~= frame._daLastStacksText then
                        frame._daLastStacksText = s
                        frame._daTextStacks:SetText(s)
                    end
                    frame._daTextStacks:SetTextColor(1, 0.2, 0.2, 1)
                    frame._daTextStacks:Show()
                end
            end
        end
    end
	    -- ========== Stack Counter (items: total amount) ==========
    if dataTbl
       and dataTbl.type == "Item"
       and dataTbl.conditions
       and dataTbl.conditions.item then

        local ci = dataTbl.conditions.item
        if ci.textStackCounter == true then
            -- Reuse any state already computed in the Item branch above
            local state = itemState
            if not state then
                state = _EvaluateItemCoreState(dataTbl, ci)
            end

            local cnt = state and state.effectiveCount or nil
            if cnt and cnt >= 1 then
                local s = _DA_NumToStr(cnt)
                if s ~= frame._daLastStacksText then
                    frame._daLastStacksText = s
                    frame._daTextStacks:SetText(s)
                end
                frame._daTextStacks:SetTextColor(1, 0.2, 0.2, 1)
                frame._daTextStacks:Show()
            end
        end
    end
end

-- Ability cooldown slider helper (reduces upvalues in ApplyVisuals)
local function _HandleAbilitySlider(key, ca, dataTbl)
    -- Only for Ability icons in usable/notcd mode with slider enabled
    if not (key and ca and dataTbl) then
        if SlideMgr.active and SlideMgr.active[key] then
            SlideMgr:Stop(key)
        end
        return false, false, false, 0, 0, 1
    end

    if not (ca.slider and (ca.mode == "usable" or ca.mode == "notcd")) then
        -- Slider disabled for this icon: make sure it's stopped
        local had = SlideMgr.active and SlideMgr.active[key]
        if had then
            SlideMgr:Stop(key)
            return false, true, false, 0, 0, 1
        end
        SlideMgr:Stop(key)
        return false, false, false, 0, 0, 1
    end

    local spellName  = _GetCanonicalSpellNameFromData(dataTbl)
    local rem, dur   = _AbilityCooldownByName(spellName)
    local wasSliding = SlideMgr.active and SlideMgr.active[key]
    local maxWindow  = math.min(3.0, (dur or 0) * 0.6)

    -- Last time *this* spell was actually seen cast (UNIT_CASTEVENT -> _MarkSliderSeen)
    local lastSeen = spellName and _SliderSeen and _SliderSeen[spellName] or nil

	local hasSeenForThisCD = false

	if spellName
	   and _SliderNoCastWhitelist[spellName]
	   and rem and dur and dur > 1.6 then
		-- Whitelisted: trust the *real* cooldown even without UNIT_CASTEVENT.
		hasSeenForThisCD = true

	elseif lastSeen and rem and dur and dur > 0 then
		local now   = GetTime()
		-- reconstruct approximate cooldown start from (now, rem, dur)
		local start = now + rem - dur
		-- small epsilon because lastSeen and start are sampled in
		if lastSeen + 0.25 >= start then
			hasSeenForThisCD = true
		end
	end


    -- Start only when this cooldown really belongs to this spell, but allow short CDs (GCD-only) as long as they're from this spell.
    local shouldStart = hasSeenForThisCD and rem and dur and rem > 0 and rem <= maxWindow

    -- Once sliding, ONLY keep the slide alive while within the slide window.
    local contLimit = maxWindow

    -- If maxWindow is very small (short CDs / GCD-ish), allow up to GCD range - don't kill the slide on tiny bumps.
    if contLimit < 1.60 then
        contLimit = 1.60
    end

    -- Small sampling jitter allowance.
    contLimit = contLimit + 0.15

    local shouldContinue = wasSliding and rem and rem > 0 and rem <= contLimit


    local startedSlide, stoppedSlide = false, false

    if shouldStart or shouldContinue then
        local baseX, baseY = 0, 0
        if _GetBaseXY then
            baseX, baseY = _GetBaseXY(key, dataTbl)
        end

        SlideMgr:StartOrUpdate(
            key,
            (ca.sliderDir or "center"),
            baseX,
            baseY,
            GetTime() + (rem or 0)
        )

        if not wasSliding then
            startedSlide = true
        end
    else
        if wasSliding then
            stoppedSlide = true
        end
        SlideMgr:Stop(key)
    end

    local active, dx, dy, alpha = SlideMgr:Get(key)
    if not active then
        return startedSlide, stoppedSlide, false, 0, 0, 1
    end
    return startedSlide, stoppedSlide, true, dx or 0, dy or 0, alpha or 1
end

---------------------------------------------------------------
-- Apply visuals to icons
---------------------------------------------------------------
function DoiteConditions:ApplyVisuals(key, show, glow, grey)
    local frame = _GetIconFrame(key)
    if not frame then
        -- If icons rebuilt, forget any stale cached ref for this key and retry.
        _ForgetIconFrame(key)
        if DoiteAuras_RefreshIcons then DoiteAuras_RefreshIcons() end
        frame = _GetIconFrame(key)
        if not frame then return end
    end

local dataTbl = (DoiteDB and DoiteDB.icons and DoiteDB.icons[key])
                or (DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key])

	-- Compute editing FIRST (needed by proc-window guard + texture preload)
	local editing = _IsKeyUnderEdit(key)

	if (not editing) and dataTbl and dataTbl.type == "Ability"
	   and dataTbl.conditions and dataTbl.conditions.ability then

		local ca = dataTbl.conditions.ability
		if ca and ca.mode == "usable" then
			local spellName = _GetCanonicalSpellNameFromData(dataTbl)
			local dur = _ProcWindowDuration(spellName)

			if dur then
				local prev = (_ProcLastShowByKey[key] == true)

				if show and (not prev) then
					local now = GetTime()
					local curUntil = _ProcUntil[spellName] or 0
					if curUntil < now then
						_ProcWindowSet(spellName, now + dur)
					end
				end

				_ProcLastShowByKey[key] = (show == true) and true or false
			end
		end
	end

	if show or editing then
		if frame.icon and not frame.icon:GetTexture() and dataTbl and (dataTbl.displayName or dataTbl.name) then
			local nameKey = dataTbl.displayName or dataTbl.name

			-- Prefer per-entry stored texture, then cache, then fallback.
			local tex = nil
			if dataTbl.iconTexture and dataTbl.iconTexture ~= "" then
				tex = dataTbl.iconTexture
			elseif IconCache and nameKey then
				tex = IconCache[nameKey]
			end

			if tex and tex ~= "" then
				frame.icon:SetTexture(tex)
			else
				frame.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
			end
		end

		if dataTbl then
			if dataTbl.type == "Ability" then
				_EnsureAbilityTexture(frame, dataTbl)
			elseif dataTbl.type == "Buff" or dataTbl.type == "Debuff" then
				_EnsureAuraTexture(frame, dataTbl)
			elseif dataTbl.type == "Item" then
				_EnsureItemTexture(frame, dataTbl)
			end
		end
	end

    ------------------------------------------------------------
    -- Slider (driven by SlideMgr; ignores GCD; super smooth)
    ------------------------------------------------------------
    local slideActive, dx, dy, slideAlpha = false, 0, 0, 1

    if dataTbl and dataTbl.type == "Ability"
       and dataTbl.conditions
       and dataTbl.conditions.ability then

        local ca = dataTbl.conditions.ability
        local startedSlide, stoppedSlide

        -- Lightweight wrapper: heavy logic lives in _HandleAbilitySlider
        startedSlide, stoppedSlide, slideActive, dx, dy, slideAlpha =
            _HandleAbilitySlider(key, ca, dataTbl)

        -- === immediate group reflow on slide start/stop ===
        if (startedSlide or stoppedSlide) and DoiteGroup and DoiteGroup.ApplyGroupLayout then
            if type(DoiteAuras) == "table"
               and type(DoiteAuras.GetAllCandidates) == "function" then
                _G["DoiteGroup_NeedReflow"] = true
            end
        end
    else
        -- Non-ability icons never slide
        if SlideMgr.active and SlideMgr.active[key] then
            SlideMgr:Stop(key)
        end
    end
	
    -- Pull the current slide offset/alpha (if sliding)
    local allowSlideShow = false
    do


        -- ==== Effective flags with OLD-behavior defaults ====
        -- 1) Always allow showing during slide (preview), like OLD code.
        allowSlideShow = false
		if slideActive and dataTbl and dataTbl.conditions and dataTbl.conditions.ability then
			allowSlideShow = (dataTbl.conditions.ability.slider == true)
		end

        -- 2) Default suppression during slide UNLESS slider is explicitly enabled.
        local isSliderEnabled = false
        local sliderGlowFlag  = false
        local sliderGreyFlag  = false

        if dataTbl and dataTbl.type == "Ability" and dataTbl.conditions and dataTbl.conditions.ability then
            local ca = dataTbl.conditions.ability
            if ca.slider == true then
                isSliderEnabled = true
                sliderGlowFlag  = (ca.sliderGlow == true)
                sliderGreyFlag  = (ca.sliderGrey == true)
            end
        end

        local useGlow, useGrey
        if slideActive then
            if isSliderEnabled then
                useGlow = sliderGlowFlag
                useGrey = sliderGreyFlag
            else
                useGlow = false
                useGrey = false
            end
        else
            useGlow = (glow == true)
            useGrey = (grey == true)
        end

        -- Flags for other systems / change detector
		frame._daSliding      = slideActive and true or false
		frame._daShouldShow   = ((show == true) or editing) and true or false
		frame._daUseGlow      = useGlow and true or false
		frame._daUseGreyscale = useGrey and true or false
    end

	-- Determine baseline anchoring
	local baseX, baseY = 0, 0
	if _GetBaseXY and dataTbl then baseX, baseY = _GetBaseXY(key, dataTbl) end

	-- If this icon belongs to a group, prefer the latest computed position (for leaders AND followers)
	local isGrouped = (dataTbl and dataTbl.group and dataTbl.group ~= "" and dataTbl.group ~= "no")
	local hasGroupPos = false
	if isGrouped and _G["DoiteGroup_Computed"] and _G["DoiteGroup_Computed"][dataTbl.group] then
		local arr = _G["DoiteGroup_Computed"][dataTbl.group]
		local n = table.getn(arr)
		for idx = 1, n do
			local e = arr[idx]
			if e and e.key == key and e._computedPos then
				baseX = e._computedPos.x
				baseY = e._computedPos.y
				hasGroupPos = true
				break
			end
		end
	end

	if slideActive then SlideMgr:UpdateBase(key, baseX, baseY) end

    -- Show during slide preview even if main conditions would hide
    local showForSlide = (show or allowSlideShow)

	-- If this is the key currently being edited, force it visible regardless of conditions/group caps
	if editing then
		showForSlide = true
	end

	-- Group capacity may block this icon unless editing this very key
	if frame._daBlockedByGroup and (not editing) then
		showForSlide = false
	end

    -- Apply position and alpha (no stutter: set exact coordinates each paint)
    do
        local isGrouped = (dataTbl and dataTbl.group and dataTbl.group ~= "" and dataTbl.group ~= "no")
        local isLeader = (dataTbl and dataTbl.isLeader == true)

		-- Apply position and alpha (no stutter:set exact coordinates each paint)
		do
			-- When sliding: apply transient movement to everyone (leaders + followers)
			if slideActive then
				frame:ClearAllPoints()
				frame:SetPoint("CENTER", UIParent, "CENTER", baseX + dx, baseY + dy)
				frame:SetAlpha(slideAlpha)
			else
				-- When not sliding: do NOT force followers' points here.
				if not (isGrouped and not isLeader) then
					frame:ClearAllPoints()
					frame:SetPoint("CENTER", UIParent, "CENTER", baseX, baseY)
					frame:SetAlpha((dataTbl and dataTbl.alpha) or 1)
				else
					-- Followers:
					-- Only re-anchor having a computed group position for this key.
					if hasGroupPos then
						frame:ClearAllPoints()
						frame:SetPoint("CENTER", UIParent, "CENTER", baseX, baseY)
					end
					-- If !hasGroupPos: do not touch points this tick; avoid snapping back to original x/y.
					frame:SetAlpha((dataTbl and dataTbl.alpha) or 1)
				end
			end
		end
        -- === Overlay Text: cooldown remaining + stacks (forced above glow) ===
        _Doite_UpdateOverlayForFrame(frame, key, dataTbl, slideActive)
    end

	-- === Apply EFFECTS with change detection (don’t restart animations every frame) ===
	do
		-- Decide final show flag (editing & group gating preserved)
		local showForSlide = (show or allowSlideShow)
		if editing then
			showForSlide = true
		end

		-- Never suppress the edited icon because of group capacity while editing
		if frame._daBlockedByGroup and (not editing) then
			showForSlide = false
		end

        -- Apply visibility only on change
        if frame._daLastShown ~= showForSlide then
            frame._daLastShown = showForSlide
            if showForSlide then
                frame:Show()

                if not slideActive then
                    frame:SetAlpha(1)
                end
            else
                frame:Hide()
            end
        end

		-- GREYSCALE — only flip when it changes
		if frame.icon then
			local wantGrey = (frame._daUseGreyscale == true) and showForSlide
			if frame._daLastGrey ~= wantGrey then
				frame._daLastGrey = wantGrey
				if wantGrey then
					frame.icon:SetDesaturated(1)
				else
					frame.icon:SetDesaturated(nil)
				end
			end
		end

		-- GLOW — only start/stop when it changes (preserve animation)
		if DG then
			local wantGlow = (frame._daUseGlow == true) and showForSlide
			if frame._daLastGlow ~= wantGlow then
				frame._daLastGlow = wantGlow
				if wantGlow then
					DG.Start(frame)
				else
					DG.Stop(frame)
				end
			end
		end
	end


    ----------------------------------------------------------------
    -- Reflow groups when this icon’s logical visibility flips.
    -- This covers Buff/Debuff-only groups (no abilities involved).
    ----------------------------------------------------------------
    if DoiteGroup and DoiteGroup.ApplyGroupLayout then
        if frame._lastShowState ~= show then
            frame._lastShowState = show
            if type(DoiteAuras) == "table" and type(DoiteAuras.GetAllCandidates) == "function" then
                _G["DoiteGroup_NeedReflow"] = true
            end
        end
    end
end

function DoiteConditions_RequestEvaluate()
    -- Re-scan icons if anyone still needs the time heartbeat
    if _RebuildAbilityTimeHeartbeatFlag then
        _RebuildAbilityTimeHeartbeatFlag()
    end
    if _RebuildAuraTimeHeartbeatFlag then
        _RebuildAuraTimeHeartbeatFlag()
    end
    if _RebuildAuraUsageFlags then
        _RebuildAuraUsageFlags()
    end
    if _RebuildTargetModsFlags then
        _RebuildTargetModsFlags()
    end
    dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true
end

function DoiteConditions:EvaluateAbilities(doLogic, doTime)
    local editingAny = _IsAnyKeyUnderEdit()
    -- Default behaviour (no args): full logic + time, as before.
    if doLogic == nil and doTime == nil then
        doLogic, doTime = true, true
    else
        if doLogic == nil then doLogic = true end
        if doTime  == nil then doTime  = false end
    end

    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

    local key, data

    -- Fast path: time-heartbeat only (avoid scanning every icon each 0.5s)
    if doLogic == false and doTime == true then
        -- 1) Live keys that actually have time logic
        if live then
            local keys = _timeKeysAbilityItem_live
            if keys then
                local i, n = 1, table.getn(keys)
                while i <= n do
                    key = keys[i]
                    data = key and live[key]
                    if data and (data.type == "Ability" or data.type == "Item") then
                        data.key = key
                        local show, glow, grey
                        if data.type == "Ability" then
                            show, glow, grey = CheckAbilityConditions(data)
                        else
                            show, glow, grey = CheckItemConditions(data)
                        end
                        DoiteConditions:ApplyVisuals(key, show, glow, grey)
                    end
                    i = i + 1
                end
            end
        end

        -- 2) Editor keys (skip any that exist in live, same as original)
        if edit then
            local keys = _timeKeysAbilityItem_edit
            if keys then
                local i, n = 1, table.getn(keys)
                while i <= n do
                    key = keys[i]
                    if key and ((not live) or (not live[key])) then
                        data = edit[key]
                        if data and (data.type == "Ability" or data.type == "Item") then
                            data.key = key
                            local show, glow, grey
                            if data.type == "Ability" then
                                show, glow, grey = CheckAbilityConditions(data)
                            else
                                show, glow, grey = CheckItemConditions(data)
                            end
                            DoiteConditions:ApplyVisuals(key, show, glow, grey)
                        end
                    end
                    i = i + 1
                end
            end
        end

        return
    end

    -- 1) Live icons (runtime set)
    if live then
        for key, data in pairs(live) do
            if data and (data.type == "Ability" or data.type == "Item") then
                -- Decide whether this icon should be touched in this pass
                local wantsTime = false
                if doTime then
                    if data.type == "Ability" then
                        wantsTime = _IconHasTimeLogic_Ability(data)
                    else -- "Item"
                        wantsTime = _IconHasTimeLogic_Item(data)
                    end
                end

                local wantsLogic = doLogic

                if wantsLogic or wantsTime then
                    data.key = key
                    local show, glow, grey
                    if data.type == "Ability" then
                        show, glow, grey = CheckAbilityConditions(data)
                    else
                        show, glow, grey = CheckItemConditions(data)
                    end
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)
                end
            end
        end
    end

    -- 2) Any extra editor-only icons (keys not in live)
    if edit then
        for key, data in pairs(edit) do
            if (not live) or (not live[key]) then
                if data and (data.type == "Ability" or data.type == "Item") then
                    local wantsTime = false
                    if doTime then
                        if data.type == "Ability" then
                            wantsTime = _IconHasTimeLogic_Ability(data)
                        else
                            wantsTime = _IconHasTimeLogic_Item(data)
                        end
                    end

                    local wantsLogic = doLogic

                    if wantsLogic or wantsTime then
                        data.key = key
                        local show, glow, grey
                        if data.type == "Ability" then
                            show, glow, grey = CheckAbilityConditions(data)
                        else
                            show, glow, grey = CheckItemConditions(data)
                        end
                        DoiteConditions:ApplyVisuals(key, show, glow, grey)
                    end
                end
            end
        end
    end
end

function DoiteConditions:EvaluateAuras()
    local editingAny = _IsAnyKeyUnderEdit()
    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

    local key, data

    -- 1) Live icons (runtime set)
    if live then
        for key, data in pairs(live) do
            if type(data) ~= "table" then
                live[key] = nil
            elseif data.type == "Buff" or data.type == "Debuff" then
                data.key = key

                local show, glow, grey = CheckAuraConditions(data)
                DoiteConditions:ApplyVisuals(key, show, glow, grey)
            end
        end
    end

    -- 2) Any extra editor-only icons (keys not in live)
    --    Only bother when at least one key is under edit, same as before.
    if edit and editingAny then
        for key, data in pairs(edit) do
            if (not live) or (not live[key]) then
                if type(data) ~= "table" then
                    edit[key] = nil
                elseif data.type == "Buff" or data.type == "Debuff" then
                    data.key = key

                    local show, glow, grey = CheckAuraConditions(data)
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)
                end
            end
        end
    end
end


-- Small helper: keep warrior Overpower/Revenge proc windows in sync
local function _WarriorProcTick()
    if not _isWarrior then return end
    if _REV_until <= 0 and _OP_until <= 0 then return end

    local nowAbs = GetTime()

    if _REV_until > 0 and nowAbs > _REV_until then
        _REV_until = 0
        dirty_ability = true
    end

    if _OP_until > 0 and nowAbs > _OP_until then
        _OP_until = 0
        dirty_ability = true
    end
end

_G.DoiteConditions_WarriorProcTick = _WarriorProcTick

-- Lightweight pass that ONLY refreshes remaining-time text / stacks.
-- No condition logic, no aura scanning – uses existing cached data.
function DoiteConditions_UpdateTimeText()
    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

    -- Runtime icons (live set)
    if live then
        -- Ability/Item keys with time logic
        do
            local keys = _timeKeysAbilityItem_live
            local i, n = 1, table.getn(keys)
            while i <= n do
                local key = keys[i]
                local data = key and live[key]
                if type(data) == "table" and data.type then
                        local frame = _GetIconFrame(key)
                    if frame and frame.IsShown and frame:IsShown() then
                        local dataTbl =
                            (DoiteDB and DoiteDB.icons and DoiteDB.icons[key])
                            or
                            (DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key])
                        if dataTbl then
                            _Doite_UpdateOverlayForFrame(frame, key, dataTbl, frame._daSliding == true)
                        end
                    end
                end
                i = i + 1
            end
        end

        -- Aura keys with time logic
        do
            local keys = _timeKeysAura_live
            local i, n = 1, table.getn(keys)
            while i <= n do
                local key = keys[i]
                local data = key and live[key]
                if type(data) == "table" and data.type then
                        local frame = _GetIconFrame(key)
                    if frame and frame.IsShown and frame:IsShown() then
                        local dataTbl =
                            (DoiteDB and DoiteDB.icons and DoiteDB.icons[key])
                            or
                            (DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key])
                        if dataTbl then
                            _Doite_UpdateOverlayForFrame(frame, key, dataTbl, frame._daSliding == true)
                        end
                    end
                end
                i = i + 1
            end
        end
    end

    -- Editor-only icons (keys not in live)
    if edit then
        local skipKeys = live or {}

        -- Ability/Item keys with time logic
        do
            local keys = _timeKeysAbilityItem_edit
            local i, n = 1, table.getn(keys)
            while i <= n do
                local key = keys[i]
                if key and (not skipKeys[key]) then
                    local data = edit[key]
                    if type(data) == "table" and data.type then
                        local frame = _GetIconFrame(key)
                        if frame and frame.IsShown and frame:IsShown() then
                            local dataTbl =
                                (DoiteDB and DoiteDB.icons and DoiteDB.icons[key])
                                or
                                (DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key])
                            if dataTbl then
                                _Doite_UpdateOverlayForFrame(frame, key, dataTbl, frame._daSliding == true)
                            end
                        end
                    end
                end
                i = i + 1
            end
        end

        -- Aura keys with time logic
        do
            local keys = _timeKeysAura_edit
            local i, n = 1, table.getn(keys)
            while i <= n do
                local key = keys[i]
                if key and (not skipKeys[key]) then
                    local data = edit[key]
                    if type(data) == "table" and data.type then
                        local frame = _GetIconFrame(key)
                        if frame and frame.IsShown and frame:IsShown() then
                            local dataTbl =
                                (DoiteDB and DoiteDB.icons and DoiteDB.icons[key])
                                or
                                (DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key])
                            if dataTbl then
                                _Doite_UpdateOverlayForFrame(frame, key, dataTbl, frame._daSliding == true)
                            end
                        end
                    end
                end
                i = i + 1
            end
        end
    end
end

local _tick = CreateFrame("Frame", "DoiteConditionsTick")

-- Keep these as globals so the OnUpdate script doesn't capture them as upvalues
_acc        = 0
_textAccum  = 0
_distAccum  = 0
_timeEvalAccum = 0

-- Lift the body into a real function
function DoiteConditions_OnUpdate(dt)
    _acc       = _acc + dt
    _textAccum = _textAccum + dt

    -- 0.5s heartbeat for ability/item time-based logic (cooldown end needs reevaluation).
    _timeEvalAccum = _timeEvalAccum + dt
    if _timeEvalAccum >= 0.5 then
        _timeEvalAccum = 0
        if _hasAnyAbilityTimeLogic then
            dirty_ability_time = true
        end
    end

    -- Keep warrior Overpower/Revenge procs in sync even if no other events fire
    DoiteConditions_WarriorProcTick()

    -- Coalesce aura events: scan/rebuild at most once per frame, before any rendering/eval.
	DoiteConditions:ProcessPendingAuraScans()

    -- Smooth remaining-time text (abilities/items/auras) on a cheap path
    if _textAccum >= 0.1 then
        _textAccum = 0

        if _hasAnyAbilityTimeLogic or _hasAnyAuraTimeLogic then
            DoiteConditions_UpdateTimeText()
        end
    end
	
	-- Lightweight distance heartbeat: keep "In range" / "Melee range" /
    _distAccum = _distAccum + dt
    if _distAccum >= 0.15 then
        _distAccum = 0

        if UnitExists and UnitExists("target") then
            -- Only mark dirty if configs actually use these options
            if _hasAnyTargetMods_Ability then
                dirty_ability = true
            end
            if _hasAnyTargetMods_Aura then
                dirty_aura = true
            end
        end
    end

    -- Render faster while sliding; else ~30fps
    local thresh = (next(DoiteConditions_SlideMgr.active) ~= nil) and 0.03 or 0.10
    if _acc < thresh then return end
    _acc = 0

	local needAbilityLogic = dirty_ability or dirty_power
	local needAbilityTime  = dirty_ability_time
	local needAura         = dirty_aura or dirty_target or dirty_power

    if needAbilityLogic or needAbilityTime then
        _G.DoiteConditions:EvaluateAbilities(needAbilityLogic, needAbilityTime)
    end
    if needAura then
        _G.DoiteConditions:EvaluateAuras()
    end

    if needAbilityLogic or needAbilityTime or needAura then
        dirty_aura, dirty_target, dirty_power = false, false, false
        dirty_ability_time = false
        -- While sliding, ability icons updating each frame
        dirty_ability = next(DoiteConditions_SlideMgr.active) and true or false
    end
end

-- Avoid per-frame pcall (allocation/overhead). Enable it only when debugging.
local function _DoiteConditions_OnUpdateWrapper()
    local dt = arg1 or 0
    if _G["DoiteAuras_DebugPcallOnUpdate"] == true then
        local ok, err = pcall(DoiteConditions_OnUpdate, dt)
        if not ok and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff0000[DoiteAuras] OnUpdate error:|r " .. tostring(err)
            )
        end
    else
        DoiteConditions_OnUpdate(dt)
    end
end

_tick:SetScript("OnUpdate", _DoiteConditions_OnUpdateWrapper)

-- Prime aura snapshot and trigger initial evaluation
DoiteConditions_ScanUnitAuras("player")
if _G.UnitExists and _G.UnitExists("target") then
    DoiteConditions_ScanUnitAuras("target")
end
dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true

---------------------------------------------------------------
-- Event handling + smoother updates
---------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "DoiteConditionsEventFrame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UNIT_MANA")
eventFrame:RegisterEvent("UNIT_ENERGY")
eventFrame:RegisterEvent("UNIT_RAGE")
eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("PLAYER_COMBO_POINTS")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        -- Initial aura scan
        DoiteConditions_ScanUnitAuras("player")
        if _G.UnitExists and _G.UnitExists("target") then
            DoiteConditions_ScanUnitAuras("target")
        end
        dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true

        -- Cache player class for lightweight warrior-specific logic + range overrides
        local _, cls = UnitClass("player")
        cls = cls and string.upper(cls) or ""
        _isWarrior  = (cls == "WARRIOR")
        _playerClass = cls

        -- Prime time-heartbeat flags
        if _RebuildAbilityTimeHeartbeatFlag then
            _RebuildAbilityTimeHeartbeatFlag()
        end
        if _RebuildAuraTimeHeartbeatFlag then
            _RebuildAuraTimeHeartbeatFlag()
        end
        if _RebuildAuraUsageFlags then
            _RebuildAuraUsageFlags()
        end
        if _RebuildTargetModsFlags then
            _RebuildTargetModsFlags()
        end
        if _RefreshPlayerMeleeThreshold then
            _RefreshPlayerMeleeThreshold()
        end

elseif event == "UNIT_AURA" then
		if arg1 == "player" then
			-- Player auras changed: coalesce scan into OnUpdate (once per frame)
			DoiteConditions._pendingAuraScanPlayer = true

			-- Only rebuild per-name timer cache if any aura icon actually uses time logic.
			if _hasAnyAuraTimeLogic then
				DoiteConditions._pendingRebuildPlayerTimers = true
			end

			dirty_aura    = true
			dirty_ability = true

    elseif arg1 == "target" then
        -- Only bother if *any* config ever looks at target auras.
        if _hasAnyTargetAuraUsage then
            -- Coalesce scan/clear into OnUpdate (once per frame)
            DoiteConditions._pendingAuraScanTarget = true
            dirty_aura    = true
            dirty_ability = true
        end
    end

    elseif event == "SPELLS_CHANGED" then
        local cache = _G.DoiteConditions_SpellIndexCache
        if cache then
            for k in pairs(cache) do cache[k] = nil end
        end
        dirty_ability = true

	elseif event == "PLAYER_TARGET_CHANGED" then
			-- If target aura tracking is used anywhere, scan/clear once in OnUpdate. Otherwise, keep snapshot empty so no stale target aura data can ever match.
			if _hasAnyTargetAuraUsage then
				DoiteConditions._pendingAuraScanTarget = true
			else
				local snap = _G.DoiteConditions_AuraSnapshot
				local s = snap and snap.target
				if s then
					for k in pairs(s.buffs) do s.buffs[k] = nil end
					for k in pairs(s.debuffs) do s.debuffs[k] = nil end
				end
			end

			dirty_target, dirty_aura = true, true
			dirty_ability = true

    elseif event == "SPELL_UPDATE_COOLDOWN"
        or event == "UPDATE_SHAPESHIFT_FORM" then

        dirty_ability = true

    elseif event == "UNIT_HEALTH" then
        if arg1 == "player" or arg1 == "target" then
            dirty_ability = true
            dirty_aura    = true
        end

    elseif event == "PLAYER_COMBO_POINTS" then
        dirty_ability = true
        dirty_aura    = true

    elseif event == "UNIT_MANA" or event == "UNIT_RAGE" or event == "UNIT_ENERGY" then
        if arg1 == "player" then
            dirty_power = true
        end

    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        dirty_ability, dirty_aura = true, true

	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if _G.DoiteConditions_ClearTrinketFirstMemory then
			_G.DoiteConditions_ClearTrinketFirstMemory()
		end
		if _InvalidateItemScanCache then
			_InvalidateItemScanCache()
		end
		dirty_ability = true
		dirty_aura    = true

	elseif event == "BAG_UPDATE_COOLDOWN" then
		dirty_ability = true

	elseif event == "BAG_UPDATE" then
		if _InvalidateItemScanCache then
			_InvalidateItemScanCache()
		end
		dirty_ability = true

	elseif event == "UNIT_INVENTORY_CHANGED" then
		if arg1 == "player" then
			if _InvalidateItemScanCache then
				_InvalidateItemScanCache()
			end
			dirty_ability = true
		end
	end
end)
