-- ShortyInterrupt - options.lua
-- Minimal options panel:
--   - Lock frame toggle
--   - Reset position
--   - Test bars (debug helper)

ShortyInterrupt_Options = {}

local function EnsureDB()
  ShortyInterruptDB = ShortyInterruptDB or {}
  ShortyInterruptDB.ui = ShortyInterruptDB.ui or {}

  local ui = ShortyInterruptDB.ui
  if ui.locked == nil then ui.locked = false end

  if ui.point == nil then
    ui.point, ui.relPoint, ui.x, ui.y = "CENTER", "CENTER", 0, 0
  end

  return ui
end

local function RegisterOptionsPanel(panel, name)
  -- Retail / modern client (Dragonflight+ / 10.0+ / 12.0+)
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local category = Settings.RegisterCanvasLayoutCategory(panel, name or panel.name or "ShortyInterrupt")
    Settings.RegisterAddOnCategory(category)
    return
  end

  -- Legacy fallback
  if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
    return
  end

  -- If neither exists, just do nothing (panel won't be accessible, but addon won't error)
end


local function ApplyFramePosition()
  if not (ShortyInterrupt_UI and ShortyInterrupt_UI.frame) then return end

  local ui = EnsureDB()
  local f = ShortyInterrupt_UI.frame

  f:ClearAllPoints()
  f:SetPoint(ui.point, UIParent, ui.relPoint, ui.x, ui.y)
end

local function ResetPosition()
  local ui = EnsureDB()
  ui.point, ui.relPoint, ui.x, ui.y = "CENTER", "CENTER", 0, 0
  ApplyFramePosition()

  if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then
    ShortyInterrupt_UI:Refresh()
  end
end

local function SpawnTestBars()
  -- Creates a few fake cooldowns so UI can be tested without casting.
  local me = UnitName("player") or "Player"
  ShortyInterrupt_Tracker:Start(me, 57994, 12)        -- Wind Shear
  ShortyInterrupt_Tracker:Start("MageFriend-Realm", 2139, 25) -- Counterspell
  ShortyInterrupt_Tracker:Start("RogueFriend-Realm", 1766, 15) -- Kick
end

function ShortyInterrupt_Options:CreatePanel()
  if self.panel then return end
  EnsureDB()

  local p = CreateFrame("Frame", "ShortyInterruptOptionsPanel", UIParent)
  p.name = "ShortyInterrupt"

  local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("ShortyInterrupt")

  local sub = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  sub:SetText("Broadcast-only interrupt tracker. No Blizzard cooldown API sampling.")

  -- Lock checkbox
  local lock = CreateFrame("CheckButton", nil, p, "InterfaceOptionsCheckButtonTemplate")
  lock:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -18)
  lock.Text:SetText("Lock frame (disable dragging)")

  lock:SetScript("OnShow", function(selfBtn)
    local ui = EnsureDB()
    selfBtn:SetChecked(ui.locked and true or false)
  end)

  lock:SetScript("OnClick", function(selfBtn)
    local ui = EnsureDB()
    ui.locked = selfBtn:GetChecked() and true or false
    if ShortyInterrupt_UI and ShortyInterrupt_UI.SetLocked then
      ShortyInterrupt_UI:SetLocked(ui.locked)
    end
  end)

  -- Reset position button
  local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  reset:SetSize(140, 22)
  reset:SetPoint("TOPLEFT", lock, "BOTTOMLEFT", 0, -14)
  reset:SetText("Reset Position")
  reset:SetScript("OnClick", function()
    ResetPosition()
  end)

  -- Test bars button
  local test = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  test:SetSize(140, 22)
  test:SetPoint("LEFT", reset, "RIGHT", 10, 0)
  test:SetText("Test Bars")
  test:SetScript("OnClick", function()
    SpawnTestBars()
  end)

  -- Helpful hint text
  local hint = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", reset, "BOTTOMLEFT", 0, -10)
  hint:SetText("Tip: Use 'Test Bars' to verify the UI without casting an interrupt.")

  RegisterOptionsPanel(p, "ShortyInterrupt")
  self.panel = p
end