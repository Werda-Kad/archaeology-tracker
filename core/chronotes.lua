-- Learns chronote rewards as you play. The game doesn't store them anywhere a plugin can read
-- (round 14 probe), so this watches two things and links them:
-- - the museum flags: an artifact turning on in a collection means you handed it in, and a
--   whole collection turning off at once means you completed it (it empties to refill);
-- - the chronotes in your backpack going up at the same time.
-- Each tick's hand-ins are paired with the chronotes that arrive within a tick or two of them,
-- so quick hand-ins one after another are still told apart. If exactly one reward in a
-- hand-in isn't known yet, the chronotes gained (minus the known ones) must be that reward.
-- Hand-ins with several unknown are kept, and worked out once the others are learned.
-- Completion rewards are also read straight from the game's collection window while it's open.
-- Rewards are the same for every character, so they're shared.
-- Until a reward has been seen, the RuneScape Wiki's value (core/chronote_values.lua) is shown.
-- A collection's completion bonus is its artifacts' rewards added up (125% for Velucia's museum
-- collections), as the wiki explains and the game confirmed (Museum - Zarosian I: 2,108 x 1.25 = 2,635).

local log = require("core/log")
local catalog = require("core/catalog")
local progress = require("core/progress")
local storage = require("core/storage")
local wikiValues = require("core/chronote_values")

local chronotes = {}

local SAVE_KEY = "chronotes/rewards"
local PAIR_TICKS = 2     -- chronotes this many ticks (1.2 s) before or after a hand-in belong to it
local BONUS = { VELUCIA = 1.25 }   -- completion bonus as a share of the artifacts' total, where it isn't 1

-- "COLLECTION/ARTIFACT" -> chronotes; collection -> completion bonus; hand-ins not worked out yet.
local rewards = { artifacts = {}, collections = {}, unsolved = {} }
local flags = nil         -- collection -> { artifact -> true } handed in, as of last tick
local handIns = {}        -- hand-ins waiting for their chronotes: { tick, handed = list, completed = list }
local gains = {}          -- chronotes that arrived, waiting for their hand-in: { tick, amount }
local ticks = 0
local listeners = {}      -- called when a reward is learned, e.g. to redraw a window
local chronoteId = nil    -- the chronote item's number

-- The wiki's value for an artifact, by its name, or nil if the wiki has none.
local function wikiValue(artifact)
    local a = catalog.artifacts[artifact]
    return a and wikiValues[a.name]
end

-- Chronotes for handing this artifact in to this collection: the reward seen in game, or the
-- wiki's value until then. Nil if neither is known.
function chronotes.forArtifact(collection, artifact)
    return rewards.artifacts[collection .. "/" .. artifact] or wikiValue(artifact)
end

-- The bonus chronotes for completing this collection: the reward seen in game, or worked out
-- from its artifacts' rewards. Nil if any of those isn't known.
function chronotes.forCompletion(collection)
    if rewards.collections[collection] then return rewards.collections[collection] end
    local c = catalog.collections[collection]
    if not c then return nil end
    local total = 0
    for _, artifact in ipairs(c.artifacts) do
        local n = chronotes.forArtifact(collection, artifact)
        if not n then return nil end
        total = total + n
    end
    return math.floor(total * (BONUS[c.collector] or 1) + 0.5)
end

-- The most chronotes this artifact gives in any of its collections (or the wiki's value, if
-- it's in none), or nil if none is known.
function chronotes.bestForArtifact(artifact)
    local best = nil
    for _, collection in ipairs((catalog.artifacts[artifact] or {}).collections or {}) do
        local n = chronotes.forArtifact(collection, artifact)
        if n and (not best or n > best) then best = n end
    end
    return best or wikiValue(artifact)
end

-- Chronotes for giving this artifact to the museum donation bin: 40% of its collection reward
-- (RuneScape Wiki), rounded down. Nil if its reward isn't known.
function chronotes.forDonation(artifact)
    local best = chronotes.bestForArtifact(artifact)
    return best and math.floor(best * 0.4)
end

-- Calls listener() whenever a reward is learned.
function chronotes.onChange(listener)
    table.insert(listeners, listener)
end

-- Which artifacts are handed in to each collection right now.
local function readFlags()
    local now = {}
    for key, collection in pairs(catalog.collections) do
        now[key] = {}
        for _, artifact in ipairs(collection.artifacts) do
            if progress.collectionHas(key, artifact) then now[key][artifact] = true end
        end
    end
    return now
end

-- Compares the museum flags with last tick's. Anything handed in or completed this tick is
-- one hand-in, waiting for its chronotes.
local function checkFlags()
    local now = readFlags()
    if flags then
        local handIn = { tick = ticks, handed = {}, completed = {} }
        for key, collection in pairs(catalog.collections) do
            local before, after = flags[key], now[key]
            if next(before) ~= nil and next(after) == nil then
                -- The whole collection emptied: completed. The missing artifacts were the last ones handed in.
                table.insert(handIn.completed, key)
                for _, artifact in ipairs(collection.artifacts) do
                    if not before[artifact] then table.insert(handIn.handed, { key, artifact }) end
                end
            else
                for artifact in pairs(after) do
                    if not before[artifact] then table.insert(handIn.handed, { key, artifact }) end
                end
            end
        end
        if #handIn.handed > 0 or #handIn.completed > 0 then table.insert(handIns, handIn) end
    end
    flags = now
end

-- Saves what's been learned and tells listeners.
local function saveAndTell()
    PersistentDB:SetStructuredData(SAVE_KEY, rewards)
    for _, listener in ipairs(listeners) do listener() end
end

-- A reward's current value. Terms look like "a:VELUCIA_01/VENATOR_DAGGER" (an artifact in a
-- collection) or "c:VELUCIA_01" (a collection's completion bonus).
local function valueOf(term)
    local kind, key = term:sub(1, 1), term:sub(3)
    return kind == "a" and rewards.artifacts[key] or rewards.collections[key]
end

-- Records a reward's value. The test log notes when it differs from the wiki's.
local function setValue(term, value)
    local kind, key = term:sub(1, 1), term:sub(3)
    if kind == "a" then rewards.artifacts[key] = value else rewards.collections[key] = value end
    local wiki = kind == "a" and wikiValue(key:match("/(.+)$")) or nil
    log.say("Chronotes learned: " .. key .. " = " .. value .. ((wiki and wiki ~= value) and (" (the wiki says " .. wiki .. ")") or ""))
end

-- Tries one hand-in: the rewards it paid, and the chronotes gained. If exactly one reward is
-- unknown, the gain minus the known ones must be it. Returns true once it's no longer needed.
local function solve(handIn)
    local known, unknown = 0, {}
    for _, term in ipairs(handIn.terms) do
        local n = valueOf(term)
        if n then known = known + n else table.insert(unknown, term) end
    end
    if #unknown == 0 then return true end
    if #unknown > 1 then return false end
    local value = handIn.gained - known
    if value > 0 then setValue(unknown[1], value) else log.say("Chronotes didn't add up (" .. handIn.gained .. " gained)") end
    return true
end

-- Tries every hand-in that couldn't be worked out yet, again and again while each new
-- reward learned lets another be worked out.
local function solveSaved()
    local again = true
    while again do
        again = false
        for i = #rewards.unsolved, 1, -1 do
            if solve(rewards.unsolved[i]) then
                table.remove(rewards.unsolved, i)
                again = true
            end
        end
    end
end

-- A hand-in and its chronotes. One that can't be worked out yet (several unknown rewards at
-- once) is kept, to try again whenever another reward is learned.
local function settle(p, gained)
    local handIn = { terms = {}, gained = gained }
    for _, h in ipairs(p.handed) do table.insert(handIn.terms, "a:" .. h[1] .. "/" .. h[2]) end
    for _, key in ipairs(p.completed) do table.insert(handIn.terms, "c:" .. key) end
    if not solve(handIn) then
        log.say("Handed in " .. #handIn.terms .. " things at once; kept to work out later")
        table.insert(rewards.unsolved, handIn)
        while #rewards.unsolved > 50 do table.remove(rewards.unsolved, 1) end  -- keep the save small
    end
    solveSaved()
    saveAndTell()
end

-- Pairs waiting hand-ins with waiting chronotes, oldest first, when they arrived close
-- together. Anything left waiting too long is dropped: chronotes with no hand-in (e.g. taken
-- from the bank), or a hand-in no chronotes came for.
local function pairUp()
    while handIns[1] and gains[1] do
        local h, g = handIns[1], gains[1]
        if math.abs(g.tick - h.tick) <= PAIR_TICKS then
            table.remove(handIns, 1)
            table.remove(gains, 1)
            settle(h, g.amount)
        elseif g.tick < h.tick then
            table.remove(gains, 1)
        else
            table.remove(handIns, 1)
            log.say("Handed in, but no chronotes seen in the backpack")
        end
    end
    if handIns[1] and ticks - handIns[1].tick > PAIR_TICKS then
        table.remove(handIns, 1)
        log.say("Handed in, but no chronotes seen in the backpack")
    end
    if gains[1] and ticks - gains[1].tick > PAIR_TICKS then table.remove(gains, 1) end
end

-- The game's collection window (round 16 probe): interface 656, named COLLECTION_LOG. While open,
-- it lists every collection's name, then the chosen one's name again and its "Reward: N Chronotes".
local WINDOW, WINDOW_PARTS = 656, 64
local namesToKeys = nil   -- collection name -> its key, for reading the game's window
local boardLogged = false -- test log: what the game's window held, written once

-- While the game's collection window is open, reads the chosen collection's "Reward: N Chronotes"
-- straight from it: the reward belongs to the last collection name above it.
local function readBoard()
    local texts = progress.windowTexts(WINDOW, WINDOW_PARTS)
    if not texts then boardLogged = false; return end
    if not namesToKeys then
        namesToKeys = {}
        for key, collection in pairs(catalog.collections) do namesToKeys[string.lower(collection.name)] = key end
    end
    local current, changed, read = nil, false, 0
    for _, text in ipairs(texts) do
        local key = namesToKeys[string.lower(text)]
        if key then current = key end
        local amount = text:match("[Rr]eward:%s*([%d,]+)%s*[Cc]hronotes")
        if amount and current then
            read = read + 1
            local value = tonumber((amount:gsub(",", "")))
            if value and rewards.collections[current] ~= value then
                setValue("c:" .. current, value)
                changed = true
            end
        end
    end
    if not boardLogged then
        boardLogged = true
        log.say("Collection window open: " .. #texts .. " texts, " .. read .. " rewards read"
            .. (read == 0 and (": " .. table.concat(texts, " | ", 1, math.min(#texts, 20))) or ""))
    end
    if changed then
        solveSaved()
        saveAndTell()
    end
end

-- Loads what's been learned before, and starts watching.
function chronotes.start()
    local saved = PersistentDB:GetStructuredData(SAVE_KEY) or {}
    for k, v in pairs(saved.artifacts or {}) do rewards.artifacts[k] = math.tointeger(v) or v end
    for k, v in pairs(saved.collections or {}) do rewards.collections[k] = math.tointeger(v) or v end
    rewards.unsolved = {}
    for _, h in pairs(saved.unsolved or {}) do
        local terms = {}
        for _, t in pairs(h.terms or {}) do table.insert(terms, t) end
        table.insert(rewards.unsolved, { terms = terms, gained = math.tointeger(h.gained) or h.gained })
    end
    local ok, item = pcall(function() return config.Obj.ARCH_CURRENCY_CHRONOTES end)
    chronoteId = ok and item and item.id or nil
    -- Chronotes arriving in the backpack.
    storage.onUpdate(function(name, old, new)
        if name ~= "backpack" or not chronoteId then return end
        local gained = (new[chronoteId] or 0) - (old[chronoteId] or 0)
        if gained <= 0 then return end
        -- Chronotes in the same tick as earlier ones are added together.
        local last = gains[#gains]
        if last and last.tick == ticks then last.amount = last.amount + gained
        else table.insert(gains, { tick = ticks, amount = gained }) end
    end)
    catalog.onReady(function()
        Event.ServerLogic.Subscribe("trackerChronotes", function()
            ticks = ticks + 1
            local okTick, err = pcall(function()
                checkFlags()
                pairUp()
                readBoard()   -- every tick (0.6 s), so a quick look at a collection is still caught
            end)
            if not okTick then log.say("Couldn't watch chronotes: " .. tostring(err)) end
        end)
    end)
end

return chronotes
