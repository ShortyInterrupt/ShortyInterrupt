-- ShortyInterrupt - tracker.lua
-- Stores interrupt cooldown timers that were started locally:
--   - from your own casts (ShortyInterrupt.lua)
--   - from received addon broadcasts (comms.lua)
--
-- No Blizzard cooldown APIs. Pure GetTime() math.

ShortyInterrupt_Tracker = {
  active = {}, -- [sender] = { [spellID] = { startAt=number, duration=number, expiresAt=number } }
}

local function SenderKey(sender)
  return sender or "UNKNOWN"
end

-- Start (or restart) a cooldown timer for sender + spell.
function ShortyInterrupt_Tracker:Start(sender, spellID, duration)
  if not sender or not spellID or not duration then return end

  spellID = tonumber(spellID)
  duration = tonumber(duration)
  if not spellID or not duration or duration <= 0 then return end

  local now = GetTime()
  local key = SenderKey(sender)

  self.active[key] = self.active[key] or {}
  self.active[key][spellID] = {
    startAt   = now,
    duration  = duration,
    expiresAt = now + duration,
  }

  if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then
    ShortyInterrupt_UI:Refresh()
  end
end

-- Remove expired timers (call periodically; UI OnUpdate is fine).
function ShortyInterrupt_Tracker:PruneExpired()
  local now = GetTime()
  for sender, spells in pairs(self.active) do
    for spellID, cd in pairs(spells) do
      if cd.expiresAt <= now then
        spells[spellID] = nil
      end
    end
    if next(spells) == nil then
      self.active[sender] = nil
    end
  end
end

-- Clears all timers (e.g., when leaving group).
function ShortyInterrupt_Tracker:ClearAll()
  wipe(self.active)

  if ShortyInterrupt_UI and ShortyInterrupt_UI.Refresh then
    ShortyInterrupt_UI:Refresh()
  end
end

-- Returns raw active table (sender->spell->timer)
function ShortyInterrupt_Tracker:GetActive()
  return self.active
end

-- Utility: Flatten active timers into a sorted array (useful for UI)
-- Each row: { sender, spellID, startAt, duration, expiresAt, remaining, progress }
function ShortyInterrupt_Tracker:GetRows()
  local rows = {}
  local now = GetTime()

  for sender, spells in pairs(self.active) do
    for spellID, cd in pairs(spells) do
      local remaining = cd.expiresAt - now
      if remaining > 0 then
        local progress = (now - cd.startAt) / cd.duration
        if progress < 0 then progress = 0 end
        if progress > 1 then progress = 1 end

        rows[#rows + 1] = {
          sender   = sender,
          spellID  = spellID,
          startAt  = cd.startAt,
          duration = cd.duration,
          expiresAt = cd.expiresAt,
          remaining = remaining,
          progress  = progress,
        }
      end
    end
  end

  table.sort(rows, function(a, b)
    -- Soonest to expire at top; tie-break by sender then spellID
    if a.expiresAt == b.expiresAt then
      if a.sender == b.sender then
        return a.spellID < b.spellID
      end
      return a.sender < b.sender
    end
    return a.expiresAt < b.expiresAt
  end)

  return rows
end
