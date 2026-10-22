-- Reads archaeology progress (collections, mysteries, relics, restorations) by name.
-- The game always sends these, so they're read live instead of saved. Names: see DATA_SOURCES.md.

local progress = {}

-- A saved game value by name, or nil if the game has no value with that name.
function progress.value(name)
    local ok, v = pcall(function() return var.VarPlayer[name] end)
    if ok and v then return v.value end
    return nil
end

-- True if an on/off value is on.
local function isOn(name)
    return progress.value(name) == 1
end

-- Your Archaeology level, ignoring boosts.
function progress.level()
    return Player.GetLevelUncapped(SkillType.ARCHAEOLOGY)
end

-- Collection names look like "VELUCIA_01"; artifact names like "VENATOR_DAGGER".
function progress.collectionHas(collection, artifact)
    return isOn("COLLECTION_" .. collection .. "_ARCH_" .. artifact)
end

-- True once a collection has been completed at least once (stays true while it refills).
function progress.collectionEverCompleted(collection)
    return isOn("COLLECTION_" .. collection .. "_COMPLETE")
end

-- How many times this artifact has ever been restored.
function progress.timesRestored(artifact)
    return progress.value("ARCH_RESTORATION_" .. artifact) or 0
end

-- Mystery names look like "DAEMONHEIM_A_NEW_HOME".
function progress.mysteryCompleted(mystery)
    return isOn("ARCH_MYSTERY_" .. mystery .. "_COMPLETED")
end

-- Relic names look like "WOLFS_HUNGER". "Acquired" vs "unlocked" still needs checking in game.
function progress.relicUnlocked(relic)
    return isOn("ARCH_RELIC_" .. relic .. "_UNLOCKED")
end

-- True once you've found the relic itself.
function progress.relicAcquired(relic)
    return isOn("ARCH_RELIC_" .. relic .. "_ACQUIRED")
end

-- Which relic loadout is in use (0 to 3).
function progress.activeLoadout()
    return progress.value("ARCH_RELIC_LOADOUT")
end

-- The relic power numbers in a loadout's 3 slots, e.g. { 4, 30, 0 } where 4 = Endurance and 0 = empty.
-- (The game also keeps a 4th slot value, always 0.)
function progress.loadoutRelics(loadout)
    local relics = {}
    for slot = 1, 3 do
        relics[slot] = progress.value("ARCH_RELIC_LOADOUT_" .. loadout .. "_SLOT_" .. slot .. "_ID") or 0
    end
    return relics
end

-- All the text in one of the game's windows while it's open, in order, with colour tags removed;
-- nil while it's closed. `parts` is how many of its parts to look through.
function progress.windowTexts(interfaceId, parts)
    local window = ui.Interfaces:GetInterface(interfaceId)
    if not window then return nil end
    local found = {}
    -- Adds the text of one part and everything inside it.
    local function collect(component)
        local ok, content = pcall(function() return component.content end)
        if ok and type(content) == "string" and content ~= "" then table.insert(found, (content:gsub("<[^>]*>", ""))) end
        -- Visits each part inside it (only layout parts have any).
        local function visit(child)
            collect(child)
            return false
        end
        pcall(function() component:IterateStaticComponents(visit) end)
        pcall(function() component:IterateDynamicComponents(visit) end)
    end
    for part = 0, parts do
        local ok, component = pcall(function() return window:GetComponent(part) end)
        if ok and component then collect(component) end
    end
    return found
end

-- Your guild qualification: 0 (none yet), 1 Intern ... 5 Guildmaster.
function progress.qualification()
    return progress.value("ARCH_QUALIFICATION") or 0
end

-- Your stats that qualifications ask for: level, damaged artifacts uncovered, artifacts
-- restored, unique collections completed, mysteries solved and research team hours.
function progress.qualificationStats()
    local catalog = require("core/catalog")
    local collections, mysteries = 0, 0
    for key in pairs(catalog.collections) do
        if progress.collectionEverCompleted(key) then collections = collections + 1 end
    end
    for key in pairs(catalog.mysteries) do
        if progress.mysteryCompleted(key) then mysteries = mysteries + 1 end
    end
    -- Research time is kept in game ticks of 0.6 s, so 6000 a hour (2,151,000 = 358.5 hours).
    return { level = progress.level() or 0, discovered = progress.value("ARCH_DISCOVERY_TOTAL") or 0,
        restored = progress.value("ARCH_RESTORATION_TOTAL") or 0, collections = collections, mysteries = mysteries,
        researchHours = (progress.value("ARCH_RESEARCH_TOTAL_TIME") or 0) // 6000 }
end

return progress
