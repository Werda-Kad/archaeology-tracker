-- Hotspot tracking. The game data has no hotspot locations, so they're learned as you play:
-- every few seconds the hotspots loaded near you are looked up by name, and each one's tile
-- is remembered (for all characters, since hotspots don't move).
-- Pressing Track on a hotspot shows arrows leading to its nearest known spot (indicators.lua)
-- until you press Stop. If the hotspot is in another area (e.g. inside the Barracks), they
-- lead to the entrance on the way instead (routes.lua).

local catalog = require("core/catalog")
local log = require("core/log")
local routes = require("tracking/routes")
local indicators = require("tracking/indicators")

local tracking = {}

local SAVE_KEY = "hotspots/locations"
local LOOK_EVERY = 5  -- server ticks between looking around (5 = 3 seconds)

-- hotspot key -> list of spots where it has been seen: { tile = packed south-west corner tile,
-- w, l = how many tiles it covers east-west and north-south (from the object's LocType) }.
local known = {}
local byName = {}      -- hotspot display name -> list of hotspot keys with that name
local target = nil     -- hotspot key being tracked
local unsaved = false
local listeners = {}   -- called when what's known or tracked changes, e.g. to redraw a window

-- Lets windows know something changed (a new location learned, or tracking started/stopped).
local function changed()
    for _, listener in ipairs(listeners) do listener() end
end

-- Calls listener() whenever a location is learned or tracking starts or stops.
function tracking.onChange(listener)
    table.insert(listeners, listener)
end

-- How many spots of this hotspot are known (0 = not seen yet).
function tracking.spotsKnown(key)
    return #(known[key] or {})
end

-- The hotspot being tracked, or nil.
function tracking.target()
    return target
end

-- Starts pointing at a hotspot (replacing any other), or stops if nil.
function tracking.track(key)
    target = key
    log.say(key and ("Tracking " .. tostring(catalog.hotspots[key] and catalog.hotspots[key].name)) or "Tracking stopped")
    changed()
end

-- Distance in tiles between two tiles, ignoring height.
local function distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- The hotspots (and caches) with a known spot within `radius` tiles of you, as a set of keys.
-- A spot's distance is measured to its nearest edge, as some hotspots are several tiles wide.
-- Hotspots you've never been near aren't known yet, so can't be found.
function tracking.hotspotsNear(radius)
    local near = {}
    local me = Player.GetEntity()
    if not me then return near end
    local here = me.coordGrid
    for key, spots in pairs(known) do
        for _, spot in ipairs(spots) do
            local s = CoordGrid.new(spot.tile)
            if s.level == here.level then
                -- How far you are outside the spot's box on each axis (0 if inside it).
                local dx = math.max(0, s.x - here.x, here.x - (s.x + (spot.w or 1) - 1))
                local dz = math.max(0, s.z - here.z, here.z - (s.z + (spot.l or 1) - 1))
                if math.sqrt(dx * dx + dz * dz) <= radius then near[key] = true end
            end
        end
    end
    return near
end

-- A loc's size in tiles along x and z. Turned a quarter, its width and length swap.
local function sizeOf(loc)
    local ok, w, l, turned = pcall(function()
        return loc.config.width, loc.config.length, loc.rotationType
    end)
    if not (ok and w and l) then return nil end
    if turned == 1 or turned == 3 then w, l = l, w end
    return w, l
end

local MAX_SPOT = 4   -- the most tiles across one spot can grow to when objects are joined

-- Joins a spot and an area of tiles (corner tile, w, l) into one box covering both, if they
-- touch and the box stays small. Returns the box's corner and size, or nil if they don't join.
local function join(spot, tile, w, l)
    local s = CoordGrid.new(spot.tile)
    if s.level ~= tile.level then return nil end
    local sw, sl = spot.w or 1, spot.l or 1
    local x0, z0 = math.min(s.x, tile.x), math.min(s.z, tile.z)
    local x1, z1 = math.max(s.x + sw, tile.x + w), math.max(s.z + sl, tile.z + l)
    -- Touching means no tile-wide gap between them on either axis.
    local gapX = math.max(s.x, tile.x) - math.min(s.x + sw, tile.x + w)
    local gapZ = math.max(s.z, tile.z) - math.min(s.z + sl, tile.z + l)
    if gapX > 0 or gapZ > 0 or x1 - x0 > MAX_SPOT or z1 - z0 > MAX_SPOT then return nil end
    return CoordGrid.new((tile.level << 28) | (x0 << 14) | z0), x1 - x0, z1 - z0
end

-- Remembers where a hotspot object is, for every hotspot with its name. Objects of the same
-- hotspot right next to each other (one hotspot can be made of several) are joined into one
-- spot covering them all, so the frame goes around the whole thing and doesn't hop between
-- them. Returns true if anything new was learned.
local function remember(name, loc)
    local tile, learned = loc.coordGrid, false
    local w, l = sizeOf(loc)
    for _, key in ipairs(byName[name] or {}) do
        known[key] = known[key] or {}
        local joined = false
        for _, spot in ipairs(known[key]) do
            local corner, bw, bl = join(spot, tile, w or 1, l or 1)
            if corner then
                joined = true
                if corner:ToPacked() ~= spot.tile or bw ~= (spot.w or 1) or bl ~= (spot.l or 1) then
                    spot.tile, spot.w, spot.l = corner:ToPacked(), bw, bl   -- grown to cover this object too
                    learned = true
                end
                break
            end
        end
        if not joined then
            table.insert(known[key], { tile = tile:ToPacked(), w = w, l = l })
            learned = true
        end
    end
    return learned
end

local unknownCaches = {}   -- test log: cache names seen that match no hotspot, logged once each

-- Looks for hotspot objects loaded near you and remembers where they are. Material caches have
-- no name in the game's tables (we make one up), so any "cache" nearby that matches nothing is
-- logged, to learn what the game really calls them.
local function lookAround()
    local learned = 0
    for _, loc in ipairs(LocList.All() or {}) do
        local name = loc.displayName
        if byName[name] then
            if remember(name, loc) then learned = learned + 1 end
        elseif type(name) == "string" and name:lower():find("cache") and not unknownCaches[name] then
            unknownCaches[name] = true
            log.say("Cache not recognised: " .. name)
        end
    end
    if learned > 0 then
        unsaved = true
        log.say("Learned " .. learned .. " hotspot location(s)")
        changed()
    end
end

-- The tracked hotspot's known spot nearest to you, or nil.
local function nearestSpot(me)
    local best, bestDistance = nil, math.huge
    for _, spot in ipairs(known[target] or {}) do
        local d = distance(me.coordGrid, CoordGrid.new(spot.tile))
        if d < bestDistance then best, bestDistance = spot, d end
    end
    return best
end

-- The middle of an area of tiles at ground height: its south-west corner tile, w tiles east
-- and l tiles north (1 x 1 if unknown). Returns the centre and the size, in world units.
local function onGround(tile, w, l, fallbackHeight)
    local corner = tile:ToCoordFine(false).position
    local width, length = (w or 1) * 512, (l or 1) * 512
    local x, z = corner.x + width / 2, corner.z + length / 2
    local ok, height, found = pcall(World.GetGroundHeight, tile.level, math.floor(x), math.floor(z))
    return Vector3.new(x, (ok and found and height) or fallbackHeight, z), width, length
end

-- Every frame: show the arrows leading to the tracked hotspot's nearest known spot (or the
-- entrance on the way to it), with the distance to the hotspot itself.
local function draw(seconds)
    local me = target and Player.GetEntity()
    local spot = me and nearestSpot(me)
    if not spot then return indicators.hide() end
    local tile = CoordGrid.new(spot.tile)
    local via = routes.aim(me.coordGrid, tile)
    local aim, width, length
    if via == tile then
        aim, width, length = onGround(tile, spot.w, spot.l, me.position.y)  -- the hotspot itself
    else
        aim, width, length = onGround(via, 1, 1, me.position.y)              -- an entrance on the way
    end
    indicators.show(me, aim, width, length, math.floor(distance(me.coordGrid, tile) + 0.5), seconds)
end

-- Starts learning locations and drawing. Needs the catalog (for hotspot names), so waits for it.
function tracking.start()
    routes.start()
    local saved = PersistentDB:GetStructuredData(SAVE_KEY) or {}
    for key, spots in pairs(saved) do
        known[key] = {}
        for _, s in pairs(spots) do
            -- Older saves kept just the tile number; their sizes are learned on the next visit.
            if type(s) == "number" then s = { tile = s } end
            local tile = CoordGrid.new(math.tointeger(s.tile) or s.tile)
            local w, l = math.tointeger(s.w) or s.w or 1, math.tointeger(s.l) or s.l or 1
            -- Older saves may hold one hotspot as several spots side by side; join them.
            local joined = false
            for _, other in ipairs(known[key]) do
                local corner, bw, bl = join(other, tile, w, l)
                if corner then
                    other.tile, other.w, other.l, joined = corner:ToPacked(), bw, bl, true
                    break
                end
            end
            if not joined then table.insert(known[key], { tile = tile:ToPacked(), w = w, l = l }) end
        end
    end
    catalog.onReady(function()
        for key, hotspot in pairs(catalog.hotspots) do
            if hotspot.name then
                byName[hotspot.name] = byName[hotspot.name] or {}
                table.insert(byName[hotspot.name], key)
            end
        end
    end)
    indicators.start()

    local ticks = 0
    Event.ServerLogic.Subscribe("trackerHotspots", function()
        ticks = ticks + 1
        if catalog.ready and ticks % LOOK_EVERY == 0 then
            local ok, err = pcall(lookAround)
            if not ok then log.say("Couldn't look for hotspots: " .. tostring(err)) end
        end
        if unsaved then
            PersistentDB:SetStructuredData(SAVE_KEY, known)
            unsaved = false
        end
    end)
    Event.Draw.Subscribe("trackerArrow", function(event)
        local ok, err = pcall(draw, event and event.timeDeltaSecs)
        if not ok then
            indicators.hide()
            log.say("Couldn't draw the tracking arrows: " .. tostring(err))
            target = nil
        end
    end)
end

return tracking
