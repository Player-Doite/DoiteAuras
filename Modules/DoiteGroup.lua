-- DoiteGroup.lua
-- Handles grouped layout logic for DoiteAuras icons
-- Turtle WoW 1.12 / Lua 5.0

-- Use a global-named table (compatible with older loader behavior)
local DoiteGroup = _G["DoiteGroup"] or {}
_G["DoiteGroup"] = DoiteGroup

---------------------------------------------------------------
-- Helpers
---------------------------------------------------------------
local function num(v, default) return tonumber(v) or default or 0 end

local function isValidGroupMember(entry)
    if not entry or not entry.data then return false end
    local g = entry.data.group
    return g and g ~= "" and g ~= "no"
end

local function isKnown(entry)
    -- Abilities might be unknown in another spec; never occupy a slot then
    return not (entry and entry.data and entry.data.isUnknown)
end

-- Resolve sort mode for a group: "prio" (default) or "time"
local function GetGroupSortMode(groupName)
    if not groupName then
        return "prio"
    end

    local db = DoiteAurasDB
    if db and db.groupSort and db.groupSort[groupName] then
        local mode = db.groupSort[groupName]
        if mode == "time" then
            return "time"
        end
    end

    return "prio"
end

-- Current key being edited (published by DoiteEdit.lua)
local function editingKey()
    return _G["DoiteEdit_CurrentKey"]
end

---------------------------------------------------------------
-- Compute layout for a single group, driven by the group's leader
---------------------------------------------------------------
local function ComputeGroupLayout(entries, groupName)
    if not entries or table.getn(entries) == 0 then return {} end

    -- 1) Find leader; bail if none (group misconfigured)
    local leader = nil
    for _, e in ipairs(entries) do
        if e.data and e.data.isLeader then leader = e; break end
    end
    if not leader then return {} end

    local L = leader.data
    local baseX    = num(L.offsetX, 0)
    local baseY    = num(L.offsetY, 0)
    local baseSize = num(L.iconSize, 36)
    local growth   = L.growth or "Horizontal Right"
    local limit    = num(L.numAuras, 5)
    local spacing  = (DoiteAurasDB and DoiteAurasDB.settings and DoiteAurasDB.settings.spacing) or 8
    local pad      = baseSize + spacing

	-- 2) Build the pool of items that are BOTH known and WANT to be shown (conditions OR sliding)
    local visibleKnown = {}
	local editKey = editingKey()
	for _, e in ipairs(entries) do
		if isKnown(e) then
			local f = _G["DoiteIcon_" .. e.key]
			-- Use frame flags; fall back to 'show'; finally fall back to "currently visible" to avoid races
			local wants = (f and (f._daShouldShow == true or f._daSliding == true))
					   or (e.show == true)
					   or (f and f:IsShown() == 1)

			-- While editing, always include the edited member in the layout pool
			if editKey and e.key == editKey then
				wants = true
			end

			if wants then
				table.insert(visibleKnown, e)
			end
		end
	end



    -- Nothing visible? Clear any previous assignment and exit
    if table.getn(visibleKnown) == 0 then
        for _, e in ipairs(entries) do e._computedPos = nil end
        return {}
    end

    -- Decide how to sort this group: "prio" (default) or "time"
    local sortMode = GetGroupSortMode(groupName)

    -- 3) Order by saved priority or remaining time, depending on sort mode
    table.sort(visibleKnown, function(a, b)
        -- Put the edited member first (if present)
        if editKey then
            if a.key == editKey and b.key ~= editKey then return true end
            if b.key == editKey and a.key ~= editKey then return false end
        end

        local da = a.data or {}
        local db = b.data or {}
        local oa = num(da.order, 999)
        local ob = num(db.order, 999)

        -- Time-based sort: timed icons (with remaining time) first, then by lowest remaining
        if sortMode == "time" then
            local fa = _G["DoiteIcon_" .. a.key]
            local fb = _G["DoiteIcon_" .. b.key]

            local ra = fa and fa._daSortRem or nil
            local rb = fb and fb._daSortRem or nil

            if ra and ra <= 0 then ra = nil end
            if rb and rb <= 0 then rb = nil end

            local hasA = ra and true or false
            local hasB = rb and true or false

            -- Timed entries come before non-timed entries
            if hasA ~= hasB then
                return hasA
            end

            -- Both timed: lower remaining time first
            if hasA and hasB and ra ~= rb then
                return ra < rb
            end
        end

        -- Default / fallback: priority by order, then key (unchanged behaviour)
        if oa == ob then
            return (tostring(a.key) < tostring(b.key))
        end
        return oa < ob
    end)

    -- 4) Assign up to numAuras slots, starting from leader’s baseXY
    local placed = {}
    local curX, curY = baseX, baseY

    local actualPlaced = math.min(limit, table.getn(visibleKnown))
    for i = 1, actualPlaced do
        local e = visibleKnown[i]
        e._computedPos = { x = curX, y = curY, size = baseSize }
        local f = _G["DoiteIcon_" .. e.key]
        if f then
            f._daBlockedByGroup = false
            -- Do not re-anchor while the slider owns the frame this tick
            if not f._daSliding then
                f:ClearAllPoints()
                f:SetPoint("CENTER", UIParent, "CENTER", curX, curY)
            end
            f:SetWidth(baseSize)
            f:SetHeight(baseSize)
        end
        table.insert(placed, e)

        if i < actualPlaced then
            if     growth == "Horizontal Right" then curX = curX + pad
            elseif growth == "Horizontal Left"  then curX = curX - pad
            elseif growth == "Vertical Up"      then curY = curY + pad
            elseif growth == "Vertical Down"    then curY = curY - pad
            else  curX = curX + pad
            end
        end
    end

    -- 5) Everything else must not occupy a position (hide if currently shown)
    local placedSet = {}
    for _, e in ipairs(placed) do placedSet[e.key] = true end

    for _, e in ipairs(entries) do
		if not placedSet[e.key] then
			e._computedPos = nil
			local f = _G["DoiteIcon_" .. e.key]
			if f then
				if editKey and e.key == editKey then
					-- While editing: do not block or force-hide this member
					f._daBlockedByGroup = false
				else
					f._daBlockedByGroup = true   -- mark as over the group limit
					if f:IsShown() then
						f:Hide()
					end
				end
			end
		end
	end



    return placed
end

---------------------------------------------------------------
-- Public: ApplyGroupLayout over all candidates
---------------------------------------------------------------
function DoiteGroup.ApplyGroupLayout(candidates)
    if not candidates or type(candidates) ~= "table" then return end
    if _G["DoiteGroup_LayoutInProgress"] then return end
    _G["DoiteGroup_LayoutInProgress"] = true

    -- Normalize core fields (defensive)
    for _, entry in ipairs(candidates) do
        local d = entry.data or {}
        d.offsetX  = num(d.offsetX, 0)
        d.offsetY  = num(d.offsetY, 0)
        d.iconSize = num(d.iconSize, 36)
        d.order    = num(d.order, 999)
    end

    -- 1) Partition by group
    local groups = {}
    for _, e in ipairs(candidates) do
        if isValidGroupMember(e) then
            local g = e.data.group
            groups[g] = groups[g] or {}
            table.insert(groups[g], e)
        end
    end

    _hasGroups = false
	for gName, list in pairs(groups) do
		ComputeGroupLayout(list, gName)
		_hasGroups = true
	end

    -- 3) Publish for ApplyVisuals
    _G["DoiteGroup_Computed"] = groups
    _G["DoiteGroup_LayoutInProgress"] = false
end

---------------------------------------------------------------
-- Lightweight watcher: detects changes in shown/order and reflows
---------------------------------------------------------------
-- We recompute only when the group “signature” changes.
local _watch = CreateFrame("Frame")
local _acc   = 0
local _lastSig = {}
local _hasGroups = false

local function _collectCandidates()
    if type(DoiteAuras) == "table" and type(DoiteAuras.GetAllCandidates) == "function" then
        return DoiteAuras.GetAllCandidates()
    end
    -- Fallback: synthesize from DB
    local out = {}
    local src = (DoiteDB and DoiteDB.icons) or (DoiteAurasDB and DoiteAurasDB.spells) or {}
    for k, d in pairs(src) do
        table.insert(out, { key = k, data = d })
    end
    return out
end

local function _buildSignatures(candidates)
    local perGroup = {}
    local editKey = editingKey()

    for _, e in ipairs(candidates) do
        if isValidGroupMember(e) then
            local g = e.data.group
            perGroup[g] = perGroup[g] or {}
            local f = _G["DoiteIcon_" .. e.key]

            local wants
            if editKey and e.key == editKey then
                -- While editing, treat the member as present regardless of condition flips
                wants = "1"
            else
                wants = (f and ((f._daShouldShow == true) or (f._daSliding == true))) and "1" or "0"
            end

            -- Keep the edited key stable at the front by using a very low "order" in the signature
            local ord
            if editKey and e.key == editKey then
                ord = "000"
            else
                ord = string.format("%03d", num(e.data.order, 999))
            end

            table.insert(perGroup[g], e.key .. ":" .. wants .. ":" .. ord)
        end
    end

    for g, arr in pairs(perGroup) do
        table.sort(arr)
        perGroup[g] = table.concat(arr, ",")
    end

    return perGroup
end

_watch:SetScript("OnUpdate", function()
    _acc = _acc + (arg1 or 0)
    if _acc < 0.2 then return end
    _acc = 0

    local needFlag = _G["DoiteGroup_NeedReflow"] == true

    local candidates = _collectCandidates()
    if not candidates or table.getn(candidates) == 0 then
        _G["DoiteGroup_NeedReflow"] = nil
        return
    end

    -- quick skip if no grouped members (unless forced by flag)
    local hasAnyGroup = false
    if not needFlag then
        for _, e in ipairs(candidates) do
            if isValidGroupMember(e) then hasAnyGroup = true; break end
        end
        if not hasAnyGroup then return end
    end

    local changed = false
    if not needFlag then
        local sigs = _buildSignatures(candidates)
        for g, sig in pairs(sigs) do
            if _lastSig[g] ~= sig then
                _lastSig[g] = sig
                changed = true
            end
        end
        for g, _ in pairs(_lastSig) do
            if not sigs[g] then
                _lastSig[g] = nil
                changed = true
            end
        end
    end

    if (changed or needFlag) and not _G["DoiteGroup_LayoutInProgress"] then
        _G["DoiteGroup_NeedReflow"] = nil
        DoiteGroup.ApplyGroupLayout(candidates)
    end
end)
