-- Restoring at the workbench uses materials and damaged artifacts from storages that may be
-- closed, so the game doesn't send those changes. This guesses them from the recipe instead.
-- storage.lua logs whether the guess was right the next time the storage opens.

local catalog = require("core/catalog")
local progress = require("core/progress")
local storage = require("core/storage")

local restore = {}

local lastCounts = {}      -- artifact key -> times restored, as last seen
local countsFor = nil      -- character the counts belong to
local checkSoon = false    -- a restoration count changed; compare counts on the next tick
local pending = {}         -- restores waiting one tick, so backpack changes can arrive first
local backpackLoss = {}    -- item id -> amount that left the backpack in the last two ticks
local olderLoss = {}

-- Notes every artifact's restore count for the current character.
local function rememberCounts()
    countsFor = storage.currentCharacter()
    for key in pairs(catalog.artifacts) do lastCounts[key] = progress.timesRestored(key) end
end

-- Takes up to `wanted` from what recently left the backpack, returns what's still missing.
local function fromBackpack(itemId, wanted)
    for _, losses in ipairs({ olderLoss, backpackLoss }) do
        local used = math.min(losses[itemId] or 0, wanted)
        losses[itemId] = (losses[itemId] or 0) - used
        wanted = wanted - used
    end
    return wanted
end

-- Removes what one batch of restores used. Anything that didn't come from the backpack
-- must have come from storage. Ordinary ingredients (e.g. white candles) come from the backpack.
local function applyRestore(artifact, times)
    -- (The Tetracompass has no damaged version, so only its pieces and materials are used up.)
    if artifact.damagedId then storage.adjust("artifactStorage", artifact.damagedId, -fromBackpack(artifact.damagedId, times)) end
    for _, m in ipairs(artifact.materials) do
        if catalog.materials[m.itemId].isArchaeologyMaterial then
            storage.adjust("materialStorage", m.itemId, -fromBackpack(m.itemId, m.amount * times))
        end
    end
end

-- Finds artifacts whose restoration count went up since last time.
local function findRestores()
    for key, artifact in pairs(catalog.artifacts) do
        local now = progress.timesRestored(key)
        local times = now - (lastCounts[key] or now)
        if times > 0 and times <= 100 then  -- a huge jump means bad data, not restoring
            table.insert(pending, { artifact = artifact, times = times })
        end
        lastCounts[key] = now
    end
end

-- Each server tick: handle a character change, apply waiting restores, look for new ones.
local function onTick()
    if not catalog.ready then return end
    if countsFor ~= storage.currentCharacter() then
        rememberCounts()  -- new character: their counts aren't restores
        pending, checkSoon = {}, false
    end
    for _, p in ipairs(pending) do applyRestore(p.artifact, p.times) end
    pending = {}
    if checkSoon then
        findRestores()
        checkSoon = false
    end
    olderLoss, backpackLoss = backpackLoss, {}
end

-- Starts watching for restores and for items leaving the backpack.
function restore.start()
    Event.VarTransmit.Subscribe("trackerRestoreVar", function(event)
        local name = event.var.configName
        if type(name) == "string" and name:find("^ARCH_RESTORATION_") then checkSoon = true end
    end)
    storage.onUpdate(function(name, old, new)
        if name ~= "backpack" then return end
        for id, count in pairs(old) do
            local lost = count - (new[id] or 0)
            if lost > 0 then backpackLoss[id] = (backpackLoss[id] or 0) + lost end
        end
    end)
    Event.ServerLogic.Subscribe("trackerRestoreTick", onTick)
end

return restore
