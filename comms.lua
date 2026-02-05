-- ShortyInterrupt - comms.lua
-- Broadcast-only interrupt tracking via addon messages + presence handshake + capabilities.
--
-- Message types:
--   I|v|spellID|cd          (interrupt broadcast)
--   L|v|csvSpellIDs         (capabilities list: interrupts I actually have)
--   R|v                     (request capabilities rebroadcast)
--   Q|v|requestID           (presence query)
--   A|v|requestID           (presence ack, whispered back to requester)
--
-- Backwards compatibility:
--   v|spellID|cd            (old interrupt format)

ShortyInterrupt_Comms = {
  PREFIX  = "ShortyINT",
  VERSION = 1,

  -- Presence
  _seenQueries = {},   -- [requestID] = true (avoid responding multiple times)
  _onPresenceAck = nil,
}

-- ==========================================
-- Helpers
-- ==========================================
local function AllowedChannel()
  -- Match ShortyRCD behavior exactly:
  -- Instance groups (LFG/Mythic+/LFR) use INSTANCE_CHAT. Raids use RAID.
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if IsInRaid() then return "RAID" end
  if IsInGroup() then return "PARTY" end
  return nil
end

local function FullPlayerName()
  local name, realm = UnitName("player")
  if not name then return nil end
  if realm and realm ~= "" then return name .. "-" .. realm end
  local myRealm = GetNormalizedRealmName()
  if myRealm and myRealm ~= "" then
    return name .. "-" .. myRealm
  end
  return name
end

local function SendToGroup(msg)
  local ch = AllowedChannel()
  if not ch then return end
  if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end

  -- Prefer ChatThrottleLib if present (like ShortyRCD)
  if ChatThrottleLib and ChatThrottleLib.SendAddonMessage then
    ChatThrottleLib:SendAddonMessage("NORMAL", ShortyInterrupt_Comms.PREFIX, msg, ch)
  else
    C_ChatInfo.SendAddonMessage(ShortyInterrupt_Comms.PREFIX, msg, ch)
  end
end

local function SendWhisper(msg, toPlayer)
  if not toPlayer or toPlayer == "" then return end
  if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end

  if ChatThrottleLib and ChatThrottleLib.SendAddonMessage then
    ChatThrottleLib:SendAddonMessage("NORMAL", ShortyInterrupt_Comms.PREFIX, msg, "WHISPER", toPlayer)
  else
    C_ChatInfo.SendAddonMessage(ShortyInterrupt_Comms.PREFIX, msg, "WHISPER", toPlayer)
  end
end

-- ==========================================
-- Init / handlers
-- ==========================================
function ShortyInterrupt_Comms:Init()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
  end
end

function ShortyInterrupt_Comms:SetPresenceAckHandler(fn)
  self._onPresenceAck = fn
end

-- =========================
-- Interrupt broadcast
-- =========================
function ShortyInterrupt_Comms:BroadcastInterrupt(spellID, cdSeconds)
  spellID = tonumber(spellID)
  cdSeconds = tonumber(cdSeconds)
  if not spellID or not cdSeconds or cdSeconds <= 0 then return end

  local msg = string.format("I|%d|%d|%d", self.VERSION, spellID, cdSeconds)
  SendToGroup(msg)
end

-- =========================
-- Capabilities (ShortyRCD-style)
-- =========================
function ShortyInterrupt_Comms:BroadcastCapabilities(spells)
  if type(spells) ~= "table" or #spells == 0 then return end

  local parts = {}
  for i = 1, #spells do
    local id = tonumber(spells[i])
    if id and (ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[id]) then
      parts[#parts + 1] = tostring(id)
    end
  end
  if #parts == 0 then return end
  table.sort(parts)

  -- L|v|147362,57994
  local msg = string.format("L|%d|%s", self.VERSION, table.concat(parts, ","))
  SendToGroup(msg)
end

function ShortyInterrupt_Comms:RequestCapabilities()
  -- R|v
  local msg = string.format("R|%d", self.VERSION)
  SendToGroup(msg)
end

-- =========================
-- Presence handshake
-- =========================
function ShortyInterrupt_Comms:BroadcastPresenceQuery(requestID)
  if not requestID or requestID == "" then return end
  local msg = string.format("Q|%d|%s", self.VERSION, requestID)
  SendToGroup(msg)
end

function ShortyInterrupt_Comms:SendPresenceAck(toPlayer, requestID)
  if not toPlayer or toPlayer == "" then return end
  if not requestID or requestID == "" then return end

  local msg = string.format("A|%d|%s", self.VERSION, requestID)
  SendWhisper(msg, toPlayer)
end

-- =========================
-- Incoming messages
-- =========================
function ShortyInterrupt_Comms:OnMessage(prefix, msg, channel, sender)
  if prefix ~= self.PREFIX then return end
  if type(msg) ~= "string" or msg == "" then return end
  if not sender or sender == "" then return end

  -- IMPORTANT:
  -- Do NOT restrict channels here. Presence ACK arrives via WHISPER.

  -- Ignore self (handle both full and short forms)
  local myFull = FullPlayerName()
  local myShort = UnitName("player")
  if (myFull and sender == myFull) or (myShort and sender == myShort) then
    return
  end

  local t1, t2, t3, t4 = strsplit("|", msg)

  -- Capabilities request: R|v
  if t1 == "R" then
    local v = tonumber(t2)
    if v ~= self.VERSION then return end

    if ShortyInterrupt and ShortyInterrupt.BroadcastMyCapabilities then
      ShortyInterrupt:BroadcastMyCapabilities("CAPS_REQUEST")
    end
    return
  end

  -- Capabilities list: L|v|csv
  if t1 == "L" then
    local v = tonumber(t2)
    if v ~= self.VERSION then return end

    local spellIDs = {}
    if type(t3) == "string" and t3 ~= "" then
      for idStr in string.gmatch(t3, "([^,]+)") do
        local id = tonumber(idStr)
        if id and (ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[id]) then
          spellIDs[#spellIDs + 1] = id
        end
      end
    end

    if ShortyInterrupt_Tracker and ShortyInterrupt_Tracker.SetRemoteCapabilities then
      ShortyInterrupt_Tracker:SetRemoteCapabilities(sender, spellIDs)
    end
    return
  end

  -- New interrupt protocol: I|v|spellID|cd
  if t1 == "I" then
    local v = tonumber(t2)
    local spellID = tonumber(t3)
    local cd = tonumber(t4)

    if v ~= self.VERSION then return end
    if not spellID or not cd or cd <= 0 then return end
    if not (ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[spellID]) then return end

    ShortyInterrupt_Tracker:Start(sender, spellID, cd)
    return
  end

  -- Presence query: Q|v|requestID
  if t1 == "Q" then
    local v = tonumber(t2)
    local requestID = t3

    if v ~= self.VERSION then return end
    if not requestID or requestID == "" then return end

    if not self._seenQueries[requestID] then
      self._seenQueries[requestID] = true
      self:SendPresenceAck(sender, requestID)
    end
    return
  end

  -- Presence ack: A|v|requestID
  if t1 == "A" then
    local v = tonumber(t2)
    local requestID = t3

    if v ~= self.VERSION then return end
    if not requestID or requestID == "" then return end

    if self._onPresenceAck then
      self._onPresenceAck(sender, requestID)
    end
    return
  end

  -- Backwards compatible interrupt format: v|spellID|cd
  local v = tonumber(t1)
  local spellID = tonumber(t2)
  local cd = tonumber(t3)

  if not v or v ~= self.VERSION then return end
  if not spellID or not cd or cd <= 0 then return end
  if not (ShortyInterrupt_Interrupts and ShortyInterrupt_Interrupts[spellID]) then return end

  ShortyInterrupt_Tracker:Start(sender, spellID, cd)
end