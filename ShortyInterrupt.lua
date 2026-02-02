-- ShortyInterrupt - ShortyInterrupt.lua
-- Step 1 + Presence handshake:
--   - Interrupt broadcast tracking (no Blizzard cooldown APIs)
--   - Group roster presence query: detect who does NOT have the addon
--   - Print a single summarized line (truncated) only when someone is missing

local ADDON = ...
local frame = CreateFrame("Frame")

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

local function IsInterruptSpell(spellID)
  return ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[spellID] ~= nil
end

local function PrintOnce(msg)
  -- Central place if you later want to route to a UI panel
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd200ShortyInterrupt:|r " .. msg)
end

-- =========================
-- Presence state (group session)
-- =========================
local Presence = {
  roster = {},        -- [name] = true (current roster snapshot)
  has = {},           -- [name] = true (confirmed has addon)
  missing = {},       -- [name] = true (we already announced missing)
  pending = nil,      -- { id=, members={...}, startedAt= }
  debounce = false,
}

local function WipePresenceSession()
  wipe(Presence.roster)
  wipe(Presence.has)
  wipe(Presence.missing)
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
  else
    -- Not grouped
  end

  return members, set
end

local function MakeRequestID()
  -- Unique enough: time + random
  return tostring(math.floor(GetTime() * 1000)) .. "-" .. tostring(math.random(1000, 9999))
end

local function SummarizeMissing(missingList)
  -- Truncate: show first N, then "+X more"
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

local function ResolvePresenceCheck(requestID)
  if not Presence.pending or Presence.pending.id ~= requestID then return end

  local pendingMembers = Presence.pending.members
  Presence.pending = nil

  local me = FullPlayerName()
  local missingNow = {}

  for _, name in ipairs(pendingMembers) do
    if name ~= me then
      -- Only care if NOT confirmed AND not already announced missing
      if not Presence.has[name] and not Presence.missing[name] then
        missingNow[#missingNow + 1] = name
      end
    end
  end

  if #missingNow > 0 then
    table.sort(missingNow)

    -- Mark as announced missing so we don't spam later
    for _, name in ipairs(missingNow) do
      Presence.missing[name] = true
    end

    local msg = SummarizeMissing(missingNow)
    if msg then
      PrintOnce(msg)
    end
  end
end

local function StartPresenceCheck(reason)
  if not IsInGroup() then return end
  if Presence.pending then return end

  local members, _ = BuildRosterSnapshot()
  if #members <= 1 then return end

  local requestID = MakeRequestID()
  Presence.pending = {
    id = requestID,
    members = members,
    startedAt = GetTime(),
  }

  ShortyInterrupt_Comms:BroadcastPresenceQuery(requestID)

  -- Wait window for replies; then mark non-responders as missing.
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

-- Called when we receive an ACK from someone
local function OnPresenceAck(sender, requestID)
  -- If we are not currently pending, still useful: cache "has addon"
  Presence.has[sender] = true

  -- (Optional) If you ever want to early-resolve, you could check if all responded,
  -- but we purposely keep it simple and deterministic: wait the timer.
end

-- =========================
-- Interrupt cast handling
-- =========================
local function OnPlayerSpellcastSucceeded(unit, castGUID, spellID)
  if unit ~= "player" then return end
  if not spellID then return end
  if not IsInterruptSpell(spellID) then return end

  local cd = ShortyInterrupt_GetEffectiveCooldown(spellID)
  if not cd or cd <= 0 then return end

  local sender = FullPlayerName() or UnitName("player")
  ShortyInterrupt_Tracker:Start(sender, spellID, cd)
  ShortyInterrupt_Comms:BroadcastInterrupt(spellID, cd)
end

-- =========================
-- Group roster change logic
-- =========================
local function HandleGroupRosterUpdate()
  if not IsInGroup() then
    -- Leaving group: clear timers and presence session
    ShortyInterrupt_Tracker:ClearAll()
    WipePresenceSession()
    return
  end

  local _, newSet = BuildRosterSnapshot()

  -- Detect new members
  local hasAny = next(Presence.roster) ~= nil
  local newJoin = false

  for name in pairs(newSet) do
    if not Presence.roster[name] then
      newJoin = true
      break
    end
  end

  -- Update roster set
  wipe(Presence.roster)
  for name in pairs(newSet) do
    Presence.roster[name] = true
  end

  -- If we just joined a group (first roster population) or someone new joined, query presence.
  if not hasAny or newJoin then
    DebouncedPresenceCheck("roster_change")
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
    math.randomseed(time())

    ShortyInterrupt_Comms:Init()
    ShortyInterrupt_Comms:SetPresenceAckHandler(OnPresenceAck)

    -- UI + options are already part of your build; leave as-is.
    ShortyInterrupt_UI:Create()
    ShortyInterrupt_UI:SetLocked(ShortyInterruptDB.ui.locked)
    ShortyInterrupt_Options:CreatePanel()

    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- If loading into an already-formed group/instance, run a check
    if IsInGroup() then
      DebouncedPresenceCheck("enter_world")
    end

  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    OnPlayerSpellcastSucceeded(...)

  elseif event == "CHAT_MSG_ADDON" then
    OnAddonMessage(...)

  elseif event == "GROUP_ROSTER_UPDATE" then
    HandleGroupRosterUpdate()
  end
end)

frame:RegisterEvent("ADDON_LOADED")