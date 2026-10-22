-- The Restoration Tracker window. Top: what you're tracking (collections and artifacts), each with a
-- "-  N  +" count and a remove button. Bottom: what that all needs, as owned / needed: the
-- restored artifacts you already have towards it (and where they're kept), the damaged
-- artifacts still to restore, then the materials for them. Green once you have enough.
-- The damaged artifacts and materials each have a "Pin" button, for a small window that stays open.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local progress = require("core/progress")
local tracker = require("core/restoration_tracker")

local window = {}

local WIDTH = 560
local PAD = 10
local LINE = 20
local ROW = 54                     -- one tracked entry
local ROWS_SHOWN = 4               -- tracked entries shown before the rest scroll
local SLOT = 34                    -- a collection's artifact slots
local SQUARE_W, SQUARE_H, GAP = 80, 92, 6   -- one needed thing's square
local PER_ROW = 6
local NEEDS_H = 2 * (SQUARE_H + GAP) + 2 * (LINE + 8)   -- the needs section's visible height
local CHECK_EVERY = 5              -- ticks between checks for hand-ins while open (3 s)
local HAVE_ROW = 40                -- one restored artifact you have
-- Storages in the order they're listed, with the words shown for them.
local STORAGES = { { "backpack", "backpack" }, { "bank", "bank" }, { "artifactStorage", "artifact storage" } }

local win, box = nil, nil
local areas = {}       -- scrolling sections, removed when the window closes or redraws
local dirty = false    -- something changed; redraw on the next tick
local lastHanded = nil -- collection flags last drawn, to spot hand-ins
local ticks = 0

-- Text in a part of the window.
local function text(parent, content, x, y, w, h, colour, font)
    local t = widgets.text(parent, content, colour, font or widgets.SMALL_FONT)
    t:SetPos(x, y)
    t:SetSize(w, h)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return t
end

-- A small button.
local function smallButton(parent, label, x, y, w, onPress)
    local b = widgets.button(parent, label, onPress)
    b:SetPos(x, y)
    b:SetSize(w, 24)
    return b
end

-- One tracked entry's row: what it is, then "-  N  +" and a remove button at the right.
local function entryRow(parent, index, entry, y)
    local row = ui.Layer.new(parent)
    row:SetPos(0, y)
    row:SetSize(0, ROW - 4, 1.0, 0)
    local background = widgets.box(row, widgets.PANEL)
    background:SetSize(0, 0, 1.0, 1.0)
    if entry.kind == "collection" then
        -- A collection: its name, then its artifacts (full colour if handed in, black if not).
        local collection = catalog.collections[entry.key]
        text(row, widgets.fit(collection.name, 260), 8, 0, 260, 18, widgets.NAME)
        for n, key in ipairs(collection.artifacts) do
            if n > 9 then break end
            local icon = widgets.slotIcon(row, 8 + (n - 1) * (SLOT - 2), 17, SLOT - 4)
            widgets.showArtifact(icon, catalog.artifacts[key].restoredId, progress.collectionHas(entry.key, key))
        end
    else
        -- An artifact: its icon, name, and how many damaged + restored you have.
        local artifact = catalog.artifacts[entry.key]
        local icon = ui.Sprite.new(row)
        icon:SetAssociatedObject(artifact.restoredId)
        icon:SetPos(8, 4)
        icon:SetSize(44, 42)
        icon.clickthrough = true
        text(row, widgets.fit(artifact.name, 220), 60, 4, 220, 20, widgets.NAME)
        text(row, storage.count(artifact.damagedId).total .. " damaged + " .. storage.count(artifact.restoredId).total
            .. " restored", 60, 24, 220, 20, widgets.DIM)
    end
    -- The count: how many times to complete this collection or restore this artifact.
    local right = WIDTH - 2 * PAD - widgets.SCROLLBAR_WIDTH - 4
    smallButton(row, "-", right - 148, 13, 28, function() tracker.step(index, -1) end).enabled = entry.count > 1
    local count = text(row, "x" .. entry.count, right - 116, 13, 40, 24, widgets.WHITE, widgets.BOLD_FONT)
    count:AlignTo(ui.AlignMode.CENTRE)
    smallButton(row, "+", right - 72, 13, 28, function() tracker.step(index, 1) end)
    smallButton(row, "X", right - 40, 13, 36, function() tracker.remove(index) end)   -- stop tracking it
end

-- One needed thing: name header, icon, and "owned / needed" (green if you have enough).
-- Clicking it opens its window.
local function needSquare(parent, name, itemId, owned, needed, onPress, x, y)
    local square = ui.Layer.new(parent)
    square:SetPos(x, y)
    square:SetSize(SQUARE_W, SQUARE_H)
    local button = widgets.button(square, "", onPress)
    button:SetSize(0, 0, 1.0, 1.0)
    local header = ui.Button.new(square)
    header.stylesheetID = id.StyleSheet.TAB_HEADER_24PX
    header:SetPos(2, 2)
    header:SetSize(-4, 34, 1.0, 0)
    header.clickthrough = true
    local label = widgets.text(square, (widgets.wrap(name or "?", 10)), widgets.NAME, widgets.SMALL_FONT)
    label:SetPos(3, 3)
    label:SetSize(-6, 32, 1.0, 0)
    label.maxLines = 2
    label:AlignTo(ui.AlignMode.CENTRE)
    local icon = ui.Sprite.new(square)
    icon:SetAssociatedObject(itemId)
    icon:SetPos(SQUARE_W // 2 - 18, 38)
    icon:SetSize(36, 30)
    icon.clickthrough = true
    local counts = widgets.text(square, owned .. " / " .. needed, owned >= needed and widgets.ENOUGH or widgets.SHORT,
        widgets.SMALL_FONT)
    counts:SetPos(0, -22, 0, 1.0)
    counts:SetSize(0, 20, 1.0, 0)
    counts:AlignTo(ui.AlignMode.CENTRE)
end

-- Lays out squares in rows from height y; returns the height below them.
local function squares(parent, list, y)
    for i, s in ipairs(list) do
        local col, row = (i - 1) % PER_ROW, (i - 1) // PER_ROW
        needSquare(parent, s.name, s.itemId, s.owned, s.needed, s.open, col * (SQUARE_W + GAP), y + row * (SQUARE_H + GAP))
    end
    return y + math.ceil(#list / PER_ROW) * (SQUARE_H + GAP)
end

-- "bank 1, backpack 1": where your copies of an item are kept.
local function whereKept(itemId)
    local c, parts = storage.count(itemId), {}
    for _, s in ipairs(STORAGES) do
        if (c[s[1]] or 0) > 0 then table.insert(parts, s[2] .. " " .. c[s[1]]) end
    end
    return table.concat(parts, ", ")
end

-- One restored artifact you have towards your goals: icon, name, "have / wanted" (green once
-- you have them all) and where they're kept. Clicking it opens the artifact.
local function haveRow(parent, entry, y)
    local row = ui.Layer.new(parent)
    row:SetPos(0, y)
    row:SetSize(0, HAVE_ROW - 4, 1.0, 0)
    local button = widgets.button(row, "", entry.open)
    button:SetSize(0, 0, 1.0, 1.0)
    local icon = ui.Sprite.new(row)
    icon:SetAssociatedObject(entry.itemId)
    icon:SetPos(6, 2)
    icon:SetSize(34, 32)
    icon.clickthrough = true
    text(row, widgets.fit(entry.name, 190), 48, 8, 190, LINE, widgets.NAME)
    local counts = text(row, entry.owned .. " / " .. entry.needed, 240, 8, 60, LINE,
        entry.owned >= entry.needed and widgets.ENOUGH or widgets.SHORT)
    counts:AlignTo(ui.AlignMode.CENTRE)
    text(row, widgets.fit(entry.where, 200), 306, 8, 200, LINE, widgets.DIM)
end

-- The needs: restored artifacts you have towards the goals, damaged artifacts to restore, then
-- materials, each sorted by name.
local function needsLists()
    local restores, materials, wanted = tracker.needs()
    local have, damaged, mats = {}, {}, {}
    for key, n in pairs(wanted) do
        local a = catalog.artifacts[key]
        local owned = storage.count(a.restoredId).total
        if n > 0 and owned > 0 then
            table.insert(have, { name = a.name, itemId = a.restoredId, owned = math.min(owned, n), needed = n,
                where = whereKept(a.restoredId), open = function() require("windows/artifact_detail").open(a) end })
        end
    end
    for key, n in pairs(restores) do
        local a = catalog.artifacts[key]
        -- (The Tetracompass has no damaged version: its pieces show under materials instead.)
        if a.damagedId then table.insert(damaged, { name = a.name, itemId = a.damagedId, owned = storage.count(a.damagedId).total, needed = n,
            open = function() require("windows/artifact_detail").open(a) end }) end
    end
    for itemId, n in pairs(materials) do
        local m = catalog.materials[itemId]
        table.insert(mats, { name = m and m.name, itemId = itemId, owned = storage.count(itemId).total, needed = n,
            open = function() if m then require("windows/material_detail").open(m) end end })
    end
    for _, list in ipairs({ have, damaged, mats }) do
        table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    end
    return have, damaged, mats
end

-- Which artifacts are handed in to the tracked collections, as text, to notice hand-ins.
local function handedState()
    local parts = {}
    for _, e in ipairs(tracker.entries()) do
        if e.kind == "collection" and catalog.collections[e.key] then
            for _, key in ipairs(catalog.collections[e.key].artifacts) do
                if progress.collectionHas(e.key, key) then table.insert(parts, e.key .. "/" .. key) end
            end
        end
    end
    return table.concat(parts, ",")
end

-- Shared with the Overview window's small version of the tracker.
window.needsLists, window.needSquare = needsLists, needSquare

-- A "Pin" button by a section's heading: opens a small window listing just that section
-- ("damaged" or "materials"), to keep on screen while digging.
local function pinButton(parent, kind, y)
    local b = widgets.button(parent, "Pin", function() require("windows/pinned_needs_window").open(kind) end)
    b:SetPos(-60, y - 2, 1.0, 0)
    b:SetSize(56, 22)
end

-- Builds (or rebuilds) everything inside the window.
local function draw()
    for _, area in ipairs(areas) do area:remove() end
    areas = {}
    -- Everything is drawn in one layer over the whole window, removed and redrawn each time. It
    -- lets clicks through, so the window's header can still be dragged.
    if window.body then window.body:Destroy() end
    local body = ui.Layer.new(box)
    body:SetSize(0, 0, 1.0, 1.0)
    body.clickthrough = true
    window.body = body
    lastHanded = handedState()

    -- What you're tracking.
    local entries = tracker.entries()
    local y = widgets.HEADER_HEIGHT + 6
    text(body, "Tracking", PAD, y, 300, LINE, widgets.GOLD, widgets.BOLD_FONT)
    y = y + LINE + 4
    if #entries == 0 then
        text(body, "Nothing tracked yet. Use \"Add to tracker\" in an artifact or collection window.",
            PAD, y, WIDTH - 2 * PAD, ROWS_SHOWN * ROW, widgets.DIM)
    else
        local area = widgets.scrollArea(win, body, PAD, y, WIDTH - 2 * PAD, ROWS_SHOWN * ROW,
            #entries * ROW, ROW)
        table.insert(areas, area)
        for i, entry in ipairs(entries) do entryRow(area.content, i, entry, (i - 1) * ROW) end
    end
    y = y + ROWS_SHOWN * ROW + 8

    -- What it all needs.
    text(body, "Needed (owned / needed)", PAD, y, 300, LINE, widgets.GOLD, widgets.BOLD_FONT)
    y = y + LINE + 4
    local have, damaged, materials = needsLists()
    if #have == 0 and #damaged == 0 and #materials == 0 then return end
    -- Each part only appears if it has something in it.
    local contentH = (#have > 0 and (LINE + 4 + #have * HAVE_ROW + 4) or 0)
        + (#damaged > 0 and (LINE + 8 + math.ceil(#damaged / PER_ROW) * (SQUARE_H + GAP)) or 0)
        + (#materials > 0 and (LINE + 8 + math.ceil(#materials / PER_ROW) * (SQUARE_H + GAP)) or 0)
        + (#damaged == 0 and LINE or 0)
    local area = widgets.scrollArea(win, body, PAD, y, WIDTH - 2 * PAD, NEEDS_H, contentH, SQUARE_H + GAP)
    table.insert(areas, area)
    local inner = 0
    if #have > 0 then
        text(area.content, "Restored artifacts you have", 0, inner, 300, LINE, widgets.NAME)
        inner = inner + LINE + 4
        for i, entry in ipairs(have) do haveRow(area.content, entry, inner + (i - 1) * HAVE_ROW) end
        inner = inner + #have * HAVE_ROW + 4
    end
    if #damaged == 0 then
        text(area.content, "Nothing more needed: you have every restored artifact.", 0, inner, WIDTH - 2 * PAD, LINE,
            widgets.ENOUGH)
        return
    end
    text(area.content, "Damaged artifacts to restore", 0, inner, 300, LINE, widgets.NAME)
    pinButton(area.content, "damaged", inner)
    inner = squares(area.content, damaged, inner + LINE + 4)
    text(area.content, "Materials", 0, inner + 4, 300, LINE, widgets.NAME)
    pinButton(area.content, "materials", inner + 4)
    squares(area.content, materials, inner + LINE + 8)
end

-- The "Add to tracker" button for an artifact or collection window, at its top right, with a
-- note under it saying how many times it's tracked. Each press adds one more.
function window.addButton(parent, kind, key, y)
    local button = widgets.button(parent, "Add to tracker", function() tracker.add(kind, key) end)
    button:SetPos(-PAD - 130, y, 1.0, 0)
    button:SetSize(130, 24)
    local n = tracker.countOf(kind, key)
    if n > 0 then
        local note = widgets.text(parent, "In tracker: x" .. n, widgets.ENOUGH, widgets.SMALL_FONT)
        note:SetPos(-PAD - 130, y + 26, 1.0, 0)
        note:SetSize(130, 18)
        note:AlignTo(ui.AlignMode.CENTRE)
    end
end

-- Closes the window.
function window.close()
    for _, area in ipairs(areas) do area:remove() end
    widgets.destroyWindow(box)
    win, box, areas, window.body = nil, nil, {}, nil
end

-- Opens the window, or does nothing if it's already open.
function window.open()
    if box then return end
    win = widgets.window("restoreTracker", "Restoration Tracker", WIDTH,
        widgets.HEADER_HEIGHT + 6 + 2 * (LINE + 4) + ROWS_SHOWN * ROW + 8 + NEEDS_H + PAD, window.close)
    box = win.box
    draw()
end

-- Whether the window is open.
function window.isOpen()
    return box ~= nil
end

-- Redraws when the list or your storages change, and every few ticks if artifacts were handed in.
function window.start()
    tracker.onChange(function() dirty = true end)
    storage.onUpdate(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerRestoreTrackerRedraw", function()
        ticks = ticks + 1
        if box and (dirty or (ticks % CHECK_EVERY == 0 and handedState() ~= lastHanded)) then draw() end
        dirty = false
    end)
end

return window
