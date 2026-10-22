-- The Restoration Tracker's list: the artifacts and collections you're working towards, each with a
-- count (e.g. a collection x2 = complete it twice), saved for each character. Works out what
-- that all needs: how many of each artifact to restore, and the materials for those restores.
-- (restore.lua is something else: it guesses materials used while storage is closed.)

local catalog = require("core/catalog")
local storage = require("core/storage")
local progress = require("core/progress")

local tracker = {}

local MAX_COUNT = 99
local entries = {}     -- list of { kind = "artifact" or "collection", key, count }
local character = nil  -- whose list is loaded
local listeners = {}   -- called when the list changes, e.g. to redraw the window

-- Where a character's list is saved (still under its first name, "restoreTracker", so lists
-- saved before the rename are kept).
local function saveKey()
    return "restoreTracker/" .. character
end

-- Saves the list and tells listeners.
local function changed()
    if character then PersistentDB:SetStructuredData(saveKey(), { entries = entries }) end
    for _, listener in ipairs(listeners) do listener() end
end

-- Calls listener() whenever the list changes.
function tracker.onChange(listener)
    table.insert(listeners, listener)
end

-- The tracked entries, in the order added.
function tracker.entries()
    return entries
end

-- Adds an artifact or collection, or adds one more to its count if it's already tracked.
function tracker.add(kind, key)
    for _, e in ipairs(entries) do
        if e.kind == kind and e.key == key then
            e.count = math.min(MAX_COUNT, e.count + 1)
            return changed()
        end
    end
    table.insert(entries, { kind = kind, key = key, count = 1 })
    changed()
end

-- How many times an artifact or collection is tracked (0 if not).
function tracker.countOf(kind, key)
    for _, e in ipairs(entries) do
        if e.kind == kind and e.key == key then return e.count end
    end
    return 0
end

-- Changes an entry's count by +1 or -1 (never below 1; use remove for that).
function tracker.step(index, by)
    local e = entries[index]
    if not e then return end
    e.count = math.max(1, math.min(MAX_COUNT, e.count + by))
    changed()
end

-- Stops tracking an entry.
function tracker.remove(index)
    table.remove(entries, index)
    changed()
end

-- What everything tracked needs. Returns:
--   restores  = artifact key -> how many still to restore
--   materials = material item id -> how many those restores use
--   wanted    = artifact key -> how many restored copies the goals need in all
-- Each collection needs its artifacts once per count, except artifacts already handed in to it,
-- which cover the first count only. Restored copies you own are taken off once, after adding up
-- every entry's needs, so two entries never count the same restored copy.
function tracker.needs()
    local wanted = {}
    for _, e in ipairs(entries) do
        if e.kind == "artifact" and catalog.artifacts[e.key] then
            wanted[e.key] = (wanted[e.key] or 0) + e.count
        elseif e.kind == "collection" and catalog.collections[e.key] then
            for _, artifact in ipairs(catalog.collections[e.key].artifacts) do
                local handedIn = progress.collectionHas(e.key, artifact) and 1 or 0
                wanted[artifact] = (wanted[artifact] or 0) + math.max(0, e.count - handedIn)
            end
        end
    end
    local restores, materials = {}, {}
    for key, n in pairs(wanted) do
        local artifact = catalog.artifacts[key]
        local toRestore = math.max(0, n - storage.count(artifact.restoredId).total)
        if toRestore > 0 then
            restores[key] = toRestore
            for _, m in ipairs(artifact.materials) do
                materials[m.itemId] = (materials[m.itemId] or 0) + m.amount * toRestore
            end
        end
    end
    return restores, materials, wanted
end

-- Loads the logged-in character's list (when they log in or switch character).
local function checkCharacter()
    local now = storage.currentCharacter()
    if now == character then return end
    character, entries = now, {}
    if now then
        local saved = PersistentDB:GetStructuredData(saveKey()) or {}
        for _, e in pairs(saved.entries or {}) do
            table.insert(entries, { kind = e.kind, key = e.key, count = math.tointeger(e.count) or 1 })
        end
    end
    for _, listener in ipairs(listeners) do listener() end
end

-- Starts following which character is logged in.
function tracker.start()
    Event.ServerLogic.Subscribe("trackerRestoreTrackerCharacter", checkCharacter)
end

return tracker
