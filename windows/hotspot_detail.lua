-- The hotspot window: opens when a hotspot (or material cache) is clicked in an artifact or
-- material window. Shows its dig site, area and level, whether its location is known (with a
-- Track button), and what's dug up there: artifacts and materials, each with its share of
-- finds. Clicking a find opens its window.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local tracking = require("tracking/tracking")

local detail = {}

local WIDTH = 560
local PAD = 10
local LINE = 20                    -- height of one line of text
local SQUARE, GAP = 60, 6          -- one find's square
local PER_ROW = 8                  -- squares per row

local box = nil      -- the window's frame, while it's open
local shown = nil    -- the hotspot it's showing
local dirty = false  -- tracking or counts changed; rebuild on the next tick

-- "30%": a find's share of its kind (artifacts or materials) at this hotspot, from the game's drop weights.
local function shares(hotspot, things)
    local total = 0
    for _, thing in ipairs(things) do total = total + (hotspot.weights[thing] or 0) end
    local result = {}
    for _, thing in ipairs(things) do
        local w = hotspot.weights[thing]
        result[thing] = (w and total > 0) and (math.floor(w * 100 / total + 0.5) .. "%") or ""
    end
    return result
end

-- A line of text at a height in the window; returns the height below it.
local function line(text, y, colour, font)
    local t = widgets.text(box, text, colour, font or widgets.SMALL_FONT)
    t:SetPos(PAD, y)
    t:SetSize(-2 * PAD, LINE, 1.0, 0)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return y + LINE
end

-- A section heading with a little space above it; returns the height below it.
local function heading(text, y)
    return line(text, y + 8, widgets.GOLD, widgets.BOLD_FONT)
end

-- One find: its icon (dimmed if you have none) and its share, as a button that opens its window.
local function findSquare(itemId, share, owned, onPress, x, y)
    local square = ui.Layer.new(box)
    square:SetPos(x, y)
    square:SetSize(SQUARE, SQUARE)
    local button = widgets.button(square, "", onPress)
    button:SetSize(0, 0, 1.0, 1.0)
    local icon = ui.Sprite.new(square)
    icon:SetAssociatedObject(itemId)
    icon:SetPos(SQUARE // 2 - 18, 4)
    icon:SetSize(36, 34)
    icon.clickthrough = true
    icon.colour = owned and Vector4.new(1.0, 1.0, 1.0, 1.0) or Vector4.new(0.45, 0.45, 0.45, 0.8)
    local text = widgets.text(square, share, widgets.WHITE, widgets.SMALL_FONT)
    text:SetPos(0, -20, 0, 1.0)
    text:SetSize(0, 18, 1.0, 0)
    text:AlignTo(ui.AlignMode.CENTRE)
end

-- Lays out squares in rows from height y; returns the height below them.
local function squares(entries, y)
    for i, entry in ipairs(entries) do
        local col, row = (i - 1) % PER_ROW, (i - 1) // PER_ROW
        findSquare(entry.itemId, entry.share, entry.owned, entry.open, PAD + col * (SQUARE + GAP), y + row * (SQUARE + GAP))
    end
    return y + math.max(1, math.ceil(#entries / PER_ROW)) * (SQUARE + GAP)
end

-- Builds the window's contents for a hotspot. The window is sized to fit them.
local function build(hotspot)
    -- What's found here, most common first.
    local artifactShares, materialShares = shares(hotspot, hotspot.artifacts), shares(hotspot, hotspot.materials)
    local artifacts, materials = {}, {}
    for _, key in ipairs(hotspot.artifacts) do
        local a = catalog.artifacts[key]
        table.insert(artifacts, { itemId = a.restoredId, share = artifactShares[key], weight = hotspot.weights[key] or 0,
            owned = storage.count(a.damagedId).total + storage.count(a.restoredId).total > 0,
            open = function() require("windows/artifact_detail").open(a) end })
    end
    for _, itemId in ipairs(hotspot.materials) do
        local m = catalog.materials[itemId]
        table.insert(materials, { itemId = itemId, share = materialShares[itemId], weight = hotspot.weights[itemId] or 0,
            owned = storage.count(itemId).total > 0, open = function() require("windows/material_detail").open(m) end })
    end
    for _, list in ipairs({ artifacts, materials }) do
        table.sort(list, function(a, b) return a.weight > b.weight end)
    end
    local rows = function(n) return math.max(1, math.ceil(n / PER_ROW)) end
    local height = widgets.HEADER_HEIGHT + 6 + 3 * LINE + LINE + 8 + LINE + 8
        + (#artifacts > 0 and (LINE + 8 + rows(#artifacts) * (SQUARE + GAP)) or 0)
        + LINE + 8 + rows(#materials) * (SQUARE + GAP) + PAD
    box = widgets.window("hotspot", hotspot.name or "Hotspot", WIDTH, height, detail.close).box

    -- Where it is and what it needs.
    local y = widgets.HEADER_HEIGHT + 6
    local site = hotspot.site and catalog.sites[hotspot.site]
    y = line((hotspot.isCache and "Material cache" or "Hotspot") .. ", level " .. tostring(hotspot.level or "?"), y, widgets.WHITE)
    y = line("Dig site: " .. (site and site.name or "none"), y, widgets.WHITE)
    y = line("Area: " .. (hotspot.area or "-"), y, widgets.WHITE)

    -- Whether its location is known, and the Track (or Stop) button.
    y = heading("Location", y)
    local spots = tracking.spotsKnown(hotspot.key)
    local status = spots > 0 and ("Location known (" .. spots .. (spots == 1 and " spot)" or " spots)"))
        or "Not seen yet: visit it once in order to track it"
    local note = widgets.text(box, status, spots > 0 and widgets.ENOUGH or widgets.DIM, widgets.SMALL_FONT)
    note:SetPos(PAD, y)
    note:SetSize(-2 * PAD - 90, 24, 1.0, 0)
    note:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    local isTracked = tracking.target() == hotspot.key
    local button = widgets.button(box, isTracked and "Stop" or "Track", function()
        tracking.track(not isTracked and hotspot.key or nil)
    end)
    button:SetPos(-PAD - 76, y, 1.0, 0)
    button:SetSize(76, 24)
    button.enabled = spots > 0 or isTracked
    y = y + LINE + 4

    -- What's dug up here. Caches give only materials, so they have no artifacts section.
    if #artifacts > 0 then
        y = heading("Artifacts found here (share of artifact finds)", y)
        y = squares(artifacts, y)
    end
    y = heading("Materials found here (share of material finds)", y)
    if #materials == 0 then line("None", y, widgets.DIM) else squares(materials, y) end
end

-- Closes the window.
function detail.close()
    widgets.destroyWindow(box)
    box, shown = nil, nil
end

-- Opens the window for a hotspot (replacing whichever it was showing).
function detail.open(hotspot)
    detail.close()
    shown = hotspot
    build(hotspot)
end

-- Whether the window is open, and for which hotspot.
function detail.showing()
    return shown
end

-- Rebuilds the window when tracking or counts change, at most once per server tick.
function detail.start()
    tracking.onChange(function() dirty = true end)
    storage.onUpdate(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerHotspotDetailRedraw", function()
        if dirty and shown then detail.open(shown) end
        dirty = false
    end)
end

return detail
