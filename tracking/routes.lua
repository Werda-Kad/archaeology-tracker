-- Finding the way between areas. Sub-locations like Kharid-et's Barracks sit far away from
-- the dig site in the game's coordinates, so a straight arrow between them points nowhere useful.
-- This learns, as you play:
-- - Areas: the map squares (64 x 64 tiles) you've stood in. Squares next to each other are one
--   area, e.g. the overworld around a dig site; a sub-location's squares are a separate area.
-- - Entrances: when you use an object (Enter, Climb-down...) and then appear far away, that
--   object is an entrance from where you were to where you came out. Each also works backwards.
-- routes.aim() then says where an arrow should point to head towards a tile.

local log = require("core/log")

local routes = {}

local SAVE_KEY = "hotspots/routes"
local JUMP_TILES = 30      -- moving further than this in one tick means you went through something
local ENTRANCE_TICKS = 20  -- the jump must happen within this many ticks (12 s) of using an object
local NEAR_SQUARES = 2     -- squares this close count as one area (nearby objects load 1-2 squares out)

local squares = {}         -- square key -> true, for every map square you've stood in
local entrances = {}       -- list of { from = packed tile of the object used, to = packed tile you came out at, name }
local areaOf = nil         -- square key -> area number; rebuilt when squares or entrances change
local unsaved = false
local lastTile = nil       -- where you were last tick
local used = nil           -- the object you last used: { tile, name, tick }
local ticks = 0

-- The map square a tile is in, as one number. Levels are ignored: underground areas are elsewhere anyway.
local function squareOf(tile)
    return (tile.x // 64) * 1000 + (tile.z // 64)
end

-- Distance in tiles between two tiles, ignoring height.
local function distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- Groups the squares you've stood in into areas: squares within NEAR_SQUARES of each other
-- share an area number.
local function buildAreas()
    areaOf = {}
    local count = 0
    for start in pairs(squares) do
        if not areaOf[start] then
            count = count + 1
            local queue = { start }
            areaOf[start] = count
            while #queue > 0 do
                local key = table.remove(queue)
                local sx, sz = key // 1000, key % 1000
                for dx = -NEAR_SQUARES, NEAR_SQUARES do
                    for dz = -NEAR_SQUARES, NEAR_SQUARES do
                        local n = (sx + dx) * 1000 + (sz + dz)
                        if squares[n] and not areaOf[n] then
                            areaOf[n] = count
                            table.insert(queue, n)
                        end
                    end
                end
            end
        end
    end
end

-- Which area a tile is in (nil if you've never been near it). A tile in a square you haven't
-- stood in still counts if it's within NEAR_SQUARES of one you have, e.g. an entrance just
-- across a square's edge.
local function area(tile)
    if not areaOf then buildAreas() end
    local key = squareOf(tile)
    if areaOf[key] then return areaOf[key] end
    local sx, sz = key // 1000, key % 1000
    for dx = -NEAR_SQUARES, NEAR_SQUARES do
        for dz = -NEAR_SQUARES, NEAR_SQUARES do
            local found = areaOf[(sx + dx) * 1000 + (sz + dz)]
            if found then return found end
        end
    end
    return nil
end

-- Remembers the square you're standing in.
local function visit(tile)
    local key = squareOf(tile)
    if not squares[key] then
        squares[key] = true
        areaOf, unsaved = nil, true
    end
end

-- Every entrance as a one-way link, both directions: { at = tile to walk to, area it's in, leads = area it takes you to }.
local function links()
    local list = {}
    for _, e in ipairs(entrances) do
        local from, to = CoordGrid.new(e.from), CoordGrid.new(e.to)
        local a, b = area(from), area(to)
        if a and b and a ~= b then
            table.insert(list, { at = from, area = a, leads = b })
            table.insert(list, { at = to, area = b, leads = a })  -- the way back out is next to where you came in
        end
    end
    return list
end

-- Where an arrow should point, from your tile, to head towards the target tile:
-- straight at it if it's in your area; otherwise at the entrance that starts the way there;
-- otherwise at an entrance into the target's area; otherwise straight at it.
function routes.aim(me, target)
    local here, there = area(me), area(target)
    if not here or not there or here == there then return target end
    local all = links()
    -- Search outwards from your area for a way to the target's area, entrance by entrance.
    local firstStep, queue = { [here] = false }, { here }
    while #queue > 0 do
        local current = table.remove(queue, 1)
        if current == there then break end
        for _, link in ipairs(all) do
            if link.area == current and firstStep[link.leads] == nil then
                firstStep[link.leads] = firstStep[current] or link
                table.insert(queue, link.leads)
            end
        end
    end
    if firstStep[there] then return firstStep[there].at end
    -- No known way from here: head for the nearest entrance that leads into the target's area.
    local best, bestDistance = nil, math.huge
    for _, link in ipairs(all) do
        if link.leads == there and distance(me, link.at) < bestDistance then
            best, bestDistance = link.at, distance(me, link.at)
        end
    end
    return best or target
end

-- Whether an entrance at this object, coming out about here, is already known.
local function alreadyKnown(from, to)
    for _, e in ipairs(entrances) do
        if distance(CoordGrid.new(e.from), from) <= 3 and distance(CoordGrid.new(e.to), to) <= 5 then return true end
    end
    return false
end

-- Each tick: remember where you are, and spot going through an entrance.
local function onTick()
    ticks = ticks + 1
    local me = Player.GetEntity()
    if not me then return end
    local tile = me.coordGrid
    visit(tile)
    if lastTile and used and ticks - used.tick <= ENTRANCE_TICKS and distance(lastTile, tile) > JUMP_TILES then
        if not alreadyKnown(used.tile, tile) then
            table.insert(entrances, { from = used.tile:ToPacked(), to = tile:ToPacked(), name = used.name })
            log.say("Learned an entrance: " .. used.name .. " leads to " .. tile.x .. "," .. tile.z)
            areaOf, unsaved = nil, true
        end
        used = nil
    end
    lastTile = tile
    if unsaved then
        local saved = { entrances = entrances, squares = {} }
        for key in pairs(squares) do table.insert(saved.squares, key) end
        PersistentDB:SetStructuredData(SAVE_KEY, saved)
        unsaved = false
    end
end

-- Remembers the last object you used (from the right-click menu), in case it's an entrance.
local function onMenuChoice(event)
    local entry = event.entry
    local loc = entry and entry.locData
    local me = Player.GetEntity()
    if not (loc and me) then return end
    local level = me.coordGrid.level
    used = { tile = CoordGrid.new((level << 28) | (loc.coordGridX << 14) | loc.coordGridZ),
        -- Names carry the game's colour tags, e.g. "<col=00ffff>Rope"; they're removed.
        name = ((entry.verbText or "") .. " " .. (entry.subjectText or "")):gsub("<[^>]*>", ""), tick = ticks }
end

-- Loads what's been learned before, and starts learning.
function routes.start()
    local saved = PersistentDB:GetStructuredData(SAVE_KEY) or {}
    for _, key in pairs(saved.squares or {}) do squares[math.tointeger(key) or key] = true end
    for _, e in pairs(saved.entrances or {}) do
        table.insert(entrances, { from = math.tointeger(e.from) or e.from, to = math.tointeger(e.to) or e.to, name = e.name })
    end
    Event.ServerLogic.Subscribe("trackerRoutes", function()
        local ok, err = pcall(onTick)
        if not ok then log.say("Couldn't follow your position: " .. tostring(err)) end
    end)
    Event.MiniMenuEntrySelected.Subscribe("trackerRouteMenu", function(event)
        pcall(onMenuChoice, event)
    end)
end

return routes
