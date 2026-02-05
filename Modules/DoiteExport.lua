---------------------------------------------------------------
-- DoiteExport.lua
-- Import/Export UI for DoiteAuras
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

DoiteExport = DoiteExport or {}

-- Local string/math helpers for compression/encoding
local strsub = string.sub
local strlen = string.len
local strchar = string.char
local gsub = string.gsub
local mod = math.mod or math.fmod

-- ========= LZW compression / decompression (pfUI-style) =========
local function DE_Compress(input)
  -- based on Rochet2's lzw compression
  if type(input) ~= "string" then
    return nil
  end
  local len = strlen(input)
  if len <= 1 then
    return "u" .. input
  end

  local dict = {}
  local i
  for i = 0, 255 do
    local ic, iic = strchar(i), strchar(i, 0)
    dict[ic] = iic
  end

  local a, b = 0, 1

  local result = { "c" }
  local resultlen = 1
  local n = 2
  local word = ""

  for i = 1, len do
    local c = strsub(input, i, i)
    local wc = word .. c
    if not dict[wc] then
      local write = dict[word]
      if not write then
        return nil
      end
      result[n] = write
      resultlen = resultlen + strlen(write)
      n = n + 1

      -- if compressed data is not getting smaller, bail out
      if len <= resultlen then
        return "u" .. input
      end

      local str = wc
      if a >= 256 then
        a, b = 0, b + 1
        if b >= 256 then
          dict = {}
          b = 1
        end
      end
      dict[str] = strchar(a, b)
      a = a + 1
      word = c
    else
      word = wc
    end
  end

  result[n] = dict[word]
  resultlen = resultlen + strlen(result[n])
  n = n + 1

  if len <= resultlen then
    return "u" .. input
  end

  return table.concat(result)
end

local function DE_Decompress(input)
  -- based on Rochet2's lzw compression
  if type(input) ~= "string" or strlen(input) < 1 then
    return nil
  end

  local control = strsub(input, 1, 1)
  if control == "u" then
    return strsub(input, 2)
  elseif control ~= "c" then
    return nil
  end

  input = strsub(input, 2)
  local len = strlen(input)
  if len < 2 then
    return nil
  end

  local dict = {}
  local i
  for i = 0, 255 do
    local ic, iic = strchar(i), strchar(i, 0)
    dict[iic] = ic
  end

  local a, b = 0, 1
  local result = {}
  local n = 1

  local last = strsub(input, 1, 2)
  result[n] = dict[last]
  n = n + 1

  for i = 3, len, 2 do
    local code = strsub(input, i, i + 1)
    local lastStr = dict[last]
    if not lastStr then
      return nil
    end

    local toAdd = dict[code]
    if toAdd then
      result[n] = toAdd
      n = n + 1
      local str = lastStr .. strsub(toAdd, 1, 1)
      if a >= 256 then
        a, b = 0, b + 1
        if b >= 256 then
          dict = {}
          b = 1
        end
      end
      dict[strchar(a, b)] = str
      a = a + 1
    else
      local str = lastStr .. strsub(lastStr, 1, 1)
      result[n] = str
      n = n + 1
      if a >= 256 then
        a, b = 0, b + 1
        if b >= 256 then
          dict = {}
          b = 1
        end
      end
      dict[strchar(a, b)] = str
      a = a + 1
    end

    last = code
  end

  return table.concat(result)
end

-- ========= Base64 encode / decode (pfUI-style) =========

local function DE_Encode(to_encode)
  local index_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local bit_pattern = ""
  local encoded = ""
  local trailing = ""

  local i
  for i = 1, strlen(to_encode) do
    local remaining = tonumber(string.byte(strsub(to_encode, i, i)))
    local bin_bits = ""
    local j
    for j = 7, 0, -1 do
      local current_power = math.pow(2, j)
      if remaining >= current_power then
        bin_bits = bin_bits .. "1"
        remaining = remaining - current_power
      else
        bin_bits = bin_bits .. "0"
      end
    end
    bit_pattern = bit_pattern .. bin_bits
  end

  if mod(strlen(bit_pattern), 3) == 2 then
    trailing = "=="
    bit_pattern = bit_pattern .. "0000000000000000"
  elseif mod(strlen(bit_pattern), 3) == 1 then
    trailing = "="
    bit_pattern = bit_pattern .. "00000000"
  end

  local i2
  for i2 = 1, strlen(bit_pattern), 6 do
    local byte = strsub(bit_pattern, i2, i2 + 5)
    local offset = tonumber(byte, 2)
    encoded = encoded .. strsub(index_table, offset + 1, offset + 1)
  end

  return strsub(encoded, 1, -1 - strlen(trailing)) .. trailing
end

local function DE_Decode(to_decode)
  local index_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local padded = gsub(to_decode, "%s", "")
  local unpadded = gsub(padded, "=", "")
  local bit_pattern = ""
  local decoded = ""

  to_decode = gsub(to_decode, "\n", "")
  to_decode = gsub(to_decode, " ", "")

  local i
  for i = 1, strlen(unpadded) do
    local char = strsub(to_decode, i, i)
    local offset = string.find(index_table, char)
    if not offset then
      return nil
    end

    local remaining = offset - 1
    local bin_bits = ""
    local j
    for j = 7, 0, -1 do
      local current_power = math.pow(2, j)
      if remaining >= current_power then
        bin_bits = bin_bits .. "1"
        remaining = remaining - current_power
      else
        bin_bits = bin_bits .. "0"
      end
    end

    bit_pattern = bit_pattern .. strsub(bin_bits, 3)
  end

  local i2
  for i2 = 1, strlen(bit_pattern), 8 do
    local byte = strsub(bit_pattern, i2, i2 + 7)
    decoded = decoded .. strchar(tonumber(byte, 2))
  end

  local padding_length = strlen(padded) - strlen(unpadded)
  if padding_length == 1 or padding_length == 2 then
    decoded = strsub(decoded, 1, -2)
  end

  return decoded
end

-- Wrap/unwrap helper for export bodies
local function DE_EncodeCompressed(body)
  local c = DE_Compress(body)
  if not c then
    return nil
  end
  return DE_Encode(c)
end

local function DE_DecodeCompressed(encoded)
  local d = DE_Decode(encoded)
  if not d then
    return nil
  end
  return DE_Decompress(d)
end

local exportFrame, importFrame
local exportEditBox, exportScrollFrame
local importEditBox, importScrollFrame
local exportRows = {}
local allRow = nil

-- ========= Helpers over DoiteAurasDB =========

local function DE_GetSpells()
  DoiteAurasDB = DoiteAurasDB or {}
  DoiteAurasDB.spells = DoiteAurasDB.spells or {}
  return DoiteAurasDB.spells
end

local function DE_GetOrderedSpells()
  local spells = DE_GetSpells()
  local list = {}
  local key, data
  for key, data in pairs(spells) do
    table.insert(list, {
      key = key,
      data = data,
      order = (data and data.order) or 999
    })
  end
  table.sort(list, function(a, b)
    return a.order < b.order
  end)
  return list
end

local function DE_HasGroupOrCategory()
  local spells = DE_GetSpells()
  local _, d
  for _, d in pairs(spells) do
    if d then
      if d.group and d.group ~= "" and d.group ~= "no" then
        return true
      end
      if d.category and d.category ~= "" and d.category ~= "no" then
        return true
      end
    end
  end
  return false
end

-- ========= Export/Import Data Helpers =========
-- Deep copy of a table
local function DE_DeepCopy(src, seen)
  if type(src) ~= "table" then
    return src
  end
  if not seen then
    seen = {}
  elseif seen[src] then
    return seen[src]
  end

  local dst = {}
  seen[src] = dst

  local k, v
  for k, v in pairs(src) do
    if v ~= nil then
      dst[DE_DeepCopy(k, seen)] = DE_DeepCopy(v, seen)
    end
  end
  return dst
end

-- Find a free name by appending " (2)", " (3)", ...
local function DE_FindFreeName(base, existing)
  if not base or base == "" then
    base = "Imported"
  end
  if not existing[base] then
    return base
  end
  local n = 2
  while true do
    local cand = base .. " (" .. n .. ")"
    if not existing[cand] then
      return cand
    end
    n = n + 1
  end
end

-- Build a package table from a list of spell keys.
local function DE_BuildExportPackage(keys, context)
  if not DoiteAurasDB or not DoiteAurasDB.spells or not keys then
    return nil
  end

  -- Minimal structure: only what import actually uses.
  local pkg = {
    icons = {},
    groups = {},
    categories = {},
  }

  local spells = DoiteAurasDB.spells
  local groupSort = DoiteAurasDB.groupSort or {}
  local bucketDisabled = DoiteAurasDB.bucketDisabled or {}
  local cats = DoiteAurasDB.categories or {}

  local usedGroups = {}
  local usedCats = {}

  local keepGroups = nil
  local exportAll = false

  if type(context) == "table" then
    keepGroups = context.groupsToPreserve
    exportAll = context.exportAll and true or false
  elseif type(context) == "boolean" then
    exportAll = context
  end

  -- icons
  local i
  for i = 1, table.getn(keys) do
    local key = keys[i]
    local data = spells[key]
    if data then
      local copy = DE_DeepCopy(data)

      -- ensure exported 'key' field reflects original DB key
      copy.key = key

      -- Decide whether this icon should keep its group
      local grp = copy.group
      if not exportAll and grp and grp ~= "" and grp ~= "no" then
        if not (keepGroups and keepGroups[grp]) then
          -- icon is being exported standalone: strip its group
          copy.group = nil
          grp = nil
        end
      end

      local rec = {
        key = key,
        data = copy,
      }
      table.insert(pkg.icons, rec)

      if grp and grp ~= "" and grp ~= "no" then
        usedGroups[grp] = true
      end
      if copy.category and copy.category ~= "" and copy.category ~= "no" then
        usedCats[copy.category] = true
      end
    end
  end

  -- groups meta (only for those actually used after group stripping)
  local g
  for g in pairs(usedGroups) do
    pkg.groups[g] = {
      sort = groupSort[g] or "prio",
      disabled = bucketDisabled[g] and true or false,
    }
  end

  -- categories meta
  local c
  for c in pairs(usedCats) do
    pkg.categories[c] = {
      disabled = bucketDisabled[c] and true or false,
    }
  end

  return pkg
end

-- Serialize a Lua value to a compact Lua literal.
local function DE_SerializeValue(v, buf)
  local t = type(v)
  if t == "number" then
    table.insert(buf, tostring(v))
  elseif t == "boolean" then
    if v then
      table.insert(buf, "true")
    else
      table.insert(buf, "false")
    end
  elseif t == "string" then
    local s = v
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "\r", "\\r")
    table.insert(buf, "\"")
    table.insert(buf, s)
    table.insert(buf, "\"")
  elseif t == "table" then
    table.insert(buf, "{")
    local first = true
    local k, vv
    for k, vv in pairs(v) do
      if not first then
        table.insert(buf, ",")
      end
      first = false

      local kt = type(k)
      if kt == "string" and string.find(k, "^[A-Za-z_][A-Za-z0-9_]*$") then
        table.insert(buf, k)
        table.insert(buf, "=")
      else
        table.insert(buf, "[")
        DE_SerializeValue(k, buf)
        table.insert(buf, "]=")
      end

      DE_SerializeValue(vv, buf)
    end
    table.insert(buf, "}")
  else
    table.insert(buf, "nil")
  end
end

local function DE_SerializeExport(pkg)
  if not pkg then
    return nil
  end

  local buf = {}
  table.insert(buf, "return")
  DE_SerializeValue(pkg, buf)
  local body = table.concat(buf, "")

  -- Try compressed+base64 (DA2)
  local encoded = DE_EncodeCompressed(body)
  if encoded then
    -- Use DA2 ONLY if it's actually shorter than DA1 overall
    if strlen(encoded) + 4 < strlen(body) + 4 then
      -- +4 for "DAx:"
      return "DA2:" .. encoded
    end
  end

  -- Otherwise stick to plain DA1
  return "DA1:" .. body
end

-- Parse a DA1 export string back into a package table.
local function DE_ParseExportString(str)
  if not str or str == "" then
    return nil, "empty"
  end

  local prefix1 = "DA1:"
  local prefix2 = "DA2:"

  local body

  if strsub(str, 1, strlen(prefix2)) == prefix2 then
    -- compressed+encoded format
    local encoded = strsub(str, strlen(prefix2) + 1)
    local decoded = DE_DecodeCompressed(encoded)
    if not decoded then
      return nil, "decode_error"
    end
    body = decoded
  elseif strsub(str, 1, strlen(prefix1)) == prefix1 then
    -- Old plain-Lua format
    body = strsub(str, strlen(prefix1) + 1)
  else
    return nil, "bad_prefix"
  end

  local fn, err = loadstring(body)
  if not fn then
    return nil, "load_error: " .. tostring(err)
  end

  local ok, pkg = pcall(fn)
  if not ok then
    return nil, "eval_error: " .. tostring(pkg)
  end

  if type(pkg) ~= "table" then
    return nil, "bad_format"
  end

  return pkg, nil
end

-- Import a package table into DoiteAurasDB (groups, categories, spells).
local function DE_ImportPackage(pkg)
  if not pkg or type(pkg) ~= "table" then
    return nil, "no_package"
  end

  DoiteAurasDB = DoiteAurasDB or {}
  DoiteAurasDB.spells = DoiteAurasDB.spells or {}
  DoiteAurasDB.categories = DoiteAurasDB.categories or {}
  DoiteAurasDB.groupSort = DoiteAurasDB.groupSort or {}
  DoiteAurasDB.bucketDisabled = DoiteAurasDB.bucketDisabled or {}

  local spells = DoiteAurasDB.spells
  local categoriesList = DoiteAurasDB.categories
  local groupSort = DoiteAurasDB.groupSort
  local bucketDisabled = DoiteAurasDB.bucketDisabled

  -- existing category names
  local existingCats = {}
  local i
  for i = 1, table.getn(categoriesList) do
    local name = categoriesList[i]
    if name and name ~= "" then
      existingCats[name] = true
    end
  end

  -- existing group names
  local existingGroups = {}

  local k, d
  for k, d in pairs(spells) do
    if type(d) == "table" and d.group and d.group ~= "" and d.group ~= "no" then
      existingGroups[d.group] = true
    end
  end
  for k in pairs(groupSort) do
    existingGroups[k] = true
  end
  local name
  for name in pairs(bucketDisabled) do
    if not existingCats[name] then
      existingGroups[name] = true
    end
  end

  -- Track which groups/categories are newly imported and how many icons in each
  local createdGroups = {}
  local createdCategories = {}

  -- category remap
  local categoryMap = {}
  if pkg.categories then
    for name, info in pairs(pkg.categories) do
      local newName = DE_FindFreeName(name, existingCats)
      categoryMap[name] = newName
      existingCats[newName] = true

      createdCategories[newName] = true

      local found = false
      for i = 1, table.getn(categoriesList) do
        if categoriesList[i] == newName then
          found = true
          break
        end
      end
      if not found then
        table.insert(categoriesList, newName)
      end

      if info and info.disabled then
        bucketDisabled[newName] = true
      end
    end
  end

  -- group remap
  local groupMap = {}
  if pkg.groups then
    local g, info
    for g, info in pairs(pkg.groups) do
      local newName = DE_FindFreeName(g, existingGroups)
      groupMap[g] = newName
      existingGroups[newName] = true

      createdGroups[newName] = true

      if not groupSort[newName] then
        if info and info.sort then
          groupSort[newName] = info.sort
        else
          groupSort[newName] = "prio"
        end
      end

      if info and info.disabled then
        bucketDisabled[newName] = true
      end
    end
  end

  -- helper for new spell keys
  local function pickNewKey(base)
    if not base or base == "" then
      base = "Imported"
    end
    local key = base
    local idx = 2
    while spells[key] do
      key = base .. "#" .. idx
      idx = idx + 1
    end
    return key
  end

  -- import icons
  local imported = {}
  local icons = pkg.icons or {}
  local nImported = 0

  local groupCounts = {}
  local catCounts = {}

  local idx
  for idx = 1, table.getn(icons) do
    local rec = icons[idx]
    if rec and rec.data then
      local data = DE_DeepCopy(rec.data)

      -- remap category
      if data.category and data.category ~= "" and data.category ~= "no" then
        local oldCat = data.category
        local newCat = categoryMap[oldCat] or oldCat
        data.category = newCat
      end

      -- remap group
      if data.group and data.group ~= "" and data.group ~= "no" then
        local oldGrp = data.group
        local newGrp = groupMap[oldGrp] or oldGrp
        data.group = newGrp
      end

      -- count icons per newly created group/category
      if data.group and data.group ~= "" and createdGroups[data.group] then
        groupCounts[data.group] = (groupCounts[data.group] or 0) + 1
      end
      if data.category and data.category ~= "" and createdCategories[data.category] then
        catCounts[data.category] = (catCounts[data.category] or 0) + 1
      end

      local baseKey = data.key or rec.key or data.baseKey
      if not baseKey or baseKey == "" then
        baseKey = (data.displayName or data.name or "Imported")
      end
      local newKey = pickNewKey(baseKey)

      data.key = newKey
      -- do not modify data.baseKey; keep whatever was exported

      spells[newKey] = data
      table.insert(imported, newKey)
      nImported = nImported + 1
    end
  end

  return {
    count = nImported,
    keys = imported,
    groups = groupCounts,
    categories = catCounts,
  }, nil
end

-- One-shot import from raw string.
local function DE_ImportFromString(str)
  local pkg, err = DE_ParseExportString(str)
  if not pkg then
    return nil, err
  end
  return DE_ImportPackage(pkg)
end

-- ========= Frame "top-most" helper =========

local function DE_MakeTopMost(frame)
  if not frame then
    return
  end
  frame:SetFrameStrata("TOOLTIP")
end

-- ========= Export list UI helpers =========

local function DE_ClearRows()
  local _, row
  for _, row in ipairs(exportRows) do
    if row.frame and row.frame.Hide then
      row.frame:Hide()
    end
  end
  exportRows = {}
  allRow = nil
end

-- Will be set later when export frame exists
local function DE_UpdateCopyButton()
  if not exportFrame or not exportFrame.copyBtn or not exportEditBox then
    return
  end
  local txt = exportEditBox:GetText() or ""
  if txt == "" then
    exportFrame.copyBtn:Disable()
  else
    exportFrame.copyBtn:Enable()
  end
end

-- indent: pixels to indent the checkbox (0 for headers, >0 for child/icon rows)
local function DE_CreateRow(parent, y, labelText, kind, id, indent)
  local row = {}

  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(260)
  f:SetHeight(20)
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)

  local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  cb:SetWidth(18);
  cb:SetHeight(18)
  local off = indent or 0
  cb:SetPoint("LEFT", f, "LEFT", off, 0)

  local txt = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  txt:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  txt:SetText(labelText or "")

  row.frame = f
  row.check = cb
  row.text = txt
  row.kind = kind      -- "all", "group", "category", "ungrouped", "icon"
  row.id = id        -- groupName / categoryName / "Ungrouped" / icon key
  row.children = nil    -- filled for group/category/ungrouped headers
  row.parentRow = nil   -- filled for icon rows

  table.insert(exportRows, row)
  return row
end

-- Enable/disable everything except the ALL row
local function DE_SetRowsDisabledExceptAll(disabled)
  local _, row
  for _, row in ipairs(exportRows) do
    if row.kind ~= "all" and row.check then
      if disabled then
        -- Auto-check, then disable, and grey out text
        row.check:SetChecked(true)
        row.check:Disable()
        if row.text and row.text.SetTextColor then
          row.text:SetTextColor(0.5, 0.5, 0.5)
        end
        -- If this is a header with children, also tick + disable children
        if row.children then
          local _, child
          for _, child in ipairs(row.children) do
            if child.check then
              child.check:SetChecked(true)
              child.check:Disable()
            end
            if child.text and child.text.SetTextColor then
              child.text:SetTextColor(0.5, 0.5, 0.5)
            end
          end
        end
      else
        -- Re-enable; keep their checked state as-is
        row.check:Enable()
        if row.text and row.text.SetTextColor then
          row.text:SetTextColor(1, 1, 1)
        end
        if row.children then
          local _, child
          for _, child in ipairs(row.children) do
            if child.check then
              child.check:Enable()
            end
            if child.text and child.text.SetTextColor then
              child.text:SetTextColor(1, 1, 1)
            end
          end
        end
      end
    end
  end
end

local function DE_RebuildExportList()
  if not exportFrame or not exportFrame:IsShown() then
    return
  end
  if not exportFrame.listContent then
    return
  end

  DE_ClearRows()

  local content = exportFrame.listContent
  local y = -2

  local ordered = DE_GetOrderedSpells()

  -- Build groups, categories, and ungrouped icon lists
  local groupsByName = {}
  local groupOrder = {}
  local seenGroup = {}

  local catsByName = {}
  local catOrder = {}
  local seenCat = {}

  local ungroupedIcons = {}
  local hasUngrouped = false

  local _, entry
  for _, entry in ipairs(ordered) do
    local d = entry.data or {}
    local g = d.group
    if g and g ~= "" and g ~= "no" then
      if not groupsByName[g] then
        groupsByName[g] = {}
      end
      table.insert(groupsByName[g], entry)
      if not seenGroup[g] then
        seenGroup[g] = true
        table.insert(groupOrder, g)
      end
    else
      local cat = d.category
      if cat and cat ~= "" and cat ~= "no" then
        if not catsByName[cat] then
          catsByName[cat] = {}
        end
        table.insert(catsByName[cat], entry)
        if not seenCat[cat] then
          seenCat[cat] = true
          table.insert(catOrder, cat)
        end
      else
        table.insert(ungroupedIcons, entry)
        hasUngrouped = true
      end
    end
  end

  -- "-- EVERYTHING --" row at the top
  local all = DE_CreateRow(content, y, "-- EVERYTHING --", "all", nil, 0)
  y = y - 20
  allRow = all

  all.check:SetScript("OnClick", function()
    if all.check:GetChecked() then
      DE_SetRowsDisabledExceptAll(true)
    else
      DE_SetRowsDisabledExceptAll(false)
    end
  end)

  -- Separator line (visual only)
  local sep = content:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y - 4)
  sep:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y - 4)
  sep:SetTexture(1, 1, 1)
  if sep.SetVertexColor then
    sep:SetVertexColor(1, 1, 1, 0.15)
  end
  y = y - 10

  -- Helper: attach header -> children relationship, and header checkbox behavior
  local function SetupHeaderBehavior(headerRow)
    headerRow.children = headerRow.children or {}

    headerRow.check:SetScript("OnClick", function()
      local checked = headerRow.check:GetChecked()
      local _, child
      for _, child in ipairs(headerRow.children) do
        if child.check and child.check:IsEnabled() then
          child.check:SetChecked(checked)
        end
      end
    end)
  end

  -- Helper: icon behavior: children are independent; do NOT auto-toggle header.
  local function SetupIconBehavior(iconRow)
  end

  -- 1) Groups + their icons
  local i, gName
  for i, gName in ipairs(groupOrder) do
    local label = gName .. ":"
    local headerRow = DE_CreateRow(content, y, label, "group", gName, 0)
    y = y - 20
    headerRow.children = {}

    SetupHeaderBehavior(headerRow)

    local members = groupsByName[gName] or {}
    local _, m
    for _, m in ipairs(members) do
      local d = m.data or {}
      local baseName = d.displayName or d.name or m.key
      local labelIcon = baseName
      if d.type and d.type ~= "" then
        labelIcon = labelIcon .. " |cffaaaaaa[" .. d.type .. "]|r"
      end

      local iconRow = DE_CreateRow(content, y, labelIcon, "icon", m.key, 16)
      y = y - 20

      iconRow.parentRow = headerRow
      table.insert(headerRow.children, iconRow)

      SetupIconBehavior(iconRow)
    end
  end

  -- 2) Categories + their icons
  local j, cName
  for j, cName in ipairs(catOrder) do
    local label = cName .. ":"
    local catHeader = DE_CreateRow(content, y, label, "category", cName, 0)
    y = y - 20
    catHeader.children = {}

    SetupHeaderBehavior(catHeader)

    local catMembers = catsByName[cName] or {}
    local _, cm
    for _, cm in ipairs(catMembers) do
      local d = cm.data or {}
      local baseName = d.displayName or d.name or cm.key
      local labelIcon = baseName
      if d.type and d.type ~= "" then
        labelIcon = labelIcon .. " |cffaaaaaa[" .. d.type .. "]|r"
      end

      local iconRow = DE_CreateRow(content, y, labelIcon, "icon", cm.key, 16)
      y = y - 20

      iconRow.parentRow = catHeader
      table.insert(catHeader.children, iconRow)

      SetupIconBehavior(iconRow)
    end
  end

  -- 3) Ungrouped / Uncategorized
  if hasUngrouped then
    local label = "Ungrouped / Uncategorized:"
    local unHeader = DE_CreateRow(content, y, label, "ungrouped", "Ungrouped", 0)
    y = y - 20
    unHeader.children = {}

    SetupHeaderBehavior(unHeader)

    local _, ue
    for _, ue in ipairs(ungroupedIcons) do
      local d = ue.data or {}
      local baseName = d.displayName or d.name or ue.key
      local labelIcon = baseName
      if d.type and d.type ~= "" then
        labelIcon = labelIcon .. " |cffaaaaaa[" .. d.type .. "]|r"
      end

      local iconRow = DE_CreateRow(content, y, labelIcon, "icon", ue.key, 16)
      y = y - 20

      iconRow.parentRow = unHeader
      table.insert(unHeader.children, iconRow)

      SetupIconBehavior(iconRow)
    end
  end

  -- Adjust scroll height
  local totalHeight = -y + 4
  if totalHeight < 40 then
    totalHeight = 40
  end
  content:SetHeight(totalHeight)
  exportFrame.scrollFrame:SetScrollChild(content)
end

-- ========= Export Frame =========

local function DE_CreateExportFrame()
  if exportFrame then
    return
  end

  local f = CreateFrame("Frame", "DoiteAurasExportFrame", UIParent)
  exportFrame = f
  f:SetWidth(620)
  f:SetHeight(360)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
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

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -15)
  title:SetText("|cff6FA8DCDoiteExport|r")

  local sep = f:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -35)
  sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -35)
  sep:SetTexture(1, 1, 1)
  if sep.SetVertexColor then
    sep:SetVertexColor(1, 1, 1, 0.25)
  end

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
  close:SetScript("OnClick", function()
    f:Hide()
  end)

  -- Scrollable container for the tree (EVERYTHING / groups / categories / icons)
  local listContainer = CreateFrame("Frame", nil, f)
  listContainer:SetWidth(260)
  listContainer:SetHeight(275)
  listContainer:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -40)
  listContainer:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16 })
  listContainer:SetBackdropColor(0, 0, 0, 0.7)

  local scrollFrame = CreateFrame("ScrollFrame", "DoiteAurasExportScroll", listContainer, "UIPanelScrollFrameTemplate")
  scrollFrame:SetWidth(240)
  scrollFrame:SetHeight(265)
  scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 12, -5)

  local content = CreateFrame("Frame", "DoiteAurasExportListContent", scrollFrame)
  content:SetWidth(240)
  content:SetHeight(210)
  scrollFrame:SetScrollChild(content)

  f.listContainer = listContainer
  f.scrollFrame = scrollFrame
  f.listContent = content

  -- "Create Export" button below the scroll container
  local createBtn = CreateFrame("Button", "DoiteAurasCreateExportButton", f, "UIPanelButtonTemplate")
  createBtn:SetWidth(100)
  createBtn:SetHeight(22)
  createBtn:SetPoint("TOPLEFT", listContainer, "BOTTOMLEFT", 0, -4)
  createBtn:SetText("Create Export")
  createBtn:SetScript("OnClick", function()
    if not exportEditBox then
      return
    end

    local keys = {}
    local exportAll = allRow and allRow.check and allRow.check:GetChecked()

    -- Which groups are being exported as real groups (header checked)?
    local groupsToPreserve = {}
    if not exportAll then
      local _, row
      for _, row in ipairs(exportRows) do
        if row.kind == "group" and row.check and row.check:GetChecked() and row.id then
          groupsToPreserve[row.id] = true
        end
      end
    end

    if exportAll then
      -- Export all spells currently in the DB, in order
      local ordered = DE_GetOrderedSpells()
      local _, entry
      for _, entry in ipairs(ordered) do
        table.insert(keys, entry.key)
      end
    else
      -- Only export checked icon rows
      local _, row
      for _, row in ipairs(exportRows) do
        if row.kind == "icon" and row.check and row.check:GetChecked() and row.id then
          table.insert(keys, row.id)
        end
      end
    end

    if table.getn(keys) == 0 then
      exportEditBox:SetText("No icons selected for export.\nCheck one or more icons (or -- EVERYTHING --) on the left.")
      exportEditBox:HighlightText()
      exportEditBox:SetFocus()
      DE_UpdateCopyButton()
      return
    end

    local context = {
      exportAll = exportAll,
      groupsToPreserve = groupsToPreserve,
    }

    local pkg = DE_BuildExportPackage(keys, context)
    if not pkg then
      exportEditBox:SetText("Error: could not build export package.")
      exportEditBox:HighlightText()
      exportEditBox:SetFocus()
      DE_UpdateCopyButton()
      return
    end

    local str = DE_SerializeExport(pkg)
    if not str then
      exportEditBox:SetText("Error: could not serialize export package.")
      exportEditBox:HighlightText()
      exportEditBox:SetFocus()
      DE_UpdateCopyButton()
      return
    end

    -- Put new export in the box (user can scroll as needed)
    exportEditBox:SetText(str)
    exportEditBox:HighlightText()
    exportEditBox:SetFocus()
    DE_UpdateCopyButton()

    if exportScrollFrame and exportScrollFrame.SetVerticalScroll then
      exportScrollFrame:SetVerticalScroll(0)
    end
  end)

  -- Clear button: clears all selections + export text
  local clearBtn = CreateFrame("Button", "DoiteAurasClearExportButton", f, "UIPanelButtonTemplate")
  clearBtn:SetWidth(50)
  clearBtn:SetHeight(22)
  clearBtn:SetPoint("LEFT", createBtn, "RIGHT", 4, 0)
  clearBtn:SetText("Clear")
  clearBtn:SetScript("OnClick", function()
    -- Re-enable everything in case -- EVERYTHING -- had disabled rows
    DE_SetRowsDisabledExceptAll(false)

    -- Uncheck every checkbox
    local _, row
    for _, row in ipairs(exportRows) do
      if row.check then
        row.check:SetChecked(false)
        row.check:Enable()
      end
      if row.text and row.text.SetTextColor then
        row.text:SetTextColor(1, 1, 1)
      end
    end

    -- Clear export text + scroll to top
    if exportEditBox then
      exportEditBox:SetText("")
      exportEditBox:ClearFocus()
    end
    if exportScrollFrame and exportScrollFrame.SetVerticalScroll then
      exportScrollFrame:SetVerticalScroll(0)
    end
    DE_UpdateCopyButton()
  end)

  -- Big export box on the RIGHT, non-scrollable edit box
  local boxContainer = CreateFrame("Frame", nil, f)
  boxContainer:SetPoint("TOPLEFT", listContainer, "TOPRIGHT", 15, 0)
  boxContainer:SetWidth(300)
  boxContainer:SetHeight(140)

  boxContainer:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16 })
  boxContainer:SetBackdropColor(0, 0, 0, 0.7)

  local label = boxContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", boxContainer, "TOPLEFT", 6, -6)
  label:SetText("Export string:")

  local textScroll = CreateFrame("ScrollFrame", "DoiteAurasExportTextScroll", boxContainer, "UIPanelScrollFrameTemplate")
  textScroll:SetPoint("TOPLEFT", boxContainer, "TOPLEFT", 6, -22)
  textScroll:SetPoint("BOTTOMRIGHT", boxContainer, "BOTTOMRIGHT", -8, 6)

  local edit = CreateFrame("EditBox", "DoiteAurasExportEditBox", textScroll)
  edit:SetAutoFocus(false)
  if edit.SetMultiLine then
    edit:SetMultiLine(true)
  end
  edit:SetFontObject(GameFontHighlightSmall)
  edit:SetText("")
  edit:SetScript("OnEscapePressed", function()
    this:ClearFocus()
  end)

  -- Inner text width; keep it a bit smaller than the box width
  edit:ClearAllPoints()
  edit:SetPoint("TOPLEFT", textScroll, "TOPLEFT", 4, -4)
  edit:SetWidth(280)
  -- Large height so long exports are scrollable within the clipped region
  edit:SetHeight(10000)

  edit:SetScript("OnTextChanged", function()
    local parent = this:GetParent()
    if parent and parent.UpdateScrollChildRect then
      parent:UpdateScrollChildRect()
    end
    DE_UpdateCopyButton()
  end)

  textScroll:SetScrollChild(edit)

  -- Hide the scrollbar and its buttons so the user doesn't see them
  local scrollBar = getglobal(textScroll:GetName() .. "ScrollBar")
  if scrollBar then
    scrollBar:Hide()
    scrollBar.Show = function()
    end

    local up = getglobal(scrollBar:GetName() .. "ScrollUpButton")
    if up then
      up:Hide()
    end
    local down = getglobal(scrollBar:GetName() .. "ScrollDownButton")
    if down then
      down:Hide()
    end
  end

  exportEditBox = edit
  exportScrollFrame = textScroll

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", boxContainer, "BOTTOMLEFT", 3, -4)
  hint:SetWidth(300)
  hint:SetJustifyH("LEFT")
  hint:SetText("Export data will appear in this box.")

  -- Step 1 label in DoiteAuras blue, then the Select button
  local step1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  step1:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
  step1:SetWidth(300)
  step1:SetJustifyH("LEFT")
  step1:SetText("|cff6FA8DCStep 1.|r Click 'Select export' below.")

  local copyBtn = CreateFrame("Button", "DoiteAurasCopyExportButton", f, "UIPanelButtonTemplate")
  copyBtn:SetWidth(90)
  copyBtn:SetHeight(22)
  copyBtn:SetPoint("TOPLEFT", step1, "BOTTOMLEFT", 0, -4)
  copyBtn:SetText("Select export")
  copyBtn:Disable()
  copyBtn:SetScript("OnClick", function()
    if not exportEditBox then
      return
    end
    local txt = exportEditBox:GetText() or ""
    if txt == "" then
      return
    end

    -- Select all text and focus the box so the user can Ctrl-C it
    exportEditBox:HighlightText()
    exportEditBox:SetFocus()

    local chat = DEFAULT_CHAT_FRAME or ChatFrame1
    if chat then
      chat:AddMessage("|cff6FA8DCDoiteAuras:|r Export text selected. Press Ctrl+C to copy it.")
    end
  end)

  exportFrame.copyBtn = copyBtn

  -- Step 2 and Step 3 instructions under the button
  local step2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  step2:SetPoint("TOPLEFT", copyBtn, "BOTTOMLEFT", 0, -6)
  step2:SetWidth(360)
  step2:SetJustifyH("LEFT")
  step2:SetText("|cff6FA8DCStep 2.|r Press Ctrl+C to copy it (the whole export string).")

  local step3 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  step3:SetPoint("TOPLEFT", step2, "BOTTOMLEFT", 0, -4)
  step3:SetWidth(360)
  step3:SetJustifyH("LEFT")
  step3:SetText("|cff6FA8DCStep 3.|r Share with your friends!")

  -- OnShow: rebuild the full tree every time, clear text, ensure top-most, scroll to top
  f:SetScript("OnShow", function()
    DE_MakeTopMost(f)
    DE_RebuildExportList()
    if exportEditBox then
      exportEditBox:SetText("")
      exportEditBox:ClearFocus()
    end
    if exportScrollFrame and exportScrollFrame.SetVerticalScroll then
      exportScrollFrame:SetVerticalScroll(0)
    end
    DE_UpdateCopyButton()
  end)

  -- Make sure it's top-most right away
  DE_MakeTopMost(f)
end

function DoiteExport_ShowExportFrame()
  if not exportFrame then
    DE_CreateExportFrame()
  end

  -- If the import frame is open, close it so only one is visible
  if importFrame and importFrame:IsShown() then
    importFrame:Hide()
  end

  -- If Settings is open, close it so only one is visible
  local sf = _G["DoiteAurasSettingsFrame"]
  if sf and sf.IsShown and sf:IsShown() then
    sf:Hide()
  end

  exportFrame:Show()
end

-- ========= Import Frame =========
local function DE_CreateImportFrame()
  if importFrame then
    return
  end

  local f = CreateFrame("Frame", "DoiteAurasImportFrame", UIParent)
  importFrame = f
  -- Slightly smaller frame so it visually matches the export textbox area
  f:SetWidth(250)
  f:SetHeight(220)
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

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -15)
  title:SetText("|cff6FA8DCDoiteImport|r")

  local sep = f:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -35)
  sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -35)
  sep:SetTexture(1, 1, 1)
  if sep.SetVertexColor then
    sep:SetVertexColor(1, 1, 1, 0.25)
  end

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
  close:SetScript("OnClick", function()
    f:Hide()
  end)

  local boxContainer = CreateFrame("Frame", nil, f)
  -- Match the export box size so both sides feel consistent
  boxContainer:SetWidth(210)
  boxContainer:SetHeight(120)
  boxContainer:SetPoint("TOP", f, "TOP", 0, -60)
  boxContainer:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16 })
  boxContainer:SetBackdropColor(0, 0, 0, 0.7)

  local scroll = CreateFrame("ScrollFrame", "DoiteAurasImportScroll", boxContainer, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", boxContainer, "TOPLEFT", 6, -6)
  scroll:SetPoint("BOTTOMRIGHT", boxContainer, "BOTTOMRIGHT", -8, 6)

  local edit = CreateFrame("EditBox", "DoiteAurasImportEditBox", scroll)
  edit:SetAutoFocus(false)
  if edit.SetMultiLine then
    edit:SetMultiLine(true)
  end
  edit:SetFontObject(GameFontHighlightSmall)
  edit:SetText("")
  edit:SetScript("OnEscapePressed", function()
    this:ClearFocus()
  end)

  -- Inner area; width a bit smaller than container width
  edit:ClearAllPoints()
  edit:SetPoint("TOPLEFT", scroll, "TOPLEFT", 4, -4)
  edit:SetWidth(190)
  edit:SetHeight(10000)

  -- Click anywhere inside the import box area to focus the editbox (not just the tiny clickable rect)
  if boxContainer.EnableMouse then
    boxContainer:EnableMouse(true)
    boxContainer:SetScript("OnMouseDown", function()
      edit:SetFocus()
    end)
  end

  if scroll.EnableMouse then
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function()
      edit:SetFocus()
    end)
  end

  -- Still allow direct clicks on the editbox itself
  edit:SetScript("OnMouseDown", function()
    this:SetFocus()
  end)

  edit:SetScript("OnTextChanged", function()
    local parent = this:GetParent()
    if parent and parent.UpdateScrollChildRect then
      parent:UpdateScrollChildRect()
    end
  end)

  scroll:SetScrollChild(edit)

  -- Hide scrollbar & buttons
  local scrollBar = getglobal(scroll:GetName() .. "ScrollBar")
  if scrollBar then
    scrollBar:Hide()
    scrollBar.Show = function()
    end

    local up = getglobal(scrollBar:GetName() .. "ScrollUpButton")
    if up then
      up:Hide()
    end
    local down = getglobal(scrollBar:GetName() .. "ScrollDownButton")
    if down then
      down:Hide()
    end
  end

  importEditBox = edit
  importScrollFrame = scroll

  -- Import button (centered beneath the box)
  local importBtn = CreateFrame("Button", "DoiteAurasImportDoButton", f, "UIPanelButtonTemplate")
  importBtn:SetWidth(80)
  importBtn:SetHeight(24)
  importBtn:SetPoint("TOP", boxContainer, "BOTTOM", 0, -2)
  importBtn:SetText("Import")
  importBtn:SetScript("OnClick", function()
    local text = importEditBox:GetText() or ""
    local chat = DEFAULT_CHAT_FRAME or ChatFrame1

    if text == "" then
      if chat then
        chat:AddMessage("|cffff0000DoiteAuras:|r Nothing to import. Paste export text first.")
      end
      return
    end

    local res, err = DE_ImportFromString(text)
    if not res then
      if chat then
        chat:AddMessage("|cffff0000DoiteAuras:|r Import failed: " .. tostring(err or "unknown error"))
      end
      return
    end

    local count = res.count or 0
    local msg

    local ginfo = res.groups
    local cinfo = res.categories

    local gCount = 0
    local firstGroupName, firstGroupIcons
    if ginfo then
      local g, nIcons
      for g, nIcons in pairs(ginfo) do
        gCount = gCount + 1
        if not firstGroupName then
          firstGroupName = g
          firstGroupIcons = nIcons
        end
      end
    end

    local cCount = 0
    local firstCatName, firstCatIcons
    if cinfo then
      local c, nIcons2
      for c, nIcons2 in pairs(cinfo) do
        cCount = cCount + 1
        if not firstCatName then
          firstCatName = c
          firstCatIcons = nIcons2
        end
      end
    end

    if gCount == 1 and firstGroupName then
      msg = "Group " .. firstGroupName .. " has been imported, with " .. (firstGroupIcons or count) .. " icons."
    elseif gCount > 1 then
      msg = "Imported " .. count .. " icons into " .. gCount .. " groups."
    elseif cCount == 1 and firstCatName then
      msg = "Category " .. firstCatName .. " has been imported, with " .. (firstCatIcons or count) .. " icons."
    elseif cCount > 1 then
      msg = "Imported " .. count .. " icons into " .. cCount .. " categories."
    else
      msg = "Imported " .. count .. " icons."
    end

    -- Refresh DoiteAuras UI so new icons/groups appear immediately
    if DoiteAuras_RefreshList then
      pcall(DoiteAuras_RefreshList)
    end
    if DoiteAuras_RefreshIcons then
      pcall(DoiteAuras_RefreshIcons)
    end
    -- Clear sort cache so imported sort modes take effect
    DoiteGroup.InvalidateSortCache()

    if chat then
      chat:AddMessage("|cff6FA8DCDoiteAuras:|r " .. msg)
    end

    -- Close the import frame after a successful import
    if importFrame and importFrame.Hide then
      importFrame:Hide()
    end
  end)

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  -- Place the explanation above the input box, under the title/separator
  hint:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -40)
  hint:SetWidth(340)
  hint:SetJustifyH("LEFT")
  hint:SetText("Paste an export string below and Import.")

  f:SetScript("OnShow", function()
    DE_MakeTopMost(f)
    if importEditBox then
      importEditBox:SetText("")
      importEditBox:ClearFocus()
    end
    if importScrollFrame and importScrollFrame.SetVerticalScroll then
      importScrollFrame:SetVerticalScroll(0)
    end
  end)

  -- Make sure it's top-most initially as well
  DE_MakeTopMost(f)
end

function DoiteExport_ShowImportFrame()
  if not importFrame then
    DE_CreateImportFrame()
  end

  -- If the export frame is open, close it so only one is visible
  if exportFrame and exportFrame:IsShown() then
    exportFrame:Hide()
  end

  -- If Settings is open, close it so only one is visible
  local sf = _G["DoiteAurasSettingsFrame"]
  if sf and sf.IsShown and sf:IsShown() then
    sf:Hide()
  end

  importFrame:Show()
end
