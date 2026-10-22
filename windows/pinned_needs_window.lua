-- Small windows pinned from the Restoration Tracker, to keep on screen while you dig: one lists
-- the materials still needed, the other the damaged artifacts. Each line shows owned / needed,
-- with the ones still short at the top. "Current hotspot only" narrows the list to what the
-- hotspots within 5 tiles of you can give, with each one's chance there (its share of that
-- hotspot's artifact or material finds, from the game's drop weights).

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local tracker = require("core/restoration_tracker")
local tracking = require("tracking/tracking")

local pinned = {}

local WIDTH = 300
local PAD = 8
local LINE = 20
local ROW = 30                 -- one thing's line
local ROWS_SHOWN = 8           -- lines shown before the rest scroll
local NEAR_TILES = 5           -- "near" means a hotspot within this many tiles (some sit close together)
local CHECK_EVERY = 3          -- ticks between checks of which hotspots are near, while that box is ticked
-- The two lists: which part of the tracker's needs each shows, and its title.
local KINDS = {
    materials = { title = "Materials needed", none = "No materials needed" },
    damaged = { title = "Damaged artifacts needed", none = "No damaged artifacts needed" },
}

local windows = {}   -- kind -> { win, box, body, area, nearOnly, nearSeen } while that window is open
local ticks = 0

-- A needed thing's best chance at one of these hotspots, from 0 to 1: its share of that
-- hotspot's finds of its kind (artifacts or materials). Nil if none of them gives it.
local function chanceAt(kind, itemId, near)
    local thing = kind == "materials" and itemId or (catalog.artifactByItem[itemId] or {}).key
    local keys = kind == "materials" and (catalog.materials[itemId] or {}).hotspots or (catalog.artifactByItem[itemId] or {}).hotspots
    local best = nil
    for _, key in ipairs(keys or {}) do
        local hotspot = near[key] and catalog.hotspots[key]
        if hotspot then
            local total = 0
            for _, other in ipairs(kind == "materials" and hotspot.materials or hotspot.artifacts) do
                total = total + (hotspot.weights[other] or 0)
            end
            local share = total > 0 and (hotspot.weights[thing] or 0) / total or 0
            if not best or share > best then best = share end
        end
    end
    return best
end

-- The names of the hotspots near you, for the line under the box ("Near: Venator remains").
local function nearNames(near)
    local names, seen = {}, {}
    for key in pairs(near) do
        local name = catalog.hotspots[key] and catalog.hotspots[key].name
        if name and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

-- The things a window lists: still short first, then the rest, each by name.
local function listFor(kind, near)
    local _, damaged, materials = require("windows/restoration_tracker_window").needsLists()
    local list = {}
    for _, s in ipairs(kind == "materials" and materials or damaged) do
        local chance = near and chanceAt(kind, s.itemId, near)
        if not near or chance then
            s.chance = chance
            table.insert(list, s)
        end
    end
    table.sort(list, function(a, b)
        local aShort, bShort = a.owned < a.needed, b.owned < b.needed
        if aShort ~= bShort then return aShort end
        return (a.name or "") < (b.name or "")
    end)
    return list
end

-- One thing's line: icon, name, its chance at the hotspot you're by (with "Current hotspot
-- only"), and owned / needed (green once you have enough). Clicking it opens its window.
local function row(parent, s, y)
    local layer = ui.Layer.new(parent)
    layer:SetPos(0, y)
    layer:SetSize(0, ROW - 2, 1.0, 0)
    local button = widgets.button(layer, "", s.open)
    button:SetSize(0, 0, 1.0, 1.0)
    local icon = ui.Sprite.new(layer)
    icon:SetAssociatedObject(s.itemId)
    icon:SetPos(4, 1)
    icon:SetSize(28, 26)
    icon.clickthrough = true
    local done = s.owned >= s.needed
    local name = widgets.text(layer, widgets.fit(s.name or "?", 120), done and widgets.DIM or widgets.NAME, widgets.SMALL_FONT)
    name:SetPos(38, 4)
    name:SetSize(120, LINE)
    name:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    if s.chance then
        local percent = s.chance * 100
        local chance = widgets.text(layer, (percent > 0 and percent < 1) and "under 1%" or (math.floor(percent + 0.5) .. "%"),
            widgets.GOLD, widgets.SMALL_FONT)
        chance:SetPos(-122, 4, 1.0, 0)
        chance:SetSize(40, LINE)
        chance:AlignTo(ui.AlignMode.BOTTOMRIGHT, ui.AlignMode.CENTRE)
    end
    local counts = widgets.text(layer, s.owned .. " / " .. s.needed, done and widgets.ENOUGH or widgets.SHORT, widgets.SMALL_FONT)
    counts:SetPos(-80, 4, 1.0, 0)
    counts:SetSize(74, LINE)
    counts:AlignTo(ui.AlignMode.BOTTOMRIGHT, ui.AlignMode.CENTRE)
end

-- Builds (or rebuilds) a window's list, in one layer that lets clicks through to the header.
local function draw(kind)
    local w = windows[kind]
    if not w then return end
    if w.area then w.area:remove() end
    if w.body then w.body:Destroy() end
    w.body = ui.Layer.new(w.box)
    w.body:SetSize(0, 0, 1.0, 1.0)
    w.body.clickthrough = true
    local y = widgets.HEADER_HEIGHT + 4
    -- The box: only what the hotspots near you can give.
    local check = ui.Check.new(w.body)
    check.stylesheetID = id.StyleSheet.CHECKBOX_DEFAULT
    check.alignment = ui.CheckAlignMode.LEFT
    check.buttonSize = 16
    check.label = "Current hotspot only"
    check.text.font = widgets.SMALL_FONT
    check.value = w.nearOnly
    check:SetPos(PAD, y)
    check:SetSize(WIDTH - 2 * PAD, LINE)
    -- The box's own state is read after the press; it may be true/false or 1/0.
    check:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        w.nearOnly = check.value == true or check.value == 1
        draw(kind)
    end)
    y = y + LINE + 2
    local near = w.nearOnly and tracking.hotspotsNear(NEAR_TILES) or nil
    w.nearSeen = near and table.concat(nearNames(near), "|") or nil
    local note = ""
    if near then
        local names = nearNames(near)
        note = #names > 0 and ("Near: " .. table.concat(names, ", ")) or ("No known hotspot within " .. NEAR_TILES .. " tiles")
    end
    local noteText = widgets.text(w.body, widgets.fit(note, WIDTH - 2 * PAD), widgets.DIM, widgets.SMALL_FONT)
    noteText:SetPos(PAD, y)
    noteText:SetSize(WIDTH - 2 * PAD, LINE)
    noteText:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    y = y + LINE + 2
    local list = listFor(kind, near)
    if #list == 0 then
        local none = widgets.text(w.body, KINDS[kind].none, widgets.DIM, widgets.SMALL_FONT)
        none:SetPos(PAD, y)
        none:SetSize(WIDTH - 2 * PAD, LINE)
        w.area = nil
        return
    end
    w.area = widgets.scrollArea(w.win, w.body, PAD, y, WIDTH - 2 * PAD, ROWS_SHOWN * ROW, #list * ROW, ROW)
    for i, s in ipairs(list) do row(w.area.content, s, (i - 1) * ROW) end
end

-- Closes one pinned window (its "Current hotspot only" choice is kept for next time).
function pinned.close(kind)
    local w = windows[kind]
    if not w then return end
    if w.area then w.area:remove() end
    widgets.destroyWindow(w.box)
    windows[kind] = { nearOnly = w.nearOnly, closed = true }
end

-- Closes both pinned windows.
function pinned.closeAll()
    for kind in pairs(KINDS) do pinned.close(kind) end
end

-- Opens a pinned window ("materials" or "damaged"), or does nothing if it's already open.
function pinned.open(kind)
    local w = windows[kind]
    if w and not w.closed then return end
    local height = widgets.HEADER_HEIGHT + 4 + 2 * (LINE + 2) + ROWS_SHOWN * ROW + PAD
    local win = widgets.window("pinned_" .. kind, KINDS[kind].title, WIDTH, height, function() pinned.close(kind) end)
    windows[kind] = { win = win, box = win.box, nearOnly = w and w.nearOnly or false }
    draw(kind)
end

-- Whether a pinned window is open.
function pinned.isOpen(kind)
    local w = windows[kind]
    return w ~= nil and not w.closed
end

-- Keeps the lists up to date: after the tracker or your storages change, and every few ticks
-- while "Current hotspot only" is ticked, as you walk between hotspots.
function pinned.start()
    -- Redraws every open window.
    local function redrawAll()
        for kind, w in pairs(windows) do
            if not w.closed then draw(kind) end
        end
    end
    tracker.onChange(redrawAll)
    storage.onUpdate(redrawAll)
    Event.ServerLogic.Subscribe("trackerPinnedNeeds", function()
        ticks = ticks + 1
        if ticks % CHECK_EVERY ~= 0 then return end
        for kind, w in pairs(windows) do
            if not w.closed and w.nearOnly then
                local now = table.concat(nearNames(tracking.hotspotsNear(NEAR_TILES)), "|")
                if now ~= w.nearSeen then draw(kind) end
            end
        end
    end)
end

return pinned
