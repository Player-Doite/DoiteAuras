---------------------------------------------------------------
-- DoiteGroup.lua
-- Handles grouped layout logic for DoiteAuras icons
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

-- Use a global-named table (compatible with older loader behavior)
local DoiteGroup = _G["DoiteGroup"] or {}
_G["DoiteGroup"] = DoiteGroup

---------------------------------------------------------------
-- Helpers
---------------------------------------------------------------
local function num(v, default)
  return tonumber(v) or default or 0
end

-- Fast frame getter (avoid _G["DoiteIcon_"..key] churn in sorting/layout hot paths)
local _GetIconFrame = DoiteAuras_GetIconFrame
if not _GetIconFrame then
  local G = _G
  _GetIconFrame = function(k)
    if not k then
      return nil
    end
    return G["DoiteIcon_" .. k]
  end
end

local function isValidGroupMember(entry)
  if not entry or not entry.data then
    return false
  end
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

-- Resolve fixed layout mode for a group (false by default)
local function GetGroupFixedMode(groupName, leaderData)
  if groupName and DoiteAurasDB and DoiteAurasDB.groupFixed and DoiteAurasDB.groupFixed[groupName] then
    return true
  end
  if leaderData and leaderData.groupFixed == true then
    return true
  end
  return false
end

local function _ClearMap(t)
  if not t then
    return
  end
  for k in pairs(t) do
    t[k] = nil
  end
end

local function _ComputeOffset(baseX, baseY, growth, pad, steps)
  local x = baseX
  local y = baseY
  if steps and steps > 0 then
    if growth == "Horizontal Right" then
      x = x + (pad * steps)
    elseif growth == "Horizontal Left" then
      x = x - (pad * steps)
    elseif growth == "Vertical Up" then
      y = y + (pad * steps)
    elseif growth == "Vertical Down" then
      y = y - (pad * steps)
    else
      x = x + (pad * steps)
    end
  end
  return x, y
end

-- Centered expansion (keeps whole group centered around baseX/baseY)
local function _ComputeCenteredOffset(baseX, baseY, growth, pad, index, totalVisible)
  local x = baseX
  local y = baseY

  if not totalVisible or totalVisible <= 0 then
    return x, y
  end

  if growth == "Centered Horizontal" then
    local halfCount = totalVisible / 2.0
    local offset = (index - 1) - (halfCount - 0.5)
    x = baseX + (offset * pad)

  elseif growth == "Centered Vertical" then
    local halfCount = totalVisible / 2.0
    local offset = (index - 1) - (halfCount - 0.5)
    y = baseY + (offset * pad)
  end

  return x, y
end

local function _ApplyPlacement(entry, x, y, size)
  if not entry then
    return
  end

  local pos = entry._computedPos
  if not pos then
    pos = {}
    entry._computedPos = pos
  end
  pos.x = x
  pos.y = y
  pos.size = size

  local f = _GetIconFrame(entry.key)
  if f then
    f._daBlockedByGroup = false
    -- Do not re-anchor while the slider owns the frame this tick
    if not f._daSliding then
      if f._daGroupX ~= x or f._daGroupY ~= y then
        f._daGroupX = x
        f._daGroupY = y
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", x, y)
      end
    end
    if f._daGroupSize ~= size then
      f._daGroupSize = size
      f:SetWidth(size)
      f:SetHeight(size)
    end
  end
end

-- Current key being edited
local function editingKey()
  return _G["DoiteEdit_CurrentKey"]
end

---------------------------------------------------------------
-- Sort comparators (no per-sort closure allocations)
---------------------------------------------------------------
local _DG = { editKey = nil }

local function _cmpPrio(a, b)
  local editKey = _DG.editKey
  if editKey then
    if a.key == editKey and b.key ~= editKey then
      return true
    end
    if b.key == editKey and a.key ~= editKey then
      return false
    end
  end

  local da = a.data
  local db = b.data
  local oa = (da and da.order) or 999
  local ob = (db and db.order) or 999

  if oa == ob then
    return (a._dgKeyStr or "") < (b._dgKeyStr or "")
  end
  return oa < ob
end

local function _cmpTime(a, b)
  local editKey = _DG.editKey
  if editKey then
    if a.key == editKey and b.key ~= editKey then
      return true
    end
    if b.key == editKey and a.key ~= editKey then
      return false
    end
  end

  local hasA = a._dgHasRem and true or false
  local hasB = b._dgHasRem and true or false

  if hasA ~= hasB then
    return hasA
  end

  if hasA and hasB then
    local ra = a._dgRem
    local rb = b._dgRem
    if ra ~= rb then
      return ra < rb
    end
  end

  -- fallback to prio behaviour
  return _cmpPrio(a, b)
end

---------------------------------------------------------------
-- Compute layout for a single group, driven by the group's leader
---------------------------------------------------------------
local function ComputeGroupLayout(entries, groupName)
  if not entries or table.getn(entries) == 0 then
    return {}
  end

  -- 1) Find leader; bail if none (group misconfigured)
  local leader = nil
  for _, e in ipairs(entries) do
    if e.data and e.data.isLeader then
      leader = e;
      break
    end
  end
  if not leader then
    return {}
  end

  local L = leader.data
  local baseX = num(L.offsetX, 0)
  local baseY = num(L.offsetY, 0)
  local baseSize = num(L.iconSize, 36)
  local growth = L.growth or "Horizontal Right"
  local limit = num(L.numAuras, 50)
  local fixed = GetGroupFixedMode(groupName, L)
  local settings = (DoiteAurasDB and DoiteAurasDB.settings)
  local spacing = num(L.spacing, (settings and settings.spacing) or 8)
  local pad = baseSize + spacing

  local isCentered = (growth == "Centered Horizontal" or growth == "Centered Vertical")

  -- 2) Build pools: known (for fixed slots) and visible-known (for actual placement)
  local fixedKnown
  if fixed then
    fixedKnown = DoiteGroup._tmpAllKnown
    if not fixedKnown then
      fixedKnown = {}
      DoiteGroup._tmpAllKnown = fixedKnown
    else
      for i = table.getn(fixedKnown), 1, -1 do
        fixedKnown[i] = nil
      end
    end
  end

  -- Build the pool of items that are BOTH known and WANT to be shown (conditions OR sliding) - reuse & shrink table without realloc
  local visibleKnown = DoiteGroup._tmpVisibleKnown
  if not visibleKnown then
    visibleKnown = {}
    DoiteGroup._tmpVisibleKnown = visibleKnown
  else
    for i = table.getn(visibleKnown), 1, -1 do
      visibleKnown[i] = nil
    end
  end

  local editKey = editingKey()
  local vn = 0
  local an = 0
  local i, n = 1, table.getn(entries)
  while i <= n do
    local e = entries[i]
    if e and isKnown(e) then
      if fixed and fixedKnown then
        an = an + 1
        fixedKnown[an] = e
      end
      local f = _GetIconFrame(e.key)
      -- Use frame flags; fall back to 'show' from candidates.
      -- Only use IsShown() fallback if frame flags haven't been initialized yet (avoids blocking collapse).
      local wants = (f and (f._daShouldShow == true or f._daSliding == true))
          or (e.show == true)
          or (f and f._daShouldShow == nil and f._daSliding == nil and f:IsShown())

      -- While editing, always include the edited member in the layout pool
      if editKey and e.key == editKey then
        wants = true
      end

      if wants then
        vn = vn + 1
        visibleKnown[vn] = e
      end
    end
    i = i + 1
  end

  -- Nothing visible? Clear any previous assignment and exit
  if vn == 0 then
    local j, m = 1, table.getn(entries)
    while j <= m do
      local e = entries[j]
      if e then
        e._computedPos = nil
      end
      j = j + 1
    end
    return {}
  end

  -- Decide how to sort this group: "prio" (default) or "time"
  local groupSortCache = DoiteGroup._sortCache or {}
  DoiteGroup._sortCache = groupSortCache

  local sortMode = groupSortCache[groupName]
  if not sortMode then
    sortMode = GetGroupSortMode(groupName)
    groupSortCache[groupName] = sortMode
  end

  local sortList = fixed and fixedKnown or visibleKnown

  -- Precompute cheap sort keys once per entry (avoids frame lookups/tostring churn inside comparator)
  local j = 1
  local sn = fixed and an or vn
  while j <= sn do
    local e = sortList[j]
    local k = e.key
    if not e._dgKeyStr then
      if type(k) == "string" then
        e._dgKeyStr = k
      else
        e._dgKeyStr = tostring(k)
      end
    end

    if sortMode == "time" then
      local f = _GetIconFrame(k)
      local r = f and f._daSortRem or nil
      if r and r > 0 then
        e._dgRem = r
        e._dgHasRem = 1
      else
        e._dgRem = nil
        e._dgHasRem = nil
      end
    end

    j = j + 1
  end

  -- 3) Order by saved priority or remaining time, depending on sort mode
  _DG.editKey = editKey
  if sortMode == "time" then
    table.sort(sortList, _cmpTime)
  else
    table.sort(sortList, _cmpPrio)
  end

  -- 4) Assign up to numAuras slots, starting from leader’s baseXY
  local placed = DoiteGroup._tmpPlaced
  if not placed then
    placed = {}
    DoiteGroup._tmpPlaced = placed
  else
    local i = 1
    while placed[i] ~= nil do
      placed[i] = nil
      i = i + 1
    end
  end

  local actualPlaced = limit
  if vn < actualPlaced then
    actualPlaced = vn
  end

  if fixed then
    -- Assign stable slot indices based on the full known list (no map).
    local s = 1
    while s <= an do
      local e = fixedKnown[s]
      if e then
        e._daFixedSlot = s
      end
      s = s + 1
    end

    -- Place visible-known entries into their fixed slots (up to limit).
    local p = 0
    local v = 1
    while v <= vn do
      local e = visibleKnown[v]
      local slot = e and e._daFixedSlot
      if slot and slot <= limit then
        local curX, curY
        if isCentered then
          curX, curY = _ComputeCenteredOffset(baseX, baseY, growth, pad, slot, limit)
        else
          curX, curY = _ComputeOffset(baseX, baseY, growth, pad, slot - 1)
        end

        -- Inline placement so we can respect _daDragging (avoid fighting the drag owner).
        local pos = e._computedPos
        if not pos then
          pos = {}
          e._computedPos = pos
        end
        pos.x = curX
        pos.y = curY
        pos.size = baseSize

        local f = _GetIconFrame(e.key)
        if f then
          f._daBlockedByGroup = false

          -- Do not re-anchor while sliding OR dragging
          if not f._daSliding and not f._daDragging then
            if f._daGroupX ~= curX or f._daGroupY ~= curY then
              f._daGroupX = curX
              f._daGroupY = curY
              f:ClearAllPoints()
              f:SetPoint("CENTER", UIParent, "CENTER", curX, curY)
            end
          end

          if f._daGroupSize ~= baseSize then
            f._daGroupSize = baseSize
            f:SetWidth(baseSize)
            f:SetHeight(baseSize)
          end
        end

        p = p + 1
        placed[p] = e
      end
      v = v + 1
    end

    actualPlaced = p
  else
    if isCentered then
      local p = 1
      while p <= actualPlaced do
        local e = visibleKnown[p]
        local curX, curY = _ComputeCenteredOffset(baseX, baseY, growth, pad, p, actualPlaced)
        _ApplyPlacement(e, curX, curY, baseSize)
        placed[p] = e
        p = p + 1
      end
    else
      local curX, curY = baseX, baseY
      local p = 1
      while p <= actualPlaced do
        local e = visibleKnown[p]

        _ApplyPlacement(e, curX, curY, baseSize)

        placed[p] = e

        if p < actualPlaced then
          curX, curY = _ComputeOffset(baseX, baseY, growth, pad, p)
        end

        p = p + 1
      end
    end
  end

  -- 5) Everything else must not occupy a position (hide if currently shown)
  local placedSet = DoiteGroup._tmpPlacedSet
  if not placedSet then
    placedSet = {}
    DoiteGroup._tmpPlacedSet = placedSet
  else
    for k in pairs(placedSet) do
      placedSet[k] = nil
    end
  end

  local q = 1
  while q <= actualPlaced do
    local e = placed[q]
    placedSet[e.key] = true
    q = q + 1
  end

  local r, m = 1, table.getn(entries)
  while r <= m do
    local e = entries[r]
    if e and not placedSet[e.key] then
      e._computedPos = nil
      local f = _GetIconFrame(e.key)
      if f then
        if editKey and e.key == editKey then
          -- While editing: do not block or force-hide this member
          f._daBlockedByGroup = false
        else
          f._daBlockedByGroup = true
          if f:IsShown() then
            f:Hide()
          end
        end
      end
    end
    r = r + 1
  end

  return placed

end

---------------------------------------------------------------
-- Public: ApplyGroupLayout over all candidates
---------------------------------------------------------------
function DoiteGroup.ApplyGroupLayout(candidates)
  if not candidates or type(candidates) ~= "table" then
    return
  end
  if _G["DoiteGroup_LayoutInProgress"] then
    return
  end
  _G["DoiteGroup_LayoutInProgress"] = true

  -- Normalize core fields (defensive)
  for _, entry in ipairs(candidates) do
    local d = entry.data or {}
    d.offsetX = num(d.offsetX, 0)
    d.offsetY = num(d.offsetY, 0)
    d.iconSize = num(d.iconSize, 36)
    d.order = num(d.order, 999)
  end

  -- 1) Partition by group (reuse tables to avoid combat allocations)
  local groups = DoiteGroup._tmpGroups
  if not groups then
    groups = {}
    DoiteGroup._tmpGroups = groups
  end

  local seen = DoiteGroup._tmpGroupsSeen
  if not seen then
    seen = {}
    DoiteGroup._tmpGroupsSeen = seen
  else
    for k in pairs(seen) do
      seen[k] = nil
    end
  end

  local idx = DoiteGroup._tmpGroupsIdx
  if not idx then
    idx = {}
    DoiteGroup._tmpGroupsIdx = idx
  else
    for k in pairs(idx) do
      idx[k] = nil
    end
  end

  -- Mark membership for the hook (cheap skip for non-group icons)
  for _, e in ipairs(candidates) do
    local f = e and _GetIconFrame(e.key) or nil
    if f then
      if isValidGroupMember(e) then
        f._daInGroup = true
      else
        f._daInGroup = nil
      end
    end

    if isValidGroupMember(e) then
      local g = e.data.group
      local list = groups[g]
      if not list then
        list = {}
        groups[g] = list
      end

      if not seen[g] then
        -- clear list array once per group
        local i = 1
        while list[i] ~= nil do
          list[i] = nil
          i = i + 1
        end
        seen[g] = true
        idx[g] = 0
      end

      local n = (idx[g] or 0) + 1
      idx[g] = n
      list[n] = e
    end
  end

  -- remove groups not present this pass (keeps Published table clean)
  for g in pairs(groups) do
    if not seen[g] then
      groups[g] = nil
    end
  end

  _hasGroups = false
  for gName, list in pairs(groups) do
    ComputeGroupLayout(list, gName)
    _hasGroups = true
  end

  -- Build a cached list of sliding keys (used to run a tiny OnUpdate ONLY while sliding)
  local slideList = DoiteGroup._tmpSlideList
  if not slideList then
    slideList = {}
    DoiteGroup._tmpSlideList = slideList
  else
    local i = 1
    while slideList[i] ~= nil do
      slideList[i] = nil
      i = i + 1
    end
  end

  local sc = 0
  for gName, list in pairs(groups) do
    local i, n = 1, table.getn(list)
    while i <= n do
      local e = list[i]
      if e then
        local f = _GetIconFrame(e.key)
        if f and f._daSliding == true then
          sc = sc + 1
          slideList[sc] = e.key
        end
      end
      i = i + 1
    end
  end
  DoiteGroup._slidingCount = sc

  -- 3) Publish for ApplyVisuals
  _G["DoiteGroup_Computed"] = groups
  _G["DoiteGroup_LayoutInProgress"] = false

  -- If anything is sliding, keep a tiny watcher active; otherwise ensure it's off
  if sc > 0 and DoiteGroup._EnableSlideWatch then
    DoiteGroup._EnableSlideWatch()
  elseif DoiteGroup._DisableSlideWatch then
    DoiteGroup._DisableSlideWatch()
  end
end


-- Event/flag-driven reflow (no periodic scanning)
local _watch = CreateFrame("Frame", "DoiteGroupWatch")

-- Fallback candidate list/pool (only used if DoiteAuras.GetAllCandidates isn't available)
local _fallbackList = {}
local _fallbackPool = {}

local function _clearArray(t)
  local i = 1
  while t[i] ~= nil do
    t[i] = nil
    i = i + 1
  end
end

local function _collectCandidates()
  if type(DoiteAuras) == "table" and type(DoiteAuras.GetAllCandidates) == "function" then
    return DoiteAuras.GetAllCandidates()
  end

  -- Fallback: synthesize from DB (reuse tables)
  local out = _fallbackList
  local pool = _fallbackPool
  _clearArray(out)

  local src = (DoiteDB and DoiteDB.icons) or (DoiteAurasDB and DoiteAurasDB.spells) or {}
  local n = 0
  for k, d in pairs(src) do
    n = n + 1
    local e = pool[n]
    if not e then
      e = {}
      pool[n] = e
    end
    e.key = k
    e.data = d
    out[n] = e
  end
  return out
end

-- Slide-only OnUpdate: no layout work, just "are any of our cached sliding keys still sliding?"
local function _SlideTick()
  local slideList = DoiteGroup._tmpSlideList
  local sc = DoiteGroup._slidingCount or 0
  if not slideList or sc <= 0 then
    _watch:SetScript("OnUpdate", nil)
    return
  end

  local i = 1
  while i <= sc do
    local key = slideList[i]
    local f = _GetIconFrame(key)
    if f and f._daSliding == true then
      i = i + 1
    else
      -- remove from list (swap with last)
      slideList[i] = slideList[sc]
      slideList[sc] = nil
      sc = sc - 1
    end
  end

  DoiteGroup._slidingCount = sc

  -- If no sliding left and no pending reflow, stop ticking.
  if sc <= 0 and _G["DoiteGroup_NeedReflow"] ~= true then
    _watch:SetScript("OnUpdate", nil)
  end
end

-- One-shot reflow runner (scheduled by RequestReflow / hooked visuals)
local function _RunReflowOnce()
  _watch:SetScript("OnUpdate", nil)
  DoiteGroup._reflowQueued = nil

  if _G["DoiteGroup_LayoutInProgress"] then
    -- try again next frame (layout may be mid-flight)
    DoiteGroup._reflowQueued = 1
    _watch:SetScript("OnUpdate", _RunReflowOnce)
    return
  end

  if _G["DoiteGroup_NeedReflow"] ~= true then
    -- If something requested reflow after, queue it.
    if _G["DoiteGroup_NeedReflow"] == true then
      DoiteGroup.RequestReflow()
      return
    end

    -- Nothing requested; if sliding exists, keep slide tick, else off.
    if (DoiteGroup._slidingCount or 0) > 0 then
      _watch:SetScript("OnUpdate", _SlideTick)
    end
    return
  end

  _G["DoiteGroup_NeedReflow"] = nil

  local candidates = _collectCandidates()
  if candidates and table.getn(candidates) > 0 then
    DoiteGroup.ApplyGroupLayout(candidates)
  else
    -- nothing to do; ensure slide watch is off
    DoiteGroup._slidingCount = 0
    _watch:SetScript("OnUpdate", nil)
  end

  -- If something requested another reflow during this run, queue again.
  if _G["DoiteGroup_NeedReflow"] == true and not _G["DoiteGroup_LayoutInProgress"] then
    DoiteGroup.RequestReflow()
    return
  end
end

-- Public API: request a group reflow (preferred over directly setting the global flag)
function DoiteGroup.RequestReflow()
  _G["DoiteGroup_NeedReflow"] = true
  if DoiteGroup._reflowQueued then
    return
  end
  DoiteGroup._reflowQueued = 1
  _watch:SetScript("OnUpdate", _RunReflowOnce)
end

-- Public API: invalidate cached sort mode for a group (call when sort mode changes)
function DoiteGroup.InvalidateSortCache(groupName)
  if DoiteGroup._sortCache then
    if groupName then
      DoiteGroup._sortCache[groupName] = nil
    else
      -- Clear entire cache if no group specified
      for k in pairs(DoiteGroup._sortCache) do
        DoiteGroup._sortCache[k] = nil
      end
    end
  end
end

-- Internal helpers called by ApplyGroupLayout (Patch 1/2)
function DoiteGroup._EnableSlideWatch()
  if (DoiteGroup._slidingCount or 0) > 0 then
    _watch:SetScript("OnUpdate", _SlideTick)
  end
end

function DoiteGroup._DisableSlideWatch()
  if _G["DoiteGroup_NeedReflow"] ~= true then
    _watch:SetScript("OnUpdate", nil)
  end
end

---------------------------------------------------------------
-- Hook visuals to automatically request reflow when the real-name
-- flags change for any key (shouldShow / sliding)
-- (No assumptions: only hooks if the table+function exist.)
---------------------------------------------------------------
local function _IsKeyGrouped(key)
  local d
  if DoiteDB and DoiteDB.icons then
    d = DoiteDB.icons[key]
  end
  if not d and DoiteAurasDB and DoiteAurasDB.spells then
    d = DoiteAurasDB.spells[key]
  end
  local g = d and d.group
  return g and g ~= "" and g ~= "no"
end

local function _HookApplyVisualsIfPresent()
  if DoiteGroup._applyVisualsHooked then
    return
  end
  if type(DoiteConditions) ~= "table" then
    return
  end
  if type(DoiteConditions.ApplyVisuals) ~= "function" then
    return
  end

  local orig = DoiteConditions.ApplyVisuals

  DoiteConditions.ApplyVisuals = function(a, b, c, d, e)
    -- Supports both call styles:
    --   DoiteConditions:ApplyVisuals(key, show, glow, grey)
    --   DoiteConditions.ApplyVisuals(key, show, glow, grey)
    local self, key, show, glow, grey
    if type(a) == "table" then
      self = a
      key = b
      show = c
      glow = d
      grey = e
    else
      self = DoiteConditions
      key = a
      show = b
      glow = c
      grey = d
    end

    local f = _GetIconFrame(key)

    -- Fast skip: only track grouped keys (works even before first ApplyGroupLayout)
    if not _IsKeyGrouped(key) then
      return orig(self, key, show, glow, grey)
    end

    -- Normalize nil/false so first-time values don't cause "fake changes"
    local oldShould = (f and f._daShouldShow == true) and 1 or 0
    local oldSliding = (f and f._daSliding == true) and 1 or 0

    local r = orig(self, key, show, glow, grey)

    f = _GetIconFrame(key)
    if f then
      local newShould = (f._daShouldShow == true) and 1 or 0
      local newSliding = (f._daSliding == true) and 1 or 0
      if oldShould ~= newShould or oldSliding ~= newSliding then
        DoiteGroup.RequestReflow()
      end
    end

    return r
  end
  DoiteGroup.RequestReflow()
  DoiteGroup._applyVisualsHooked = true
end

-- Attempt hook now, and again on login/addon load (covers load order)
_HookApplyVisualsIfPresent()
_watch:RegisterEvent("PLAYER_LOGIN")
_watch:RegisterEvent("ADDON_LOADED")
_watch:SetScript("OnEvent", function()
  _HookApplyVisualsIfPresent()
end)
