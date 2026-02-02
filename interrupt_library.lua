-- ShortyInterrupt - interrupt_library.lua
-- Deterministic interrupt cooldown library (NO Blizzard cooldown APIs).
-- Provides:
--   ShortyInterrupt_Interrupts[spellID] = { name, class, spellID, iconID, bcd }
--   ShortyInterrupt_ModifiersBySpell[spellID] = { { talent, class, talentID, modifies, altcd }, ... }
--   ShortyInterrupt_GetEffectiveCooldown(spellID) -> seconds (base or talent-modified)

-- Interrupt spell library (authoritative list)
ShortyInterrupt_Interrupts = {
  [47528]  = { name = "Mind Freeze",       class = "DEATHKNIGHT", spellID = 47528,  iconID = 237527,  bcd = 15 },
  [183752] = { name = "Disrupt",           class = "DEMONHUNTER", spellID = 183752, iconID = 1305153, bcd = 15 },
  [106839] = { name = "Skull Bash",        class = "DRUID",       spellID = 106839, iconID = 236946,  bcd = 15 },
  [351338] = { name = "Quell",             class = "EVOKER",      spellID = 351338, iconID = 4622469, bcd = 15 },
  [147362] = { name = "Counter Shot",      class = "HUNTER",      spellID = 147362, iconID = 249170,  bcd = 24 },
  [187707] = { name = "Muzzle",            class = "HUNTER",      spellID = 187707, iconID = 1376045, bcd = 15 },
  [2139]   = { name = "Counterspell",      class = "MAGE",        spellID = 2139,   iconID = 135856,  bcd = 25 },
  [116705] = { name = "Spear Hand Strike", class = "MONK",        spellID = 116705, iconID = 608940,  bcd = 15 },
  [96231]  = { name = "Rebuke",            class = "PALADIN",     spellID = 96231,  iconID = 523893,  bcd = 15 },
  [15487]  = { name = "Silence",           class = "PRIEST",      spellID = 15487,  iconID = 458230,  bcd = 30 },
  [1766]   = { name = "Kick",              class = "ROGUE",       spellID = 1766,   iconID = 132219,  bcd = 15 },
  [57994]  = { name = "Wind Shear",        class = "SHAMAN",      spellID = 57994,  iconID = 136018,  bcd = 12 },
  [6552]   = { name = "Pummel",            class = "WARRIOR",     spellID = 6552,   iconID = 132938,  bcd = 15 },
}

-- Spell modifier talent definitions (authoritative list)
ShortyInterrupt_SpellModifiers = {
  { talent = "Coldthirst",   class = "DEATHKNIGHT", talentID = 378848, modifies = 47528, altcd = 12 },
  { talent = "Quick Witted", class = "MAGE",        talentID = 382297, modifies = 2139,  altcd = 20 },
}

-- Index modifiers by the spell they modify for fast lookup
ShortyInterrupt_ModifiersBySpell = {}
do
  for _, m in ipairs(ShortyInterrupt_SpellModifiers) do
    local spellID = m.modifies
    ShortyInterrupt_ModifiersBySpell[spellID] = ShortyInterrupt_ModifiersBySpell[spellID] or {}
    table.insert(ShortyInterrupt_ModifiersBySpell[spellID], m)
  end
end

-- Returns true if the player currently has the modifier talent that affects this interrupt spell.
local function PlayerHasModifierTalent(mod)
  -- Per your rules: use IsPlayerSpell(talentSpellID)
  -- In modern WoW, this returns true if the player knows the spell (including talents).
  return IsPlayerSpell(mod.talentID) == true
end

-- Compute effective cooldown for the local player (base or modified by known talent).
-- NOTE: This is ONLY for the local player (the sender). Receivers trust the broadcasted cd.
function ShortyInterrupt_GetEffectiveCooldown(spellID)
  local entry = ShortyInterrupt_Interrupts[spellID]
  if not entry then return nil end

  local cd = entry.bcd

  local mods = ShortyInterrupt_ModifiersBySpell[spellID]
  if mods then
    for _, mod in ipairs(mods) do
      if PlayerHasModifierTalent(mod) then
        cd = mod.altcd
        break
      end
    end
  end

  return cd
end