-- ShortyInterrupt - ShortyInterrupt.lua
-- Interrupt tracking via broadcasts only (NO Blizzard cooldown APIs).
--
-- Rules enforced:
--  - Never use Blizzard cooldown APIs for interrupts
--  - Broadcast-only tracking
--
-- Adds:
--  - Presence handshake (who has addon)
--  - Capability exchange (what interrupt spells a player actually has)
--  - Raid/LFR: suppress behavior (ShortyRCD handles raid-scale)

local ADDON = ...
local frame = CreateFrame("Frame")

ShortyInterrupt = ShortyInterrupt or {}

-- Forward declarations (prevents nil global calls due to definition order)
local RequestCapabilitiesExchange
local HandleGroupRosterUpdate
local OnPlayerSpellcastSucceeded
local OnPresenceAck

-- =========================
-- DB / helpers
-- =========================
local function EnsureDB()
  ShortyInterruptDB = ShortyInterruptDB or {}
  ShortyInterruptDB.ui = ShortyInterruptDB.ui or {}
  if ShortyInterruptDB.ui.locked == nil then
    ShortyInterruptDB.ui.locked = false
  end
end

local function FullNameFromUnit(unit)
  local name, realm = UnitName(unit)
  if not name then return nil end
  if realm and realm ~= "" then return name .. "-" .. realm end
  local myRealm = GetNormalizedRealmName()
  if myRealm and myRealm ~= "" then
    return name .. "-" .. myRealm
  end
  return name
end

local function FullPlayerName()
  return FullNameFromUnit("player")
end

local function ShortName(nameWithRealm)
  if type(nameWithRealm) ~= "string" then return nameWithRealm end
  if Ambiguate then return Ambiguate(nameWithRealm, "short") end
  return (nameWithRealm:gsub("%-.*$", ""))
end

local function IsInterruptSpell(spellID)
  return ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[spellID] ~= nil
end

local function PrintOnce(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd200ShortyInterrupt:|r " .. msg)
end

local function IsRaidContext()
  -- Any raid group (including LFR) => ShortyInterrupt behavior suppressed
  return IsInRaid() == true
end

-- =========================
-- #4: TX de-dupe + throttle (local-side)
-- =========================
-- Never delays; only suppresses duplicates.
local _recentCastGUID = {}  -- [castGUID] = time
local _recentSpellTX  = {}  -- [spellID]  = time
local _lastPruneAt = 0

local function PruneTXCaches(now)
  if (now - _lastPruneAt) < 2.0 then return end
  _lastPruneAt = now

  for guid, t in pairs(_recentCastGUID) do
    if (now - t) > 3.0 then
      _recentCastGUID[guid] = nil
    end
  end

  for spellID, t in pairs(_recentSpellTX) do
    if (now - t) > 3.0 then
      _recentSpellTX[spellID] = nil
    end
  end
end

local function ShouldTransmitInterrupt(castGUID, spellID)
  local now = GetTime()
  PruneTXCaches(now)

  -- De-dupe same cast firing twice
  if castGUID and castGUID ~= "" then
    local last = _recentCastGUID[castGUID]
    if last and (now - last) < 0.60 then
      return false
    end
    _recentCastGUID[castGUID] = now
  end

  -- Tiny per-spell throttle (covers edge cases where castGUID differs)
  spellID = tonumber(spellID)
  if spellID then
    local last = _recentSpellTX[spellID]
    if last and (now - last) < 0.25 then
      return false
    end
    _recentSpellTX[spellID] = now
  end

  return true
end

-- =========================
-- Presence state (group session)
-- =========================
local Presence = {
  roster = {},        -- [name] = true (current roster snapshot)
  has = {},           -- [fullName] = true (confirmed has addon)
  missing = {},       -- [fullName] = true (we already announced missing)
  pending = nil,      -- { id=, members={...}, startedAt= }
  debounce = false,

  -- Model B grace window: show briefly while waiting for ACKs
  pendingUntil = {},  -- [shortName] = expiresAt
}

ShortyInterrupt.Presence = Presence

local function WipePresenceSession()
  wipe(Presence.roster)
  wipe(Presence.has)
  wipe(Presence.missing)
  wipe(Presence.pendingUntil)
  Presence.pending = nil
  Presence.debounce = false
end

local function BuildRosterSnapshot()
  local members = {}
  local set = {}

  if IsInRaid() then
    local n = GetNumGroupMembers()
    for i = 1, n do
      local unit = "raid" .. i
      local full = FullNameFromUnit(unit)
      if full and not set[full] then
        set[full] = true
        members[#members + 1] = full
      end
    end
  elseif IsInGroup() then
    local me = FullPlayerName()
    if me then
      set[me] = true
      members[#members + 1] = me
    end
    local n = GetNumSubgroupMembers()
    for i = 1, n do
      local unit = "party" .. i
      local full = FullNameFromUnit(unit)
      if full and not set[full] then
        set[full] = true
        members[#members + 1] = full
      end
    end
  end

  return members, set
end

-- Avoid math.random/randomseed (restricted in modern WoW sandbox sometimes)
local _reqCounter = 0
local function MakeRequestID()
  _reqCounter = _reqCounter + 1
  local guid = UnitGUID("player") or "noguid"
  return tostring(math.floor(GetTime() * 1000)) .. "-" .. tostring(_reqCounter) .. "-" .. guid
end

local function SummarizeMissing(missingList)
  local total = #missingList
  if total <= 0 then return nil end

  local maxShow = 6
  local shown = {}
  local showN = math.min(maxShow, total)
  for i = 1, showN do
    shown[#shown + 1] = missingList[i]
  end

  local extra = total - showN
  if extra > 0 then
    return string.format("ShortyInterrupt missing: %d players (%s +%d more)", total, table.concat(shown, ", "), extra)
  end
  return string.format("ShortyInterrupt missing: %d players (%s)", total, table.concat(shown, ", "))
end

local function MarkPendingGrace(members, seconds)
  local untilT = GetTime() + (seconds or 2.8)
  for _, full in ipairs(members or {}) do
    local short = ShortName(full)
    if short and short ~= "" then
      Presence.pendingUntil[short] = untilT
    end
  end
end

local function ResolvePresenceCheck(requestID)
  if not Presence.pending or Presence.pending.id ~= requestID then return end

  local pendingMembers = Presence.pending.members
  Presence.pending = nil

  local me = FullPlayerName()
  local missingNow = {}

  for _, fullName in ipairs(pendingMembers) do
    if fullName ~= me then
      if not Presence.has[fullName] and not Presence.missing[fullName] then
        missingNow[#missingNow + 1] = fullName
      end
    end
  end

  if #missingNow > 0 then
    table.sort(missingNow)

    for _, fullName in ipairs(missingNow) do
      Presence.missing[fullName] = true
      Presence.pendingUntil[ShortName(fullName)] = nil
    end

    local msg = SummarizeMissing(missingNow)
    if msg then PrintOnce(msg) end
  end

  if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then
    ShortyInterrupt_UI:Refresh()
  end
end

local function StartPresenceCheck(reason)
  if IsRaidContext() then return end
  if not IsInGroup() then return end
  if Presence.pending then return end

  local members = BuildRosterSnapshot()
  if #members <= 1 then return end

  local requestID = MakeRequestID()
  Presence.pending = {
    id = requestID,
    members = members,
    startedAt = GetTime(),
  }

  MarkPendingGrace(members, 2.8)
  ShortyInterrupt_Comms:BroadcastPresenceQuery(requestID)

  C_Timer.After(2.5, function()
    ResolvePresenceCheck(requestID)
  end)
end

local function DebouncedPresenceCheck(reason)
  if Presence.debounce then return end
  Presence.debounce = true
  C_Timer.After(0.8, function()
    Presence.debounce = false
    StartPresenceCheck(reason)
  end)
end

OnPresenceAck = function(sender, requestID)
  Presence.has[sender] = true
  Presence.pendingUntil[ShortName(sender)] = nil

  if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then
    ShortyInterrupt_UI:Refresh()
  end
end

-- Optional helper for UI to decide if a row should show (Model B behavior)
function ShortyInterrupt:ShouldShowSender(senderShort, senderFull)
  if IsRaidContext() then return false end

  local now = GetTime()
  if senderShort and Presence.pendingUntil[senderShort] and Presence.pendingUntil[senderShort] > now then
    return true
  end

  if senderFull and Presence.has[senderFull] then
    return true
  end

  if senderShort then
    for full in pairs(Presence.has) do
      if ShortName(full) == senderShort then
        return true
      end
    end
  end

  return false
end

-- =========================
-- Capabilities (what interrupts I actually have)
-- =========================
local _lastCapsAt = 0
local _lastCapsReqAt = 0

local function ThrottleCaps(sec)
  local now = GetTime()
  if (now - _lastCapsAt) < (sec or 1.0) then return true end
  _lastCapsAt = now
  return false
end

local function ThrottleCapsReq(sec)
  local now = GetTime()
  if (now - _lastCapsReqAt) < (sec or 2.0) then return true end
  _lastCapsReqAt = now
  return false
end

function ShortyInterrupt:GetMyInterruptCapabilities()
  local spells = {}
  if not ShortyInterrupt_Interrupts then return spells end

  for spellID in pairs(ShortyInterrupt_Interrupts) do
    local ok = false
    if IsPlayerSpell then
      ok = IsPlayerSpell(spellID) == true
    elseif IsSpellKnown then
      ok = IsSpellKnown(spellID) == true
    end
    if ok then spells[#spells + 1] = spellID end
  end

  table.sort(spells)
  return spells
end

function ShortyInterrupt:BroadcastMyCapabilities(reason)
  if ThrottleCaps(1.0) then return end

  local spells = self:GetMyInterruptCapabilities()

  -- Update local tracker immediately (so UI can use it)
  if ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.SetRemoteCapabilities then
    ShortyInterrupt_Tracker:SetRemoteCapabilities(FullPlayerName() or UnitName("player"), spells)
  end

  if IsRaidContext() then
    if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then ShortyInterrupt_UI:Refresh() end
    return
  end
  if not IsInGroup() then return end

  if ShortyInterrupt_Comms and ShortyInterrupt_Comms.BroadcastCapabilities and #spells > 0 then
    ShortyInterrupt_Comms:BroadcastCapabilities(spells)
  end
end

-- FIXED: RequestCapabilitiesExchange is forward-declared above, assigned here
RequestCapabilitiesExchange = function(reason)
  if IsRaidContext() then return end
  if not IsInGroup() then return end
  if ThrottleCapsReq(2.0) then return end

  if ShortyInterrupt_Comms and ShortyInterrupt_Comms.RequestCapabilities then
    ShortyInterrupt_Comms:RequestCapabilities()
  end

  if ShortyInterrupt and ShortyInterrupt.BroadcastMyCapabilities then
    ShortyInterrupt:BroadcastMyCapabilities(reason or "CAPS_EXCHANGE")
  end
end

-- =========================
-- Interrupt cast handling
-- =========================
OnPlayerSpellcastSucceeded = function(unit, castGUID, spellID)
  if unit ~= "player" then return end
  if not spellID then return end
  if not IsInterruptSpell(spellID) then return end
  if IsRaidContext() then return end

  local cd = ShortyInterrupt_GetEffectiveCooldown(spellID)
  if not cd or cd <= 0 then return end

  local sender = FullPlayerName() or UnitName("player")

  -- Always start local timer immediately
  if ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.Start then
    ShortyInterrupt_Tracker:Start(sender, spellID, cd)
  end

  -- #4: De-dupe + throttle transmission only
  if ShouldTransmitInterrupt(castGUID, spellID) then
    ShortyInterrupt_Comms:BroadcastInterrupt(spellID, cd)
  end
end

-- =========================
-- Group roster change logic
-- =========================
HandleGroupRosterUpdate = function()
  if IsRaidContext() then
    if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then ShortyInterrupt_UI:Refresh() end
    return
  end

  if not IsInGroup() then
    if ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.ClearAll then
      ShortyInterrupt_Tracker:ClearAll()
    end
    WipePresenceSession()
    return
  end

  local members, newSet = BuildRosterSnapshot()

  local hasAny = next(Presence.roster) ~= nil
  local newJoin = false
  for name in pairs(newSet) do
    if not Presence.roster[name] then
      newJoin = true
      break
    end
  end

  wipe(Presence.roster)
  for name in pairs(newSet) do
    Presence.roster[name] = true
  end

  MarkPendingGrace(members, 2.8)

  if not hasAny or newJoin then
    DebouncedPresenceCheck("roster_change")
    RequestCapabilitiesExchange("ROSTER_CHANGE")
  end

  -- keep our own caps fresh (cheap + throttled)
  if ShortyInterrupt and ShortyInterrupt.BroadcastMyCapabilities then
    ShortyInterrupt:BroadcastMyCapabilities("ROSTER_UPDATE")
  end
end

-- =========================
-- Addon message handler
-- =========================
local function OnAddonMessage(prefix, msg, channel, sender)
  ShortyInterrupt_Comms:OnMessage(prefix, msg, channel, sender)
end

-- =========================
-- Events
-- =========================
frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name ~= ADDON then return end

    EnsureDB()

    ShortyInterrupt_Comms:Init()
    ShortyInterrupt_Comms:SetPresenceAckHandler(OnPresenceAck)

    ShortyInterrupt_UI:Create()
    ShortyInterrupt_UI:SetLocked(ShortyInterruptDB.ui.locked)
    ShortyInterrupt_Options:CreatePanel()

    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_TALENT_UPDATE")
    frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- If loading into an already-formed group/instance, run checks
    if IsInGroup() and not IsRaidContext() then
      DebouncedPresenceCheck("enter_world")
      RequestCapabilitiesExchange("PLAYER_ENTERING_WORLD")
    else
      if ShortyInterrupt and ShortyInterrupt.BroadcastMyCapabilities then
        ShortyInterrupt:BroadcastMyCapabilities("ENTER_WORLD_SOLO_OR_RAID")
      end
    end

    if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then
      ShortyInterrupt_UI:Refresh()
    end

  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, castGUID, spellID = ...
    OnPlayerSpellcastSucceeded(unit, castGUID, spellID)

  elseif event == "CHAT_MSG_ADDON" then
    OnAddonMessage(...)

  elseif event == "GROUP_ROSTER_UPDATE" then
    HandleGroupRosterUpdate()

  elseif event == "PLAYER_TALENT_UPDATE"
      or event == "TRAIT_CONFIG_UPDATED"
      or event == "PLAYER_SPECIALIZATION_CHANGED" then

    if ShortyInterrupt and ShortyInterrupt.BroadcastMyCapabilities then
      ShortyInterrupt:BroadcastMyCapabilities(event)
    end

    if IsInGroup() and not IsRaidContext() then
      RequestCapabilitiesExchange(event)
      DebouncedPresenceCheck("spec_change")
    end

    if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then
      ShortyInterrupt_UI:Refresh()
    end
  end
end)

-- ======================
-- Slash Commands
-- ======================

SLASH_SHORTYINT1 = "/shortyint"
SLASH_SHORTYINT2 = "/sint"

SlashCmdList["SHORTYINT"] = function(msg)
  msg = msg and msg:lower():trim() or ""

  if msg == "" or msg == "help" then
    print("|cffffcc00ShortyInterrupt commands:|r")
    print("/shortyint lock   - Lock frame")
    print("/shortyint unlock - Unlock frame")
    print("/shortyint reset  - Reset frame position")
    print("/shortyint clear  - Clear active timers")
    return
  end

  if msg == "lock" then
    ShortyInterruptDB.ui.locked = true
    if ShortyInterrupt_UI then ShortyInterrupt_UI:SetLocked(true) end
    print("ShortyInterrupt: frame locked")
    return
  end

  if msg == "unlock" then
    ShortyInterruptDB.ui.locked = false
    if ShortyInterrupt_UI then ShortyInterrupt_UI:SetLocked(false) end
    print("ShortyInterrupt: frame unlocked")
    return
  end

  if msg == "reset" then
    ShortyInterruptDB.ui.point = "CENTER"
    ShortyInterruptDB.ui.relPoint = "CENTER"
    ShortyInterruptDB.ui.x = 0
    ShortyInterruptDB.ui.y = 0

    if ShortyInterrupt_UI and ShortyInterrupt_UI.frame then
      local f = ShortyInterrupt_UI.frame
      f:ClearAllPoints()
      f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    print("ShortyInterrupt: frame position reset")
    return
  end

  if msg == "clear" then
    if ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.ClearAll then
      ShortyInterrupt_Tracker:ClearAll()
    end
    print("ShortyInterrupt: timers cleared")
    return
  end

  print("ShortyInterrupt: unknown command. Type /shortyint help")
end

frame:RegisterEvent("ADDON_LOADED")