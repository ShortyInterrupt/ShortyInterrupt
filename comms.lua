-- ShortyInterrupt - comms.lua
-- Broadcast-only interrupt tracking via addon messages + presence handshake.
--
-- Message types:
--   I|v|spellID|cd          (interrupt broadcast)
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

local function GetGroupChannel()
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    return "INSTANCE_CHAT"
  end
  if IsInRaid() then
    return "RAID"
  end
  if IsInGroup() then
    return "PARTY"
  end
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

function ShortyInterrupt_Comms:Init()
  C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
end

function ShortyInterrupt_Comms:SetPresenceAckHandler(fn)
  self._onPresenceAck = fn
end

-- =========================
-- Interrupt broadcast
-- =========================
function ShortyInterrupt_Comms:BroadcastInterrupt(spellID, cdSeconds)
  local channel = GetGroupChannel()
  if not channel then return end

  spellID = tonumber(spellID)
  cdSeconds = tonumber(cdSeconds)
  if not spellID or not cdSeconds or cdSeconds <= 0 then return end

  local msg = string.format("I|%d|%d|%d", self.VERSION, spellID, cdSeconds)
  C_ChatInfo.SendAddonMessage(self.PREFIX, msg, channel)
end

-- =========================
-- Presence handshake
-- =========================
function ShortyInterrupt_Comms:BroadcastPresenceQuery(requestID)
  local channel = GetGroupChannel()
  if not channel then return end
  if not requestID or requestID == "" then return end

  local msg = string.format("Q|%d|%s", self.VERSION, requestID)
  C_ChatInfo.SendAddonMessage(self.PREFIX, msg, channel)
end

function ShortyInterrupt_Comms:SendPresenceAck(toPlayer, requestID)
  if not toPlayer or toPlayer == "" then return end
  if not requestID or requestID == "" then return end

  local msg = string.format("A|%d|%s", self.VERSION, requestID)
  C_ChatInfo.SendAddonMessage(self.PREFIX, msg, "WHISPER", toPlayer)
end

-- =========================
-- Incoming messages
-- =========================
function ShortyInterrupt_Comms:OnMessage(prefix, msg, channel, sender)
  if prefix ~= self.PREFIX then return end
  if type(msg) ~= "string" or msg == "" then return end
  if not sender or sender == "" then return end

  local myFull = FullPlayerName()
  if myFull and sender == myFull then
    -- Ignore self
    return
  end

  local t1, t2, t3, t4 = strsplit("|", msg)

  -- New protocol
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

  if t1 == "Q" then
    local v = tonumber(t2)
    local requestID = t3

    if v ~= self.VERSION then return end
    if not requestID or requestID == "" then return end

    -- Respond only once per requestID (avoid loops / spam)
    if not self._seenQueries[requestID] then
      self._seenQueries[requestID] = true
      self:SendPresenceAck(sender, requestID)
    end
    return
  end

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