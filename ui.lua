-- ShortyInterrupt - ui.lua
-- ShortyRCD-inspired minimalist UI.
--
-- Model B visibility:
--   - Only show confirmed addon users
--   - Plus a short pending grace window during presence check
--
-- Hunter:
--   - Default to Counter Shot unless we KNOW they have Muzzle (via capability broadcast)
--
-- Raid/LFR:
--   - Hide UI completely in any raid group (ShortyRCD owns raid-scale tracking)
--
-- Visibility tweak:
--   - Normally show ONLY while in a non-raid group (party / instance party)
--   - BUT if unlocked, allow showing while solo so you can position/resize it
--   - When solo+unlocked, show 5 preview rows
--
-- Resize:
--   - When unlocked, show a bottom-right resize grip (like ShortyRCD)
--   - Manual drag-resize (no SetMinResize/StartSizing dependency)
--   - Saves size to DB (ui.w/ui.h)

ShortyInterrupt_UI = ShortyInterrupt_UI or {}
local UI = ShortyInterrupt_UI

-- -----------------------
-- Helpers
-- -----------------------
local function ShortName(nameWithRealm)
  if type(nameWithRealm) ~= "string" then return nameWithRealm end
  if Ambiguate then return Ambiguate(nameWithRealm, "short") end
  return (nameWithRealm:gsub("%-.*$", ""))
end

local function FormatTime(sec)
  sec = math.max(0, math.floor((tonumber(sec) or 0) + 0.5))
  if sec >= 3600 then
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    return ("%dh%dm"):format(h, m)
  elseif sec >= 60 then
    local m = math.floor(sec / 60)
    local s = sec % 60
    return ("%dm%02ds"):format(m, s)
  else
    return ("%ds"):format(sec)
  end
end

local function RGBToHex(r, g, b)
  r = math.max(0, math.min(1, tonumber(r) or 1))
  g = math.max(0, math.min(1, tonumber(g) or 1))
  b = math.max(0, math.min(1, tonumber(b) or 1))
  return string.format("%02x%02x%02x",
    math.floor(r*255 + 0.5),
    math.floor(g*255 + 0.5),
    math.floor(b*255 + 0.5)
  )
end

local function Clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Preferred UI font (Expressway). Place at:
-- Interface\AddOns\ShortyInterrupt\Media\Expressway.ttf
local PREFERRED_FONT = "Interface\\AddOns\\ShortyInterrupt\\Media\\Expressway.ttf"

local function GetFallbackFont()
  if GameFontNormal and GameFontNormal.GetFont then
    local f = GameFontNormal:GetFont()
    if f then return f end
  end
  return "Fonts\\FRIZQT__.TTF"
end

local function SetFontSafe(fontString, size, flags)
  if not fontString or not fontString.SetFont then return end
  size = size or 12
  flags = flags or ""
  local ok = fontString:SetFont(PREFERRED_FONT, size, flags)
  if not ok then
    fontString:SetFont(GetFallbackFont(), size, flags)
  end
end

local function EnsureDB()
  ShortyInterruptDB = ShortyInterruptDB or {}
  ShortyInterruptDB.ui = ShortyInterruptDB.ui or {}
  local ui = ShortyInterruptDB.ui

  if ui.locked == nil then ui.locked = false end
  if ui.point == nil then
    ui.point, ui.relPoint, ui.x, ui.y = "CENTER", "CENTER", 0, 0
  end

  if ui.w ~= nil then ui.w = tonumber(ui.w) end
  if ui.h ~= nil then ui.h = tonumber(ui.h) end

  return ui
end

local function GetMaxScreenWidth()
  if UIParent and UIParent.GetWidth then
    return math.max(360, UIParent:GetWidth() - 80)
  end
  return 1000
end

local function GetMaxScreenHeight()
  if UIParent and UIParent.GetHeight then
    return math.max(240, UIParent:GetHeight() - 140)
  end
  return 650
end

local function IsRaidContext()
  return IsInRaid() == true
end

local function InGroupNonRaid()
  if IsRaidContext() then return false end
  return IsInGroup() == true
end

-- -----------------------
-- Layout constants
-- -----------------------
local ROW_H   = 18
local GAP_Y   = 3
local PAD_L   = 10
local PAD_R   = 10
local PAD_B   = 8

local ICON_SZ = 16
local BAR_H   = 16

local MIN_W = 220
local MIN_H = 90

-- -----------------------
-- Interrupts indexed by class (built once)
-- -----------------------
UI.interruptsByClass = UI.interruptsByClass or nil

local function BuildInterruptsByClass()
  local map = {}
  if not ShortyInterrupt_Interrupts then return map end

  for spellID, e in pairs(ShortyInterrupt_Interrupts) do
    if e and e.class then
      map[e.class] = map[e.class] or {}
      table.insert(map[e.class], spellID)
    end
  end

  for _, list in pairs(map) do
    table.sort(list, function(a, b) return a < b end)
  end

  return map
end

-- -----------------------
-- Class mapping for roster
-- -----------------------
UI.classByName = UI.classByName or {}

function UI:RefreshRosterClasses()
  wipe(self.classByName)

  local function AddUnit(unit)
    if not UnitExists(unit) then return end
    local full = UnitName(unit)
    if not full then return end
    local short = ShortName(full)
    local _, classToken = UnitClass(unit)
    if short and classToken then
      self.classByName[short] = classToken
    end
  end

  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do AddUnit("raid" .. i) end
  elseif IsInGroup() then
    AddUnit("player")
    for i = 1, GetNumSubgroupMembers() do AddUnit("party" .. i) end
  else
    AddUnit("player")
  end
end

function UI:GetClassColorForSender(sender)
  local short = ShortName(sender)
  local classToken = self.classByName[short]
  if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
    local c = RAID_CLASS_COLORS[classToken]
    return c.r, c.g, c.b
  end
  return 0.32, 0.36, 0.42
end

-- -----------------------
-- Model B: confirmed addon users + pending grace
-- -----------------------
local function IsKnownAddonUser(shortName)
  if not ShortyInterrupt_Tracker or not ShortyInterrupt_Tracker.HasAddon then return false end
  return ShortyInterrupt_Tracker:HasAddon(shortName) == true
end

local function IsPendingGrace(shortName)
  if not ShortyInterrupt_Tracker or not ShortyInterrupt_Tracker.IsPendingGrace then return false end
  return ShortyInterrupt_Tracker:IsPendingGrace(shortName) == true
end

-- -----------------------
-- Spell selection (Hunter special case)
-- -----------------------
local function ChooseInterruptSpellForClass(classToken, shortName, spellList)
  if classToken == "HUNTER" then
    local hasMuzzle = false
    local hasCounter = false
    if ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.GetCapabilities then
      local caps = ShortyInterrupt_Tracker:GetCapabilities(shortName)
      if caps then
        if caps[187707] then hasMuzzle = true end
        if caps[147362] then hasCounter = true end
      end
    end

    if hasMuzzle then return 187707 end
    if hasCounter then return 147362 end
    return 147362 -- default
  end

  if spellList and #spellList >= 1 then
    return spellList[1]
  end
  return nil
end

-- -----------------------
-- Preview mode
-- -----------------------
function UI:IsPreviewMode()
  if IsRaidContext() then return false end
  local db = EnsureDB()
  if db.locked then return false end
  return IsInGroup() ~= true
end

local function TrimTo12(s)
  s = tostring(s or "")
  if #s > 12 then
    return string.sub(s, 1, 12)
  end
  return s
end

function UI:BuildPreviewRows()
  if not self.interruptsByClass then
    self.interruptsByClass = BuildInterruptsByClass()
  end

  local playerFull = UnitName("player") or "Player"
  local playerShort = ShortName(playerFull) or "Player"
  playerShort = TrimTo12(playerShort)

  local _, playerClass = UnitClass("player")
  if not playerClass then playerClass = "WARRIOR" end

  local playerSpell = nil
  local list = self.interruptsByClass[playerClass]
  if list and #list > 0 then
    playerSpell = ChooseInterruptSpellForClass(playerClass, playerShort, list)
  end
  if not playerSpell then
    for _, ids in pairs(self.interruptsByClass) do
      if ids and ids[1] then playerSpell = ids[1]; break end
    end
  end

  local samples = {
    { name = "Aeloria",  class = "MAGE",        spell = 2139,   rem = 9,  dur = 25 },
    { name = "Korrigan", class = "WARRIOR",     spell = 6552,   rem = 6,  dur = 15 },
    { name = "Mirella",  class = "PRIEST",      spell = 15487,  rem = 18, dur = 30 },
    { name = "Threx",    class = "DEMONHUNTER", spell = 183752, rem = 4,  dur = 15 },
  }

  for _, s in ipairs(samples) do
    if not (ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[s.spell]) then
      local l = self.interruptsByClass[s.class]
      if l and l[1] then s.spell = l[1] end
    end
  end

  -- Prime class colors so bars color correctly
  self.classByName[playerShort] = playerClass
  for _, s in ipairs(samples) do
    self.classByName[TrimTo12(s.name)] = s.class
  end

  local out = {}

  do
    local sid = playerSpell or 6552
    local entry = ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[sid]
    local spellName = entry and entry.name or "Interrupt"
    out[#out+1] = {
      sender = playerShort,
      spellID = sid,
      classToken = playerClass,
      preview = true,
      previewDuration = 15,
      previewRemaining = 7,
      previewLabel = playerShort .. "  |cff9aa7b2" .. spellName .. "|r",
    }
  end

  for _, s in ipairs(samples) do
    local n = TrimTo12(s.name)
    local entry = ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[s.spell]
    local spellName = entry and entry.name or "Interrupt"
    out[#out+1] = {
      sender = n,
      spellID = s.spell,
      classToken = s.class,
      preview = true,
      previewDuration = s.dur,
      previewRemaining = s.rem,
      previewLabel = n .. "  |cff9aa7b2" .. spellName .. "|r",
    }
  end

  return out
end

-- -----------------------
-- Real rows (group/party)
-- -----------------------
function UI:BuildRosterInterruptRows()
  if not self.interruptsByClass then
    self.interruptsByClass = BuildInterruptsByClass()
  end

  local out = {}
  local seen = {}

  local function AddMember(fullName, classToken, isPlayer)
    if not fullName or not classToken then return end
    local short = ShortName(fullName)
    if not short then return end

    if not isPlayer then
      if not IsKnownAddonUser(short) and not IsPendingGrace(short) then
        return
      end
    end

    local spellList = self.interruptsByClass[classToken]
    if not spellList or #spellList == 0 then return end

    local chosen = ChooseInterruptSpellForClass(classToken, short, spellList)
    if not chosen then return end

    if isPlayer then
      local ok = true
      if IsPlayerSpell then
        ok = IsPlayerSpell(chosen) == true
      elseif IsSpellKnown then
        ok = IsSpellKnown(chosen) == true
      end
      if not ok then return end
    end

    local key = short .. ":" .. tostring(chosen)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = {
        sender = short,
        spellID = chosen,
        classToken = classToken,
      }
    end
  end

  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local unit = "raid" .. i
      if UnitExists(unit) then
        local full = UnitName(unit)
        local _, classToken = UnitClass(unit)
        AddMember(full, classToken, UnitIsUnit(unit, "player"))
      end
    end
  elseif IsInGroup() then
    do
      local full = UnitName("player")
      local _, classToken = UnitClass("player")
      AddMember(full, classToken, true)
    end
    for i = 1, GetNumSubgroupMembers() do
      local unit = "party" .. i
      if UnitExists(unit) then
        local full = UnitName(unit)
        local _, classToken = UnitClass(unit)
        AddMember(full, classToken, false)
      end
    end
  else
    local full = UnitName("player")
    local _, classToken = UnitClass("player")
    AddMember(full, classToken, true)
  end

  table.sort(out, function(a, b)
    if a.sender ~= b.sender then return a.sender < b.sender end
    return (a.spellID or 0) < (b.spellID or 0)
  end)

  return out
end

-- -----------------------
-- Cooldown state
-- -----------------------
local function GetCooldownState(senderShort, spellID)
  if not (ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.active) then
    return nil
  end

  local spells = ShortyInterrupt_Tracker.active[senderShort]
  if not spells then return nil end

  local cd = spells[spellID]
  if not cd then return nil end

  local now = GetTime()
  local remaining = (cd.expiresAt or 0) - now
  if remaining <= 0 then
    return nil
  end

  return {
    duration = tonumber(cd.duration) or 0,
    remaining = remaining,
  }
end

-- -----------------------
-- Visibility
-- -----------------------
function UI:UpdateVisibility()
  if not self.frame then return end
  local db = EnsureDB()

  if IsRaidContext() then
    if self.frame:IsShown() then self.frame:Hide() end
    return
  end

  if InGroupNonRaid() then
    if not self.frame:IsShown() then self.frame:Show() end
    return
  end

  if db.locked == false then
    if not self.frame:IsShown() then self.frame:Show() end
  else
    if self.frame:IsShown() then self.frame:Hide() end
  end
end

-- -----------------------
-- Create frame
-- -----------------------
function UI:Create()
  if self.frame then return end
  local db = EnsureDB()

  self.rows = {}
  self._isResizing = false
  self._resizeStartX = nil
  self._resizeStartY = nil
  self._resizeStartW = nil
  self._resizeStartH = nil

  local f = CreateFrame("Frame", "ShortyInterrupt_Frame", UIParent, "BackdropTemplate")
  f:SetSize(260, 140)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")

  f:SetBackdrop({
    bgFile = "Interface/ChatFrame/ChatFrameBackground",
    edgeFile = "Interface/ChatFrame/ChatFrameBackground",
    tile = true, tileSize = 16, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 }
  })
  f:SetBackdropColor(0.07, 0.08, 0.10, 0.92)
  f:SetBackdropBorderColor(0.12, 0.13, 0.16, 1.0)

  local header = CreateFrame("Frame", nil, f, "BackdropTemplate")
  header:SetPoint("TOPLEFT", 1, -1)
  header:SetPoint("TOPRIGHT", -1, -1)
  header:SetHeight(28)
  header:SetBackdrop({
    bgFile = "Interface/ChatFrame/ChatFrameBackground",
    edgeFile = "Interface/ChatFrame/ChatFrameBackground",
    tile = true, tileSize = 16, edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
  })
  header:SetBackdropColor(0.05, 0.06, 0.08, 0.98)
  header:SetBackdropBorderColor(0.12, 0.13, 0.16, 1.0)

  local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("LEFT", 10, 0)
  title:SetText("|cffffd000Interrupts|r")
  SetFontSafe(title, 16, "")

  f:SetScript("OnDragStart", function()
    if ShortyInterruptDB and ShortyInterruptDB.ui and ShortyInterruptDB.ui.locked then return end
    if UI._isResizing then return end
    f:StartMoving()
  end)
  f:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    UI:SavePosition()
  end)

  local list = CreateFrame("Frame", nil, f)
  list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", PAD_L, -8)
  list:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD_L, PAD_B)
  list:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD_R, -36)

  -- Resize grip (manual resize; no StartSizing dependency)
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  grip:EnableMouse(true)

  local tex = grip:CreateTexture(nil, "OVERLAY")
  tex:SetAllPoints()
  tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip.tex = tex

  grip:SetScript("OnEnter", function()
    local db2 = EnsureDB()
    if db2.locked then return end
    grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  end)

  grip:SetScript("OnLeave", function()
    local db2 = EnsureDB()
    if db2.locked then return end
    grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  end)

  grip:SetScript("OnMouseDown", function(_, btn)
    if btn ~= "LeftButton" then return end
    local db2 = EnsureDB()
    if db2.locked then return end

    UI._isResizing = true
    grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

    local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale

    UI._resizeStartX = x
    UI._resizeStartY = y
    UI._resizeStartW = f:GetWidth()
    UI._resizeStartH = f:GetHeight()
  end)

  grip:SetScript("OnMouseUp", function(_, btn)
    if btn ~= "LeftButton" then return end
    if not UI._isResizing then return end

    UI._isResizing = false

    local maxW = GetMaxScreenWidth()
    local maxH = GetMaxScreenHeight()

    local db2 = EnsureDB()
    db2.w = Clamp(f:GetWidth(), MIN_W, maxW)
    db2.h = Clamp(f:GetHeight(), MIN_H, maxH)

    UI:SavePosition()
    UI:UpdateBoard()

    if not db2.locked then
      grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    end
  end)

  self.frame = f
  self.header = header
  self.title = title
  self.list = list
  self.resizeGrip = grip

  self:RestorePosition()

  if db.w and db.h then
    f:SetSize(Clamp(db.w, MIN_W, GetMaxScreenWidth()), Clamp(db.h, MIN_H, GetMaxScreenHeight()))
  end

  self:ApplyLockState()

  f:SetScript("OnEvent", function(_, event)
    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
      UI:UpdateVisibility()
      if UI.frame and UI.frame:IsShown() then
        UI:RefreshRosterClasses()
      end
      UI:UpdateBoard()
    end
  end)
  f:RegisterEvent("GROUP_ROSTER_UPDATE")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")

  self:UpdateVisibility()
  if self.frame and self.frame:IsShown() then
    self:RefreshRosterClasses()
  end

  -- One OnUpdate loop does both:
  -- - resizing when active
  -- - normal UI refresh tick when not resizing
  self.accum = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    -- Manual resize live-update (prevents snap-back)
    if UI._isResizing then
      local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
      local x, y = GetCursorPosition()
      x, y = x / scale, y / scale

      local dx = x - (UI._resizeStartX or x)
      local dy = (UI._resizeStartY or y) - y -- drag down increases height

      local startW = UI._resizeStartW or f:GetWidth()
      local startH = UI._resizeStartH or f:GetHeight()

      local maxW = GetMaxScreenWidth()
      local maxH = GetMaxScreenHeight()

      local newW = Clamp(startW + dx, MIN_W, maxW)
      local newH = Clamp(startH + dy, MIN_H, maxH)

      f:SetSize(newW, newH)
      return
    end

    UI.accum = UI.accum + elapsed
    if UI.accum >= 0.10 then
      UI.accum = 0
      if ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.PruneExpired then
        ShortyInterrupt_Tracker:PruneExpired()
      end
      UI:UpdateBoard()
    end
  end)
end

-- -----------------------
-- Row pool
-- -----------------------
function UI:EnsureRow(i)
  if self.rows[i] then return self.rows[i] end

  local parent = self.list
  local r = CreateFrame("Frame", nil, parent)
  r:SetSize(220, ROW_H)

  local bg = CreateFrame("Frame", nil, r, "BackdropTemplate")
  bg:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
  bg:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
  bg:SetBackdrop({
    bgFile = "Interface/ChatFrame/ChatFrameBackground",
    edgeFile = "Interface/ChatFrame/ChatFrameBackground",
    tile = true, tileSize = 16, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 }
  })
  bg:SetBackdropColor(0.05, 0.06, 0.08, 0.55)
  bg:SetBackdropBorderColor(0.12, 0.13, 0.16, 0.9)

  local icon = r:CreateTexture(nil, "ARTWORK")
  icon:SetSize(ICON_SZ, ICON_SZ)
  icon:SetPoint("LEFT", r, "LEFT", 4, 0)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  local barBG = CreateFrame("Frame", nil, r, "BackdropTemplate")
  barBG:SetPoint("LEFT", icon, "RIGHT", 6, 0)
  barBG:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  barBG:SetHeight(BAR_H)
  barBG:SetBackdrop({
    bgFile = "Interface/ChatFrame/ChatFrameBackground",
    edgeFile = "Interface/ChatFrame/ChatFrameBackground",
    tile = true, tileSize = 16, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 }
  })
  barBG:SetBackdropColor(0.03, 0.03, 0.04, 0.85)
  barBG:SetBackdropBorderColor(0.14, 0.15, 0.18, 1.0)

  local bar = CreateFrame("StatusBar", nil, barBG)
  bar:SetPoint("TOPLEFT", barBG, "TOPLEFT", 1, -1)
  bar:SetPoint("BOTTOMRIGHT", barBG, "BOTTOMRIGHT", -1, 1)
  bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(1)

  local timer = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  timer:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
  timer:SetJustifyH("RIGHT")
  timer:SetWidth(58)
  SetFontSafe(timer, 12, "")

  local label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", bar, "LEFT", 5, 0)
  label:SetPoint("RIGHT", timer, "LEFT", -6, 0)
  label:SetJustifyH("LEFT")
  SetFontSafe(label, 12, "")

  r.bg = bg
  r.icon = icon
  r.barBG = barBG
  r.bar = bar
  r.label = label
  r.timer = timer

  self.rows[i] = r
  return r
end

function UI:HideExtraRows(fromIndex)
  for i = fromIndex, #self.rows do
    self.rows[i]:Hide()
  end
end

-- -----------------------
-- Rendering
-- -----------------------
function UI:UpdateBoard()
  if not self.frame then return end
  if not ShortyInterrupt_Interrupts then return end

  self:UpdateVisibility()
  if not (self.frame and self.frame:IsShown()) then return end

  local previewMode = self:IsPreviewMode()
  local rosterRows = previewMode and self:BuildPreviewRows() or self:BuildRosterInterruptRows()

  local maxW = GetMaxScreenWidth()
  local maxH = GetMaxScreenHeight()

  local autoW = 260
  local autoH = 28 + 8 + PAD_B + math.max(1, #rosterRows) * (ROW_H + GAP_Y)
  autoH = math.min(maxH, math.max(MIN_H, autoH))
  autoW = math.min(maxW, math.max(MIN_W, autoW))

  local db = EnsureDB()

  -- Only force sizing when NOT actively resizing
  if not self._isResizing then
    local desiredW = autoW
    local desiredH = autoH

    if db.w and db.h then
      desiredW = Clamp(db.w, MIN_W, maxW)
      desiredH = Clamp(db.h, MIN_H, maxH)
    end

    self.frame:SetSize(desiredW, desiredH)
  end

  local y = 0
  for i = 1, #rosterRows do
    local d = rosterRows[i]
    local r = self:EnsureRow(i)

    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, -y)
    r:SetPoint("TOPRIGHT", self.list, "TOPRIGHT", 0, -y)
    r:SetHeight(ROW_H)

    local sender = d.sender or "?"
    local cr, cg, cb = self:GetClassColorForSender(sender)
    local senderHex = RGBToHex(cr, cg, cb)

    local labelText
    if previewMode and d.previewLabel then
      labelText = ("|cff%s%s|r"):format(senderHex, d.previewLabel)
    else
      labelText = ("|cff%s%s|r"):format(senderHex, sender)
    end

    local entry = ShortyInterrupt_Interrupts[d.spellID]
    local iconID = entry and entry.iconID
    if iconID then
      r.icon:SetTexture(iconID)
    else
      r.icon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")
    end

    local st
    if previewMode and d.preview then
      st = { duration = tonumber(d.previewDuration) or 15, remaining = tonumber(d.previewRemaining) or 7 }
    else
      st = GetCooldownState(sender, d.spellID)
    end

    local progress = 1
    local remaining = 0
    local total = 1

    if st then
      total = st.duration > 0 and st.duration or 1
      remaining = st.remaining > 0 and st.remaining or 0
      progress = math.max(0, math.min(1, remaining / total))
    else
      progress = 1
    end

    r.bar:SetMinMaxValues(0, 1)
    r.bar:SetValue(progress)
    r.bar:SetStatusBarColor(cr, cg, cb, 0.90)

    r.label:SetText(labelText)
    r.label:SetTextColor(0.78, 0.80, 0.84, 1.0)

    if st then
      r.timer:SetText(FormatTime(remaining))
      r.timer:SetTextColor(0.90, 0.92, 0.96, 1.0)
    else
      r.timer:SetText("")
    end

    r:Show()
    y = y + ROW_H + GAP_Y
  end

  if #rosterRows == 0 then
    local r = self:EnsureRow(1)
    r.icon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")
    r.bar:SetMinMaxValues(0, 1)
    r.bar:SetValue(1)
    r.bar:SetStatusBarColor(0.12, 0.14, 0.18, 0.65)
    r.label:SetText("|cffcfd8dcNo roster|r")
    r.timer:SetText("")
    r:Show()
    self:HideExtraRows(2)
  else
    self:HideExtraRows(#rosterRows + 1)
  end

  -- Resize grip visibility
  if self.resizeGrip then
    if db.locked then
      self.resizeGrip:Hide()
    else
      if self.frame:IsShown() then self.resizeGrip:Show() else self.resizeGrip:Hide() end
    end
  end
end

function UI:Refresh()
  if not self.frame then return end
  self:UpdateBoard()
end

-- -----------------------
-- Position save/restore
-- -----------------------
function UI:SavePosition()
  if not self.frame then return end
  local point, relTo, relPoint, x, y = self.frame:GetPoint(1)
  local relName = (relTo and relTo.GetName and relTo:GetName()) or "UIParent"

  local db = EnsureDB()
  db.point = point
  db.relPoint = relPoint
  db.x = x
  db.y = y
  db.relName = relName
end

function UI:RestorePosition()
  if not self.frame then return end
  local db = EnsureDB()
  local rel = UIParent
  if db.relName and _G[db.relName] then
    rel = _G[db.relName]
  end
  self.frame:ClearAllPoints()
  self.frame:SetPoint(db.point or "CENTER", rel, db.relPoint or "CENTER", db.x or 0, db.y or 0)
end

-- -----------------------
-- Locking
-- -----------------------
function UI:SetLocked(locked)
  local db = EnsureDB()
  db.locked = (locked == true)
  self:ApplyLockState()
  self:UpdateVisibility()
  self:UpdateBoard()
end

function UI:ApplyLockState()
  if not self.frame then return end
  local db = EnsureDB()
  local locked = db.locked == true

  self.frame:EnableMouse(not locked)

  if self.resizeGrip then
    if locked then
      self.resizeGrip:Hide()
      if self.resizeGrip.tex then
        self.resizeGrip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
      end
    else
      if self.frame:IsShown() then
        self.resizeGrip:Show()
      else
        self.resizeGrip:Hide()
      end
      if self.resizeGrip.tex then
        self.resizeGrip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
      end
    end
  end

  if locked then
    self.frame:SetBackdropColor(0.07, 0.08, 0.10, 0.00)
    self.frame:SetBackdropBorderColor(0.12, 0.13, 0.16, 0.00)

    if self.header then
      self.header:SetBackdropColor(0.05, 0.06, 0.08, 0.00)
      self.header:SetBackdropBorderColor(0.12, 0.13, 0.16, 0.00)
    end

    if self.title then
      self.title:SetAlpha(0.0)
    end
  else
    self.frame:SetBackdropColor(0.07, 0.08, 0.10, 0.92)
    self.frame:SetBackdropBorderColor(0.12, 0.13, 0.16, 1.00)

    if self.header then
      self.header:SetBackdropColor(0.05, 0.06, 0.08, 0.98)
      self.header:SetBackdropBorderColor(0.12, 0.13, 0.16, 1.00)
    end

    if self.title then
      self.title:SetAlpha(1.0)
    end
  end
end