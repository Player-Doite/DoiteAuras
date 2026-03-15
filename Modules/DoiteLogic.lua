---------------------------------------------------------------
-- DoiteLogic.lua
-- Generic boolean combinator for "in-edit" ability/auras condition
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

local DoiteLogic = _G["DoiteLogic"] or {}
_G["DoiteLogic"] = DoiteLogic

---------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------
-- Global helpers used by the logic editor and DoiteEdit

function _DA_Logic_GetAuraListForType(typeKey)
  if not DoiteAurasDB or not DoiteAurasDB.spells then
    return nil
  end
  if not DoiteEdit_CurrentKey then
    return nil
  end

  local key = DoiteEdit_CurrentKey
  local d = DoiteAurasDB.spells[key]
  if not d then
    return nil
  end
  d.conditions = d.conditions or {}

  if d.type == "Ability" or typeKey == "ability" then
    d.conditions.ability = d.conditions.ability or {}
    d.conditions.ability.auraConditions = d.conditions.ability.auraConditions or {}
    return d.conditions.ability.auraConditions

  elseif d.type == "Item" or typeKey == "item" then
    d.conditions.item = d.conditions.item or {}
    d.conditions.item.auraConditions = d.conditions.item.auraConditions or {}
    return d.conditions.item.auraConditions

  else
    -- Buff/Debuff / "aura"
    d.conditions.aura = d.conditions.aura or {}
    d.conditions.aura.auraConditions = d.conditions.aura.auraConditions or {}
    return d.conditions.aura.auraConditions
  end
end

local function _len(t)
  if not t then
    return 0
  end
  local n = 0
  while t[n + 1] ~= nil do
    n = n + 1
  end
  return n
end

local function _push(t, v)
  t[_len(t) + 1] = v
end

local function _GetOpForEntry(entry)
  if not entry or not entry.logicOp then
    return "AND"
  end
  local op = entry.logicOp
  if op == "OR" or op == "or" then
    return "OR"
  end
  return "AND"
end

local function _HasAnyLogicHints(list)
  local n = _len(list)
  if n == 0 then
    return false
  end
  local i = 1
  while i <= n do
    local e = list[i]
    if e and (e.logicOp or e.parenOpen or e.parenClose) then
      return true
    end
    i = i + 1
  end
  return false
end

-- Parenthesis-specific helpers
local function _HasAnyParenHints(list)
  local n = _len(list)
  if n == 0 then
    return false
  end
  local i = 1
  while i <= n do
    local e = list[i]
    if e and (e.parenOpen or e.parenClose) then
      return true
    end
    i = i + 1
  end
  return false
end

local function _IsParenStructureValid(list)
  local n = _len(list)
  local openCount = 0
  local i = 1
  local valid = true

  while i <= n do
    local e = list[i]

    if e and e.parenOpen then
      openCount = openCount + 1
    end

    if e and e.parenClose then
      if openCount <= 0 then
        valid = false
        break
      else
        openCount = openCount - 1
      end
    end

    i = i + 1
  end

  if openCount ~= 0 then
    valid = false
  end

  return valid
end

local function _ResetLogicToStrictAnd(list)
  -- Clear all AND/OR and paren hints; evaluation will fall back to pure AND
  local n = _len(list)
  local i = 1
  while i <= n do
    local e = list[i]
    if e then
      e.logicOp = nil
      e.parenOpen = nil
      e.parenClose = nil
    end
    i = i + 1
  end
end

local function _NotifyLogicResetForCurrentSpell()
  if not DEFAULT_CHAT_FRAME or not DEFAULT_CHAT_FRAME.AddMessage then
    return
  end
  if not DoiteAurasDB or not DoiteAurasDB.spells or not DoiteEdit_CurrentKey then
    return
  end

  local d = DoiteAurasDB.spells[DoiteEdit_CurrentKey]
  if not d then
    return
  end

  local displayName = d.displayName or DoiteEdit_CurrentKey

  -- DoiteAuras blue: #6FA8DC -> FF6FA8DC
  local prefix = "|cFF6FA8DCDoiteAuras:|r "
  local body = "|cFFFFFFFFBy removing a condition with dependant AND/OR logic, all logic has been reset for|r"
  local name = ""
  if displayName then
    name = " |cFFFFFF00" .. displayName .. "|r."
  end

  DEFAULT_CHAT_FRAME:AddMessage(prefix .. body .. name)
end

-- Public helper: used by DoiteEdit after deleting a condition row.
function DoiteLogic.ValidateOrResetCurrentLogic(typeKey)
  if not typeKey then
    return
  end
  local list = _DA_Logic_GetAuraListForType(typeKey)
  if not list then
    return
  end

  if _HasAnyParenHints(list) and not _IsParenStructureValid(list) then
    _ResetLogicToStrictAnd(list)
    _NotifyLogicResetForCurrentSpell()
  end
end

---------------------------------------------------------------
-- Shunting-yard: infix -> RPN
---------------------------------------------------------------
local _precedence = {
  AND = 2,
  OR = 1,
}

-- Scratch tables to eliminate per-evaluation allocations (tokens/RPN/stacks)
local _DA_TMP_RPN_OUT = {}
local _DA_TMP_OP_STACK = {}
local _DA_TMP_EVAL_STACK = {}
local _DA_TMP_TOKENS = {}

local function _DA_WipeArray(t)
  local i = _len(t)
  while i > 0 do
    t[i] = nil
    i = i - 1
  end
end

local function _ToRpn(tokens, output, stack)
  output = output or _DA_TMP_RPN_OUT
  stack = stack or _DA_TMP_OP_STACK

  _DA_WipeArray(output)
  _DA_WipeArray(stack)

  local n = _len(tokens)
  local i = 1
  while i <= n do
    local tok = tokens[i]

    if tok == true or tok == false then
      _push(output, tok)

    elseif tok == "AND" or tok == "OR" then
      local pTok = _precedence[tok] or 1

      while _len(stack) > 0 do
        local top = stack[_len(stack)]
        if top == "AND" or top == "OR" then
          local pTop = _precedence[top] or 1
          if pTop >= pTok then
            _push(output, top)
            stack[_len(stack)] = nil
          else
            break
          end
        else
          break
        end
      end

      _push(stack, tok)

    elseif tok == "(" then
      _push(stack, tok)

    elseif tok == ")" then
      local found = false
      while _len(stack) > 0 do
        local top = stack[_len(stack)]
        stack[_len(stack)] = nil

        if top == "(" then
          found = true
          break
        else
          _push(output, top)
        end
      end
      if not found then
        error("DoiteLogic: mismatched ')'")
      end
    end

    i = i + 1
  end

  while _len(stack) > 0 do
    local top = stack[_len(stack)]
    stack[_len(stack)] = nil

    if top == "(" or top == ")" then
      error("DoiteLogic: mismatched '('")
    end

    _push(output, top)
  end

  return output
end

---------------------------------------------------------------
-- RPN evaluation
---------------------------------------------------------------
local function _EvalRpn(rpn, st)
  st = st or _DA_TMP_EVAL_STACK
  _DA_WipeArray(st)

  local n = _len(rpn)
  local i = 1

  while i <= n do
    local tok = rpn[i]

    if tok == true or tok == false then
      _push(st, tok)

    elseif tok == "AND" or tok == "OR" then
      local sb = _len(st)
      if sb < 2 then
        error("DoiteLogic: not enough operands")
      end
      local b = st[sb];
      st[sb] = nil
      local a = st[sb - 1];
      st[sb - 1] = nil

      local v
      if tok == "AND" then
        v = (a and b) and true or false
      else
        v = (a or b) and true or false
      end

      _push(st, v)
    end

    i = i + 1
  end

  if _len(st) ~= 1 then
    error("DoiteLogic: bad RPN stack state")
  end

  return (st[1] == true)
end

local function _EvaluateStrictAnd(list, n, evalFunc)
  local i = 1
  while i <= n do
    if not evalFunc(list[i]) then
      return false
    end
    i = i + 1
  end
  return true
end

---------------------------------------------------------------
-- Generic evaluator
---------------------------------------------------------------
function DoiteLogic.EvaluateGeneric(list, evalFunc)
  if not list then
    return true
  end

  local n = _len(list)
  if n == 0 then
    return true
  end

  evalFunc = evalFunc or function(e)
    return e ~= nil
  end

  if not _HasAnyLogicHints(list) then
    return _EvaluateStrictAnd(list, n, evalFunc)
  end

  if _HasAnyParenHints(list) and not _IsParenStructureValid(list) then
    _ResetLogicToStrictAnd(list)
    _NotifyLogicResetForCurrentSpell()

    -- After reset there are no logic hints anymore, so fall back to the simple AND behaviour.
    return _EvaluateStrictAnd(list, n, evalFunc)
  end

  -- Reuse a scratch token buffer to avoid per-call allocations
  local tokens = _DA_TMP_TOKENS
  _DA_WipeArray(tokens)

  local i = 1
  while i <= n do
    local e = list[i]
    local val = (evalFunc(e) == true)

    if e and e.parenOpen then
      _push(tokens, "(")
    end

    _push(tokens, val)

    if e and e.parenClose then
      _push(tokens, ")")
    end

    if i < n then
      local op = _GetOpForEntry(e)
      _push(tokens, op)
    end

    i = i + 1
  end

  local ok, rpn = pcall(_ToRpn, tokens, _DA_TMP_RPN_OUT, _DA_TMP_OP_STACK)
  if not ok or not rpn then
    return _EvaluateStrictAnd(list, n, evalFunc)
  end

  local ok2, res = pcall(_EvalRpn, rpn, _DA_TMP_EVAL_STACK)
  if not ok2 then
    return _EvaluateStrictAnd(list, n, evalFunc)
  end

  return (res == true)
end

---------------------------------------------------------------
-- Aura-specific helpers
---------------------------------------------------------------
function DoiteLogic.EvaluateAuraList(list, evalFunc)
  return DoiteLogic.EvaluateGeneric(list, evalFunc)
end

---------------------------------------------------------------
-- Label + preview helpers (used by DoiteEdit)
---------------------------------------------------------------
local function _BuildLabelForEntry(entry, index)
  if not entry then
    return "#" .. tostring(index or 0)
  end

  local kind = entry.buffType or "BUFF"
  local mode = entry.mode or ""
  local unit = entry.unit or ""
  local name = entry.name or ("#" .. tostring(index or 0))

  local kindText
  if kind == "ABILITY" then
    kindText = "Ability"
  elseif kind == "DEBUFF" then
    kindText = "Debuff"
  elseif kind == "TALENT" then
    kindText = "Talent"
  else
    kindText = "Buff"
  end

  local modeText = ""
  if mode == "oncd" then
    modeText = "On CD"
  elseif mode == "notcd" then
    modeText = "Not on CD"
  elseif mode == "missing" then
    modeText = "Missing"
  elseif mode == "both" then
    modeText = "Found or missing"
  elseif mode == "found" or mode == "" or mode == nil then
    modeText = "Found"
  else
    -- Normalise talent modes etc.
    local m = tostring(mode or "")
    local lower = string.lower(m)
    if lower == "known" then
      modeText = "Known"
    elseif lower == "notknown" or lower == "not known" then
      modeText = "Not known"
    else
      modeText = m
    end
  end

  local unitText = ""
  local selfKind = (kind == "ABILITY" or kind == "TALENT")

  if selfKind then
    unitText = "Player"
  else
    if unit == "target" then
      unitText = "On target"
    elseif unit == "player" or unit == "" or unit == nil then
      unitText = "On player"
    end
  end

  local parts = {}
  _push(parts, kindText .. ": " .. name)
  if modeText ~= "" then
    _push(parts, "(" .. modeText .. ")")
  end
  if unitText ~= "" then
    _push(parts, "(" .. unitText .. ")")
  end

  return table.concat(parts, " ")
end

-- Exported: used by the logic editor rows
function DoiteLogic.BuildAuraLabel(entry, index)
  return _BuildLabelForEntry(entry, index)
end

-- Exported: pretty-print the whole expression
function DoiteLogic.BuildAuraPreview(list)
  if not list then
    return ""
  end
  local n = _len(list)
  if n == 0 then
    return ""
  end

  local parts = {}

  -- Color for logic parentheses only (outer + user-added), WoW color escape
  local parenOpenColored = "|cFFFFFF00(|r"
  local parenCloseColored = "|cFFFFFF00)|r"

  -- Always wrap the entire expression in an outer pair of colored parentheses
  _push(parts, parenOpenColored)

  local i = 1
  while i <= n do
    local e = list[i]
    local label = _BuildLabelForEntry(e, i)

    -- User-added opening parenthesis before this condition
    if e and e.parenOpen then
      _push(parts, parenOpenColored)
    end

    -- Label itself
    _push(parts, label)

    -- User-added closing parenthesis after this condition
    if e and e.parenClose then
      _push(parts, parenCloseColored)
    end

    if i < n then
      local op = _GetOpForEntry(e)
      -- Color AND/OR in green
      local opColored = "|cFF00FF00" .. op .. "|r"
      _push(parts, opColored)
    end

    i = i + 1
  end

  -- Closing outer colored parenthesis
  _push(parts, parenCloseColored)

  return table.concat(parts, " ")
end

---------------------------------------------------------------
-- Aura logic editor UI
---------------------------------------------------------------

-- Local helper so DoiteLogic does not hard-require SafeRefresh/SafeEvaluate
local function _DA_Logic_SafeRefreshAndEvaluate()
  if type(SafeRefresh) == "function" then
    SafeRefresh()
  end
  if type(SafeEvaluate) == "function" then
    SafeEvaluate()
  end
end

-- locals, module-scoped
local DoiteAuraLogicFrame = nil
local DoiteAuraLogic_CurrentType = nil
local DoiteAuraLogic_BackupList = nil

-- shallow copy of the list (index-based)
local function _DeepCopyAuraList(list)
  if not list then
    return nil
  end
  local out = {}
  local i = 1
  while list[i] do
    local src = list[i]
    if type(src) == "table" then
      local dst = {}
      for k, v in pairs(src) do
        dst[k] = v
      end
      out[i] = dst
    else
      out[i] = src
    end
    i = i + 1
  end
  return out
end

local function DoiteAuraLogic_UpdatePreview()
  if not DoiteAuraLogicFrame or not DoiteAuraLogic_CurrentType then
    return
  end

  local list = _DA_Logic_GetAuraListForType(DoiteAuraLogic_CurrentType)
  if not list then
    DoiteAuraLogicFrame.preview:SetText("")
    return
  end

  local txt = ""
  if DoiteLogic.BuildAuraPreview then
    txt = DoiteLogic.BuildAuraPreview(list) or ""
  end
  DoiteAuraLogicFrame.preview:SetText(txt)
end

-- Recompute parentheses validity, grey out invalid ')' and enable/disable Apply
local function DoiteAuraLogic_RecomputeParenAndApplyState()
  if not DoiteAuraLogicFrame or not DoiteAuraLogic_CurrentType then
    return
  end

  local list = _DA_Logic_GetAuraListForType(DoiteAuraLogic_CurrentType)
  if not list then
    if DoiteAuraLogicFrame.okButton then
      DoiteAuraLogicFrame.okButton:Disable()
    end
    return
  end

  local n = _len(list)
  local openCount = 0
  local valid = true
  local rows = DoiteAuraLogicFrame.rows or {}

  local i = 1
  while i <= n do
    local e = list[i]
    local row = rows[i]

    -- Count opens first
    if e and e.parenOpen then
      openCount = openCount + 1
    end

    local hasUnmatchedOpen = (openCount > 0)

    -- Grey out / enable the close parenthesis button for this row
    if row and row.parenClose then
      if hasUnmatchedOpen then
        row.parenClose:Enable()
        if row.parenClose.text then
          row.parenClose.text:SetTextColor(1, 0.82, 0)
        end
      else
        row.parenClose:Disable()
        if row.parenClose.text then
          row.parenClose.text:SetTextColor(0.4, 0.4, 0.4)
        end
      end
    end

    -- Then process actual closes for validity
    if e and e.parenClose then
      if openCount <= 0 then
        -- More closes than opens at this point -> invalid
        valid = false
      else
        openCount = openCount - 1
      end
    end

    i = i + 1
  end

  -- After the last condition, opens must be fully closed
  if openCount ~= 0 then
    valid = false
  end

  -- Toggle Apply button based on validity
  if DoiteAuraLogicFrame.okButton then
    if valid then
      DoiteAuraLogicFrame.okButton:Enable()
    else
      DoiteAuraLogicFrame.okButton:Disable()
    end
  end
end

local function DoiteAuraLogic_BuildRow(frame, index)
  local row = frame.rows[index]
  if row then
    return row
  end

  -- Parent rows to the scroll child if present, otherwise to the frame itself
  local parent = frame.scrollChild or frame

  row = CreateFrame("Frame", nil, parent)
  row:SetHeight(18)

  -- Position inside the scrollable area
  local y = -4 - (index - 1) * 20
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, y)
  row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, y)

  -- "(" checkbox
  row.parenOpen = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.parenOpen:SetWidth(18);
  row.parenOpen:SetHeight(18)
  row.parenOpen:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.parenOpen.text = row.parenOpen:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.parenOpen.text:SetPoint("LEFT", row.parenOpen, "RIGHT", 2, 0)
  row.parenOpen.text:SetText("(")

  -- ")" checkbox
  row.parenClose = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.parenClose:SetWidth(18);
  row.parenClose:SetHeight(18)
  row.parenClose:SetPoint("LEFT", row.parenOpen.text, "RIGHT", 12, 0)
  row.parenClose.text = row.parenClose:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.parenClose.text:SetPoint("LEFT", row.parenClose, "RIGHT", 2, 0)
  row.parenClose.text:SetText(")")

  -- AND
  row.andCB = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.andCB:SetWidth(18);
  row.andCB:SetHeight(18)
  row.andCB:SetPoint("LEFT", row.parenClose.text, "RIGHT", 12, 0)
  row.andFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.andFS:SetPoint("LEFT", row.andCB, "RIGHT", 2, 0)
  row.andFS:SetText("AND")

  -- OR
  row.orCB = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.orCB:SetWidth(18);
  row.orCB:SetHeight(18)
  row.orCB:SetPoint("LEFT", row.andFS, "RIGHT", 12, 0)
  row.orFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.orFS:SetPoint("LEFT", row.orCB, "RIGHT", 2, 0)
  row.orFS:SetText("OR")

  -- Label
  row.labelFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.labelFS:SetPoint("LEFT", row.orFS, "RIGHT", 12, 0)
  row.labelFS:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.labelFS:SetJustifyH("LEFT")
  row.labelFS:SetNonSpaceWrap(false)

  -- Scripts (use row._index set in OpenAuraLogicEditor)
  row.parenOpen:SetScript("OnClick", function()
    if not DoiteAuraLogic_CurrentType then
      return
    end
    local list = _DA_Logic_GetAuraListForType(DoiteAuraLogic_CurrentType)
    if not list or not row._index or not list[row._index] then
      return
    end

    list[row._index].parenOpen = this:GetChecked() and true or nil
    DoiteAuraLogic_UpdatePreview()
    DoiteAuraLogic_RecomputeParenAndApplyState()
    _DA_Logic_SafeRefreshAndEvaluate()
  end)

  row.parenClose:SetScript("OnClick", function()
    if not DoiteAuraLogic_CurrentType then
      return
    end
    local list = _DA_Logic_GetAuraListForType(DoiteAuraLogic_CurrentType)
    if not list or not row._index or not list[row._index] then
      return
    end

    list[row._index].parenClose = this:GetChecked() and true or nil
    DoiteAuraLogic_UpdatePreview()
    DoiteAuraLogic_RecomputeParenAndApplyState()
    _DA_Logic_SafeRefreshAndEvaluate()
  end)

  row.andCB:SetScript("OnClick", function()
    if not DoiteAuraLogic_CurrentType then
      return
    end
    local list = _DA_Logic_GetAuraListForType(DoiteAuraLogic_CurrentType)
    if not list or not row._index or not list[row._index] then
      return
    end

    local idx = row._index
    local n = _len(list)
    if idx >= n then
      this:SetChecked(false)
      return
    end

    if this:GetChecked() then
      row.orCB:SetChecked(false)
      list[idx].logicOp = "AND"
    else
      -- keep at least one op; default to AND
      this:SetChecked(true)
      list[idx].logicOp = "AND"
    end
    DoiteAuraLogic_UpdatePreview()
    _DA_Logic_SafeRefreshAndEvaluate()
  end)

  row.orCB:SetScript("OnClick", function()
    if not DoiteAuraLogic_CurrentType then
      return
    end
    local list = _DA_Logic_GetAuraListForType(DoiteAuraLogic_CurrentType)
    if not list or not row._index or not list[row._index] then
      return
    end

    local idx = row._index
    local n = _len(list)
    if idx >= n then
      this:SetChecked(false)
      return
    end

    if this:GetChecked() then
      row.andCB:SetChecked(false)
      list[idx].logicOp = "OR"
    else
      -- keep at least one op; default to AND
      this:SetChecked(true)
      list[idx].logicOp = "AND"
    end
    DoiteAuraLogic_UpdatePreview()
    _DA_Logic_SafeRefreshAndEvaluate()
  end)

  frame.rows[index] = row
  return row
end

-- Public: editor entry point (what DoiteEdit will call)
function DoiteLogic.OpenAuraLogicEditor(typeKey)
  if typeKey ~= "ability" and typeKey ~= "aura" and typeKey ~= "item" then
    return
  end

  local list = _DA_Logic_GetAuraListForType(typeKey)
  local count = _len(list)
  if count < 2 then
    -- nothing to combine
    return
  end

  if not DoiteAuraLogicFrame then
    local f = CreateFrame("Frame", "DoiteAuraLogicFrame", UIParent)

    -- Fullscreen overlay
    f:SetAllPoints(UIParent)

    -- force this window to the very front
    if f.SetFrameStrata then
      f:SetFrameStrata("TOOLTIP")
    end
    if UIParent and UIParent.GetFrameLevel and f.SetFrameLevel then
      local lvl = UIParent:GetFrameLevel() or 0
      f:SetFrameLevel(lvl + 1000)
    end

    -- dark background covering the entire screen
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.90)

    -- Inner content panel (actual logic editor UI)
    local content = CreateFrame("Frame", nil, f)

    -- Make the logic window about 3/4 of the screen width
    local screenWidth = UIParent:GetWidth()
    if not screenWidth or screenWidth <= 0 then
      if type(GetScreenWidth) == "function" then
        screenWidth = GetScreenWidth()
      else
        screenWidth = 1024
      end
    end
    local contentWidth = math.floor(screenWidth * 0.75)

    content:SetWidth(contentWidth)
    content:SetHeight(275)
    content:SetPoint("CENTER", f, "CENTER", 0, 0)
    content:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 16, edgeSize = 16,
    })
    content:SetBackdropColor(0, 0, 0, 0.9)
    f.content = content

    -- title
    f.title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -10)
    f.title:SetText("Added Ability/Buff/Debuff Logic")
    -- DoiteAuras blue: #6FA8DC
    f.title:SetTextColor(111 / 255, 168 / 255, 220 / 255)

    -- hint
    f.hint = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.hint:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
    f.hint:SetWidth(contentWidth - 20)
    f.hint:SetJustifyH("LEFT")
    f.hint:SetText("Configure AND/OR and parentheses between Ability, Buff & Debuff conditions for your icon. At the bottom you will find a preview of your selected logic that will apply.")
    f.hint:SetTextColor(1, 1, 1)

    -- === Scrollable container for logic rows ===
    local listContainer = CreateFrame("Frame", nil, content)
    listContainer:SetWidth(content:GetWidth() - 35)
    listContainer:SetHeight(140)
    listContainer:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -50)
    listContainer:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
    })
    listContainer:SetBackdropColor(0, 0, 0, 0.7)

    local scrollFrame = CreateFrame("ScrollFrame", "DoiteAuraLogicScroll", listContainer, "UIPanelScrollFrameTemplate")
    scrollFrame:SetWidth(listContainer:GetWidth() - 24)
    scrollFrame:SetHeight(listContainer:GetHeight() - 15)
    scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 4, -8)

    local scrollChild = CreateFrame("Frame", "DoiteAuraLogicScrollChild", scrollFrame)
    scrollChild:SetWidth(scrollFrame:GetWidth())
    scrollChild:SetHeight(listContainer:GetHeight())
    scrollFrame:SetScrollChild(scrollChild)

    -- move the actual scrollbar a bit further right, off the inner frame edge
    local scrollBar = _G["DoiteAuraLogicScrollScrollBar"]
    if scrollBar then
      scrollBar:ClearAllPoints()
      scrollBar:SetPoint("TOPLEFT", listContainer, "TOPRIGHT", -4, -18)
      scrollBar:SetPoint("BOTTOMLEFT", listContainer, "BOTTOMRIGHT", -4, 18)
    end

    f.listContainer = listContainer
    f.scrollFrame = scrollFrame
    f.scrollChild = scrollChild

    -- Make sure the visual stacking keeps the backdrop under the controls
    local baseLevel = content:GetFrameLevel() or 1
    listContainer:SetFrameLevel(baseLevel + 0)
    scrollFrame:SetFrameLevel(baseLevel + 1)
    scrollChild:SetFrameLevel(baseLevel + 2)

    -- preview text (top-aligned, under the list, and wider)
    f.previewLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.previewLabel:SetPoint("TOPLEFT", listContainer, "BOTTOMLEFT", 10, -8)
    f.previewLabel:SetText("Preview:")

    f.preview = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.preview:SetPoint("TOPLEFT", f.previewLabel, "TOPLEFT", 56, 0)
    f.preview:SetWidth(contentWidth - 86)
    f.preview:SetJustifyH("LEFT")

    -- grey preview colors
    f.previewLabel:SetTextColor(0.7, 0.7, 0.7)
    f.preview:SetTextColor(0.7, 0.7, 0.7)

    -- Apply / Cancel
    f.okButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    f.okButton:SetWidth(80);
    f.okButton:SetHeight(20)
    f.okButton:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -10, 8)
    f.okButton:SetText("Apply")

    f.cancelButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    f.cancelButton:SetWidth(80);
    f.cancelButton:SetHeight(20)
    f.cancelButton:SetPoint("RIGHT", f.okButton, "LEFT", -6, 0)
    f.cancelButton:SetText("Cancel")

    f.rows = {}

    -- Esc to close
    if UISpecialFrames then
      table.insert(UISpecialFrames, "DoiteAuraLogicFrame")
    end

    -- Apply: keep changes
    f.okButton:SetScript("OnClick", function()
      if DoiteAuraLogic_CurrentType and AuraCond_RefreshFromDB then
        AuraCond_RefreshFromDB(DoiteAuraLogic_CurrentType)
      end
      _DA_Logic_SafeRefreshAndEvaluate()
      f:Hide()
    end)

    -- Cancel: restore backup list
    f.cancelButton:SetScript("OnClick", function()
      if DoiteAuraLogic_CurrentType and DoiteAuraLogic_BackupList then
        local list2 = _DA_Logic_GetAuraListForType(DoiteAuraLogic_CurrentType)
        if list2 then
          -- wipe current
          local i = 1
          while list2[i] do
            list2[i] = nil
            i = i + 1
          end
          -- copy back
          i = 1
          while DoiteAuraLogic_BackupList[i] do
            local src = DoiteAuraLogic_BackupList[i]
            local dst = {}
            for k, v in pairs(src) do
              dst[k] = v
            end
            list2[i] = dst
            i = i + 1
          end
        end
        if AuraCond_RefreshFromDB then
          AuraCond_RefreshFromDB(DoiteAuraLogic_CurrentType)
        end
        _DA_Logic_SafeRefreshAndEvaluate()
      end
      f:Hide()
    end)

    DoiteAuraLogicFrame = f
  end

  DoiteAuraLogic_CurrentType = typeKey
  DoiteAuraLogic_BackupList = _DeepCopyAuraList(list)

  -- build rows
  local i = 1
  while i <= count do
    local entry = list[i]
    local row = DoiteAuraLogic_BuildRow(DoiteAuraLogicFrame, i)
    row._index = i
    row:Show()

    -- label
    local label = ""
    if DoiteLogic.BuildAuraLabel then
      label = DoiteLogic.BuildAuraLabel(entry, i) or ""
    else
      label = entry and (entry.name or ("#" .. tostring(i))) or ("#" .. tostring(i))
    end
    row.labelFS:SetText(label)

    -- parentheses
    row.parenOpen:SetChecked(entry and entry.parenOpen and true or false)
    row.parenClose:SetChecked(entry and entry.parenClose and true or false)

    -- AND/OR: only for rows < last
    if i < count then
      row.andCB:Enable()
      row.orCB:Enable()
      row.andFS:SetTextColor(1, 0.82, 0)
      row.orFS:SetTextColor(1, 0.82, 0)

      local op = (entry and entry.logicOp) or "AND"
      if op == "OR" or op == "or" then
        row.andCB:SetChecked(false)
        row.orCB:SetChecked(true)
      else
        row.andCB:SetChecked(true)
        row.orCB:SetChecked(false)
      end
    else
      -- last row: no operator
      row.andCB:SetChecked(false)
      row.orCB:SetChecked(false)
      row.andCB:Disable()
      row.orCB:Disable()
      row.andFS:SetTextColor(0.4, 0.4, 0.4)
      row.orFS:SetTextColor(0.4, 0.4, 0.4)
    end

    i = i + 1
  end

  -- hide unused rows
  local j = count + 1
  while DoiteAuraLogicFrame.rows[j] do
    DoiteAuraLogicFrame.rows[j]:Hide()
    j = j + 1
  end

  -- scroll child height based on number of rows (controls scrollbar range)
  local h = 20 + count * 20
  if h < 60 then
    h = 60
  end
  if DoiteAuraLogicFrame.scrollChild then
    DoiteAuraLogicFrame.scrollChild:SetHeight(h)
  end

  -- make sure the scrollframe reflects the height and start at the top
  if DoiteAuraLogicFrame.scrollFrame and DoiteAuraLogicFrame.scrollFrame.UpdateScrollChildRect then
    DoiteAuraLogicFrame.scrollFrame:UpdateScrollChildRect()
    DoiteAuraLogicFrame.scrollFrame:SetVerticalScroll(0)
  end

  DoiteAuraLogic_UpdatePreview()
  DoiteAuraLogic_RecomputeParenAndApplyState()
  DoiteAuraLogicFrame:Show()
end
