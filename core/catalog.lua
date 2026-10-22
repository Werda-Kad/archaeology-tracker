-- The archaeology reference data (artifacts, recipes, collections, hotspots, relics...),
-- read from the game's own data tables at startup. New content added by Jagex is picked up
-- automatically. Table columns are described in DATA_SOURCES.md.

local log = require("core/log")

local catalog = {
    ready = false,
    artifacts = {},       -- artifact key (e.g. "LEGIONARY_GLADIUS") -> artifact
    artifactByItem = {},  -- damaged or restored item id -> artifact
    materials = {},       -- item id -> material or other recipe ingredient (see isArchaeologyMaterial)
    collections = {},     -- collection key (e.g. "VELUCIA_01") -> collection
    collectors = {},      -- collector key (e.g. "VELUCIA") -> collector
    hotspots = {},        -- row name -> hotspot or material cache
    sites = {},           -- row name (e.g. "ARCH_SITE_KHARIDET") -> dig site
    cultures = {},        -- culture key (e.g. "ZAROSIAN") -> culture
    mysteries = {},       -- mystery key (e.g. "EVERLIGHT_REMAINS") -> mystery
    relics = {},          -- relic number (as in loadout slots) -> relic
    qualifications = {},  -- guild qualifications in order (1 Intern ... 5 Guildmaster), with what each needs
    research = {},        -- research number (as in your team's assignment) -> research
}

local PER_TICK = 2000  -- rows checked per server tick, so the game doesn't freeze
-- Row ids reached 20203 in October 2026. Scan at least that far, then keep going until
-- 1000 ids in a row don't exist, so rows Jagex adds later are found too.
local SCAN_AT_LEAST = 21000
local STOP_AFTER_MISSING = 1000
local TABLES = { ARCH_RESTORATION = true, ARCH_EXCAVATION = true, ARCH_SITE = true,
    COLLECTION = true, COLLECTOR = true, ARCH_MYSTERY = true, ARCH_RELIC = true, ARCH_QUALIFICATION = true,
    ARCH_RESEARCH = true }

local readyListeners = {}

-- Small helpers for reading table rows.
local function column(row, n)
    return row:GetColumnValues(n) or {}
end

-- The first value in a column (most columns hold just one).
local function first(row, n)
    return column(row, n)[1]
end

-- "ARCH_RELIC_ENDURANCE" without "ARCH_RELIC_" is "ENDURANCE".
local function withoutPrefix(name, prefix)
    return name:sub(#prefix + 1)
end

-- Items carry extra facts as named "params" (e.g. RECIPE_XP_VALUE_1 = 4308).
-- This gathers them into a simple list: { RECIPE_XP_VALUE_1 = 4308, ... }.
local function params(obj)
    local result = {}
    for _, param in pairs(obj.params or {}) do
        result[param.configName] = obj:GetParamValue(param)
    end
    return result
end

-- The game's item category for archaeology materials. Some recipes also use ordinary items
-- (white candle, ruby, death rune...), which are kept too but marked as not archaeology materials.
local MATERIAL_CATEGORY = 4602

-- Adds a recipe ingredient to the materials list the first time it's seen, and returns it.
local function addMaterial(obj)
    if not catalog.materials[obj.id] then
        catalog.materials[obj.id] = { itemId = obj.id, name = obj.name,
            isArchaeologyMaterial = obj.category == MATERIAL_CATEGORY,
            level = params(obj).USE_REQUIRES_STAT_LEVEL1, hotspots = {} }
    end
    return catalog.materials[obj.id]
end

-- Makes one artifact per restoration row: its damaged and restored items, level, XP
-- and recipe. Linked to collections and hotspots later.
local function buildArtifacts(rows)
    for _, row in ipairs(rows) do
        local damaged, restored = first(row, 6), first(row, 7)
        -- A few (the Tetracompass) have no damaged version: they're made from pieces instead, so
        -- they're kept only if they have a recipe.
        local recipe = restored and params(restored) or {}
        if restored and (damaged or recipe.RECIPE_INGREDIENT_TYPE_1) then
            local artifact = {
                key = withoutPrefix(row.configName, "ARCH_RESTORATION_"),
                name = restored.name, damagedId = damaged and damaged.id, restoredId = restored.id,
                -- The game stores restoration XP times ten (4308 = 430.8 XP).
                level = first(row, 5), description = first(row, 4),
                xp = recipe.RECIPE_XP_VALUE_1 and recipe.RECIPE_XP_VALUE_1 / 10,
                materials = {}, collections = {}, hotspots = {}, sites = {}, cultures = {},
            }
            -- Recipe ingredients, minus the damaged artifact itself.
            for n = 1, 10 do
                local item, amount = recipe["RECIPE_INGREDIENT_TYPE_" .. n], recipe["RECIPE_INGREDIENT_NUMBER_" .. n]
                if not item then break end
                if not damaged or item.id ~= damaged.id then
                    addMaterial(item)
                    table.insert(artifact.materials, { itemId = item.id, amount = amount })
                end
                -- The Tetracompass's four pieces are listed as artifacts too, so you can see which you have.
                local okName, name = pcall(function() return item.configName end)
                if okName and name and name:find("^ARCH_TETRACOMPASS_PIECE") then
                    local piece = { key = withoutPrefix(name, "ARCH_"), name = item.name, restoredId = item.id,
                        level = artifact.level, materials = {}, collections = {}, hotspots = {}, sites = {}, cultures = {},
                        special = "tetracompass" }
                    catalog.artifacts[piece.key] = piece
                    catalog.artifactByItem[item.id] = piece
                    artifact.special = "tetracompass"
                end
            end
            catalog.artifacts[artifact.key] = artifact
            if damaged then catalog.artifactByItem[damaged.id] = artifact end
            catalog.artifactByItem[restored.id] = artifact
        end
    end
end

-- Makes the hotspots and material caches: what each one gives when dug, linked both ways
-- (hotspot -> materials/artifacts, and material/artifact -> hotspots).
local function buildHotspots(rows)
    for _, row in ipairs(rows) do
        -- Column 2 is the kind of spot: 1 a hotspot, 2 a material cache (round 17 probe).
        local hotspot = { key = row.configName, name = first(row, 3), level = first(row, 5), materials = {}, artifacts = {},
            isCache = first(row, 2) == 2, weights = {} }   -- weights: material item id or artifact key -> drop weight
        -- Columns 16 and 18 list "thing, drop weight" pairs.
        local drops = column(row, 16)
        for i = 1, #drops, 2 do
            local material = addMaterial(drops[i])
            table.insert(hotspot.materials, material.itemId)
            hotspot.weights[material.itemId] = math.tointeger(drops[i + 1]) or drops[i + 1]
            table.insert(material.hotspots, hotspot.key)
        end
        local finds = column(row, 18)
        for i = 1, #finds, 2 do
            local artifact = catalog.artifacts[withoutPrefix(finds[i].configName, "ARCH_RESTORATION_")]
            if artifact then
                table.insert(hotspot.artifacts, artifact.key)
                hotspot.weights[artifact.key] = math.tointeger(finds[i + 1]) or finds[i + 1]
                table.insert(artifact.hotspots, hotspot.key)
            end
        end
        -- Material caches have no name of their own.
        if not hotspot.name and hotspot.materials[1] then
            hotspot.name = catalog.materials[hotspot.materials[1]].name .. " cache"
        end
        catalog.hotspots[hotspot.key] = hotspot
    end
end

-- Every entry in one of the game's enums (number -> value lists), as a plain list of values.
local function enumValues(enum)
    local values = {}
    for _, pair in ipairs(enum and enum.values or {}) do table.insert(values, pair[2]) end
    return values
end

-- The artifact a restoration-list entry stands for (a restoration row, or a damaged/restored item).
local function artifactFor(entry)
    if type(entry) ~= "userdata" and type(entry) ~= "table" then return nil end
    local ok, name = pcall(function() return entry.configName end)
    local byRow = ok and name and catalog.artifacts[withoutPrefix(name, "ARCH_RESTORATION_")]
    local okId, itemId = pcall(function() return entry.id end)
    return byRow or (okId and catalog.artifactByItem[itemId]) or nil
end

-- Makes the dig sites. Only rows named ARCH_SITE_* are dig sites (Kharid-et, Senntisten...);
-- the rest of the table are their sub-areas (e.g. Kharid-et's barracks). Each site's column 16
-- is the game's list of artifacts found there, and column 17 lists its sub-areas and hotspots.
local function buildSites(rows)
    local byName = {}
    for _, row in ipairs(rows) do byName[row.configName] = row end
    -- Marks a hotspot, or every hotspot in a sub-area, as belonging to a site.
    -- Sites list sub-areas and hotspots in column 17; sub-areas list their hotspots in column 18.
    -- "Kharid-et - Barracks excavation site" -> "Barracks": a sub-area's short name.
    local function areaName(row)
        local name = first(row, 3) or ""
        return (name:gsub("^.- %- ", ""):gsub(" excavation site$", ""))
    end
    local visited = {}   -- sub-areas reached from a dig site
    -- Marks a site's (or sub-area's) hotspots with the site and, inside a sub-area, its name.
    local function markHotspots(row, siteKey, depth, area)
        visited[row.configName] = true
        local children = {}
        for _, n in ipairs({ 17, 18 }) do
            for _, child in ipairs(column(row, n)) do table.insert(children, child) end
        end
        for _, child in ipairs(children) do
            local hotspot = type(child) ~= "number" and catalog.hotspots[child.configName]
            if hotspot then
                hotspot.site, hotspot.area = siteKey, area
            elseif type(child) ~= "number" and byName[child.configName] and depth < 3 then
                local subArea = byName[child.configName]
                markHotspots(subArea, siteKey, depth + 1, areaName(subArea))
            end
        end
    end
    for _, row in ipairs(rows) do
        if row.configName:find("^ARCH_SITE_") then
            local site = { key = row.configName, name = first(row, 3), description = first(row, 4), artifacts = 0 }
            catalog.sites[site.key] = site
            for _, entry in ipairs(enumValues(first(row, 16))) do
                local artifact = artifactFor(entry)
                if artifact then
                    table.insert(artifact.sites, site.key)
                    site.artifacts = site.artifacts + 1
                end
            end
            markHotspots(row, site.key, 1)
            log.say("Dig site " .. tostring(site.name) .. ": " .. site.artifacts .. " artifacts")
        end
    end
    -- A few areas belong to no dig site (e.g. the Third Age iron cache east of Varrock): their
    -- hotspots get the area's name, but no site.
    for _, row in ipairs(rows) do
        if not visited[row.configName] and not row.configName:find("^ARCH_SITE_") then
            for _, child in ipairs(column(row, 18)) do
                local hotspot = type(child) ~= "number" and catalog.hotspots[child.configName]
                -- The full name ("Varrock - East"), as there's no site name to go with it.
                if hotspot and not hotspot.site and not hotspot.area then
                    hotspot.area = ((first(row, 3) or "?"):gsub(" excavation site$", ""))
                end
            end
        end
    end
    -- Hotspots no area lists (e.g. Fort debris, ARCH_EXCAVATION_KHARIDET_ENTRANCE_DEBRIS) get the
    -- dig site named in their own name.
    for key, hotspot in pairs(catalog.hotspots) do
        if not hotspot.site then
            for siteKey in pairs(catalog.sites) do
                if key:find("^ARCH_EXCAVATION_" .. siteKey:gsub("^ARCH_SITE_", "") .. "_") then hotspot.site = siteKey end
            end
        end
    end
end

-- Sorts out artifacts that can't be dug up. The Tetracompass and its pieces are "tetracompass".
-- Those on a culture list are "misc" (used for a mystery or quest, like Centurion's seal); those
-- on no culture list either are "event" (e.g. Halloween). Everything else is a normal dig-site artifact.
local function buildKinds()
    local misc, event = {}, {}
    for _, artifact in pairs(catalog.artifacts) do
        if artifact.special then
            artifact.kind = artifact.special   -- the Tetracompass and its pieces
        elseif #artifact.sites > 0 then
            artifact.kind = "dig"
        elseif #artifact.cultures > 0 then
            artifact.kind = "misc"
            table.insert(misc, artifact.name)
        else
            artifact.kind = "event"
            table.insert(event, artifact.name)
        end
    end
    table.sort(misc)
    table.sort(event)
    log.say("Misc artifacts (" .. #misc .. "): " .. table.concat(misc, ", "))
    log.say("Event artifacts (" .. #event .. "): " .. table.concat(event, ", "))
end

-- Makes the cultures from the game's restoration lists: one list of artifacts per
-- culture (ARCH_RESTORATION_ZAROSIAN_TABLE...), listed in ARCH_RESTORATION_TABLE_LIST, with
-- display names in ARCH_RESTORATION_TABLE_NAMES.
local function buildCultures()
    local tables = config.Enum.ARCH_RESTORATION_TABLE_LIST
    local okNames, names = pcall(function() return config.Enum.ARCH_RESTORATION_TABLE_NAMES end)
    for _, pair in ipairs(tables.values) do
        local index, list = pair[1], pair[2]
        local key = withoutPrefix(list.configName, "ARCH_RESTORATION_"):gsub("_TABLE$", "")
        local okName, name = pcall(function() return names:GetOutputValue(index) end)
        if not (okNames and okName and type(name) == "string" and name ~= "") then
            name = key:sub(1, 1) .. key:sub(2):lower()  -- "ZAROSIAN" -> "Zarosian"
        end
        local culture = { key = key, name = name, artifacts = 0 }
        catalog.cultures[key] = culture
        for _, entry in ipairs(enumValues(list)) do
            local artifact = artifactFor(entry)
            if artifact then
                table.insert(artifact.cultures, key)
                culture.artifacts = culture.artifacts + 1
            end
        end
        log.say("Culture " .. name .. ": " .. culture.artifacts .. " artifacts")
    end
end

-- Makes the collectors (name and where to find them). Their collections are added later.
local function buildCollectors(rows)
    for _, row in ipairs(rows) do
        local key = withoutPrefix(row.configName, "COLLECTOR_")
        catalog.collectors[key] = { key = key, name = first(row, 2), location = first(row, 6), collections = {} }
    end
end

-- "VELUCIA_01" belongs to collector "VELUCIA"; "ART_01" to "ART_CRITIC_JACQUES".
-- Matched by name because no column linking them has been found yet.
local function findCollector(collectionKey)
    local prefix = collectionKey:match("^(.*)_%d+$")
    if not prefix then return nil end
    for key, collector in pairs(catalog.collectors) do
        if key == prefix or key:sub(1, #prefix + 1) == prefix .. "_" then return collector end
    end
    return nil
end

-- Makes the museum collections and links each one to its artifacts and collector.
local function buildCollections(rows)
    for _, row in ipairs(rows) do
        local collection = { key = withoutPrefix(row.configName, "COLLECTION_"), name = first(row, 5), artifacts = {} }
        for _, obj in ipairs(column(row, 14)) do
            local artifact = catalog.artifactByItem[obj.id]
            if artifact then table.insert(collection.artifacts, artifact.key) end
        end
        -- Rows with no collector (e.g. ARCH_RESTORATION_ZAROSIAN) are restoration logs, not museum collections.
        local collector = findCollector(collection.key)
        if #collection.artifacts > 0 and collector then
            collection.collector = collector.key
            table.insert(collector.collections, collection.key)
            catalog.collections[collection.key] = collection
            for _, key in ipairs(collection.artifacts) do table.insert(catalog.artifacts[key].collections, collection.key) end
        end
    end
end

-- Makes the mysteries (name and dig site).
local function buildMysteries(rows)
    for _, row in ipairs(rows) do
        local key = withoutPrefix(row.configName, "ARCH_MYSTERY_")
        local site = first(row, 4)
        catalog.mysteries[key] = { key = key, name = first(row, 2), site = site and site.configName }
    end
end

-- Makes the relics, listed by the number the game uses for them in relic loadouts.
local function buildRelics(rows)
    for _, row in ipairs(rows) do
        local number = first(row, 1)
        if number then
            -- Columns (round 19 probe): 7 icon, 9 large icon, 10 the relic item it comes from.
            local item = first(row, 10)
            local okItem, itemId, itemName = pcall(function() return item.id, item.name end)
            local okParams, settings = pcall(params, item)
            local relic = { number = number, key = withoutPrefix(row.configName, "ARCH_RELIC_"),
                name = first(row, 2), effect = first(row, 3), icon = first(row, 7), bigIcon = first(row, 9),
                itemId = okItem and itemId or nil, itemName = okItem and itemName or nil,
                reclaim = okParams and settings.DESTROYONDROP_MES or nil, materials = {} }
            -- Some relic items are made from a recipe, stored like an artifact's restoration recipe:
            -- ingredients, and the Archaeology level needed (requirement type 28 = Archaeology).
            if okParams then
                for n = 1, 10 do
                    local ingredient, amount = settings["RECIPE_INGREDIENT_TYPE_" .. n], settings["RECIPE_INGREDIENT_NUMBER_" .. n]
                    if not ingredient then break end
                    addMaterial(ingredient)
                    table.insert(relic.materials, { itemId = ingredient.id, amount = amount })
                end
                if settings.RECIPE_REQUIREMENT_TYPE_1 == 28 then relic.level = settings.RECIPE_REQUIREMENT_VALUE_1 end
            end
            catalog.relics[number] = relic
        end
    end
end

-- How many entries a list has (for the "Catalog ready" log line).
local function count(list)
    local n = 0
    for _ in pairs(list) do n = n + 1 end
    return n
end

-- Which of your stats each kind of qualification achievement counts (by the achievement chain it's part of).
local STAT_OF_CHAIN = { CHEEVO_ARCHAEOLOGY_CHAIN = "level", CHEEVO_ARCHAEOLOGY_DISCOVERY_CHAIN = "discovered",
    CHEEVO_ARCHAEOLOGY_RESTORATION_CHAIN = "restored", CHEEVO_ARCHAEOLOGY_COLLECTION_CHAIN = "collections",
    CHEEVO_ARCHAEOLOGY_MYSTERY_CHAIN = "mysteries", CHEEVO_ARCHAEOLOGY_RESEARCH_CHAIN = "researchHours" }

-- Makes the guild qualifications (Intern to Guildmaster). Each one's achievement points to a
-- list of achievements to complete first; each of those has a target (e.g. level 40, 25
-- restored), which becomes that qualification's requirement for the matching stat.
local function buildQualifications(rows)
    for _, row in ipairs(rows) do
        local number = first(row, 1)
        local okAchievement, achievement = pcall(params, first(row, 4))
        achievement = okAchievement and achievement or {}
        local qualification = { number = number, name = first(row, 2), icon = first(row, 3),
            details = achievement.CHEEVO_DETAILS, needs = {} }
        local okList, entries = pcall(function() return achievement.CHEEVO_META_LIST.values end)
        for _, pair in ipairs(okList and entries or {}) do
            local step = params(pair[2])
            local okChain, chain = pcall(function() return step.CHEEVO_PARENT_CHAIN_LATEST.configName end)
            local stat = okChain and STAT_OF_CHAIN[chain]
            if stat then qualification.needs[stat] = math.tointeger(step.CHEEVO_CHECK_VAR_TOTAL) or step.CHEEVO_CHECK_VAR_TOTAL end
        end
        if number then catalog.qualifications[number] = qualification end
    end
end

-- Makes the research your team can be sent on (round 23 probe): 1 number, 2 kind (1 general,
-- 2 special), 3 dig site, 4 name (e.g. "Kharid-et Dig Site"), 9 its base length in game ticks
-- of 0.6 s (6000 = 1 hour).
local function buildResearch(rows)
    for _, row in ipairs(rows) do
        local number = first(row, 1)
        local okSite, site = pcall(function() return first(row, 3).configName end)
        if number then
            catalog.research[number] = { number = number, kind = first(row, 2), site = okSite and site or nil,
                name = first(row, 4), ticks = first(row, 9) }
        end
    end
end

-- Turns the collected rows into linked data. Order matters: later steps look up earlier ones.
local function build(rows)
    local steps = {
        { buildArtifacts, "ARCH_RESTORATION" }, { buildHotspots, "ARCH_EXCAVATION" }, { buildSites, "ARCH_SITE" },
        { buildCultures, "cultures" }, { buildKinds, "kinds" },
        { buildCollectors, "COLLECTOR" }, { buildCollections, "COLLECTION" },
        { buildMysteries, "ARCH_MYSTERY" }, { buildRelics, "ARCH_RELIC" }, { buildQualifications, "ARCH_QUALIFICATION" },
        { buildResearch, "ARCH_RESEARCH" },
    }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step[1], rows[step[2]] or {})
        if not ok then log.say("Catalog: couldn't read " .. step[2] .. " (" .. tostring(err) .. ")") end
    end
    catalog.ready = true
    log.say("Catalog ready: " .. count(catalog.artifacts) .. " artifacts, " .. count(catalog.materials) .. " materials, "
        .. count(catalog.collections) .. " collections, " .. count(catalog.collectors) .. " collectors, "
        .. count(catalog.hotspots) .. " hotspots, " .. count(catalog.mysteries) .. " mysteries, "
        .. count(catalog.relics) .. " relics")
    for _, listener in ipairs(readyListeners) do listener() end
end

-- Runs a function once the catalog is ready (straight away if it already is).
function catalog.onReady(listener)
    if catalog.ready then listener() else table.insert(readyListeners, listener) end
end

-- Scans every table row a batch at a time, keeping the archaeology ones, then builds the catalog.
function catalog.start()
    local rows = {}  -- table name -> list of rows
    local nextId, lastFound, done = 0, 0, false
    Event.ServerLogic.Subscribe("trackerCatalogScan", function()
        if done then return end
        for rowId = nextId, nextId + PER_TICK - 1 do
            local ok, row = pcall(config.DBRow.FromID, rowId)
            if ok and row then
                lastFound = rowId
                local tableName = row.ownerDBTable.configName
                if TABLES[tableName] then
                    rows[tableName] = rows[tableName] or {}
                    table.insert(rows[tableName], row)
                end
            end
        end
        nextId = nextId + PER_TICK
        if nextId > SCAN_AT_LEAST and nextId - lastFound > STOP_AFTER_MISSING then
            done = true
            build(rows)
        end
    end)
end

return catalog
