-- The collection window: opens when a collection in the Collections window is clicked.
-- Shows who collects it and where, the level needed and the chronote reward, with a ticked
-- circle in the header once it's ever been completed (an empty circle if not). Then each artifact: full colour if handed in
-- (a black shape if not), its level, how many you have restored and damaged, and its chronotes.
-- Clicking an artifact opens its artifact window.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local chronotes = require("core/chronotes")
local collections = require("windows/collections_window")
local tracker = require("core/restoration_tracker")
local trackerWindow = require("windows/restoration_tracker_window")

local detail = {}

local WIDTH = 560
local PAD = 10
local LINE = 20                -- height of one line of text
local ARTIFACT_ROW = 42        -- height of one artifact's row
local CHRONOTE_ICON = 10315    -- ARCH_ICON_CHRONOTES_16PX
-- The artifacts table: { heading, x position, width } per column.
local COLUMNS = { { "Artifact", 52, 220 }, { "Level", 276, 50 }, { "Restored", 330, 66 }, { "Damaged", 400, 66 },
    { "Chronotes", 470, 70 } }

local box = nil      -- the window's frame, while it's open
local shown = nil    -- the collection it's showing
local dirty = false  -- something changed; rebuild on the next tick
local lastStatus = nil   -- what the window last showed, to spot hand-ins
local ticks = 0

-- A line of text at a height in the window, kept clear of the "Add to tracker" button at the
-- top right; returns the height below it.
local function line(text, y, colour, font)
    local t = widgets.text(box, text, colour, font or widgets.SMALL_FONT)
    t:SetPos(PAD, y)
    t:SetSize(-2 * PAD - 140, LINE, 1.0, 0)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return y + LINE
end

-- A section heading with a little space above it; returns the height below it.
local function heading(text, y)
    return line(text, y + 8, widgets.GOLD, widgets.BOLD_FONT)
end

-- A piece of text in one table column.
local function cell(parent, text, column, y, colour)
    local t = widgets.text(parent, text, colour, widgets.SMALL_FONT)
    t:SetPos(column[2], y)
    t:SetSize(column[3], LINE)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return t
end

-- One artifact's row: a button across it (opens the artifact window), its icon in a slot,
-- name, level, how many you have restored and damaged, and its chronotes.
local function artifactRow(collection, artifact, handed, y)
    local row = ui.Layer.new(box)
    row:SetPos(PAD, y)
    row:SetSize(-2 * PAD, ARTIFACT_ROW - 2, 1.0, 0)
    local button = widgets.button(row, "", function() require("windows/artifact_detail").open(artifact) end)
    button:SetSize(0, 0, 1.0, 1.0)
    local icon = widgets.slotIcon(row, 4, 1, ARTIFACT_ROW - 4)
    widgets.showArtifact(icon, artifact.restoredId, handed)
    local middle = (ARTIFACT_ROW - 2 - LINE) // 2
    cell(row, artifact.name, COLUMNS[1], middle, widgets.WHITE)
    cell(row, tostring(artifact.level or "?"), COLUMNS[2], middle, widgets.WHITE)
    local restored, damaged = storage.count(artifact.restoredId).total, storage.count(artifact.damagedId).total
    cell(row, tostring(restored), COLUMNS[3], middle, restored > 0 and widgets.WHITE or widgets.DIM)
    cell(row, tostring(damaged), COLUMNS[4], middle, widgets.DIM)
    local reward = chronotes.forArtifact(collection.key, artifact.key)
    cell(row, reward and collections.withCommas(reward) or "?", COLUMNS[5], middle, reward and widgets.GOLD or widgets.DIM)
end

-- Builds the window's contents for a collection. The window is sized to fit them.
local function build(collection)
    local s = collections.status(collection)
    lastStatus = s
    local collector = catalog.collectors[collection.collector] or {}
    local height = widgets.HEADER_HEIGHT + 6 + 3 * LINE + 8 + LINE + LINE + #collection.artifacts * ARTIFACT_ROW + LINE + PAD
    box = widgets.window("collection", collection.name, WIDTH, height, detail.close).box
    -- In the header, left of the close button: a ticked circle if completed before, an empty one if not.
    local tick = ui.Sprite.new(box)
    tick.sprite = s.everCompleted and widgets.TICK_IMAGE or widgets.NO_TICK_IMAGE
    tick:SetPos(-2 * widgets.HEADER_HEIGHT, 2, 1.0, 0)
    tick:SetSize(24, 24)
    tick.clickthrough = true

    -- Who collects it, where they are, what's needed and what it pays.
    local y = widgets.HEADER_HEIGHT + 6
    trackerWindow.addButton(box, "collection", collection.key, y)
    y = line("Collector: " .. (collector.name or "?") .. (collector.location and (", " .. collector.location) or ""), y, widgets.WHITE)
    y = line("Level required: " .. s.level, y, widgets.WHITE)
    local reward = chronotes.forCompletion(collection.key)
    local coin = ui.Sprite.new(box)
    coin.sprite = CHRONOTE_ICON
    coin:SetPos(PAD, y + 2)
    coin:SetSize(16, 16)
    local rewardText = widgets.text(box, reward and ("Reward: " .. collections.withCommas(reward) .. " Chronotes")
        or "Completion reward not seen yet: shown after you next complete it", reward and widgets.GOLD or widgets.DIM,
        widgets.SMALL_FONT)
    rewardText:SetPos(PAD + 22, y)
    rewardText:SetSize(-2 * PAD - 22 - 140, LINE, 1.0, 0)
    rewardText:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    y = y + LINE

    -- The artifacts, as a table.
    y = heading("Artifacts", y)
    for _, column in ipairs(COLUMNS) do
        local t = widgets.text(box, column[1], widgets.NAME, widgets.SMALL_FONT)
        t:SetPos(PAD + column[2], y)
        t:SetSize(column[3], LINE)
        t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end
    y = y + LINE
    for _, key in ipairs(collection.artifacts) do
        artifactRow(collection, catalog.artifacts[key], s.handed[key], y)
        y = y + ARTIFACT_ROW
    end
    line("Click an artifact to see where to find it and what it needs.", y + 2, widgets.DIM)
end

-- Closes the window.
function detail.close()
    widgets.destroyWindow(box)
    box, shown = nil, nil
end

-- Opens the window for a collection (replacing whichever it was showing).
function detail.open(collection)
    detail.close()
    shown = collection
    build(collection)
end

-- Whether the window is open, and for which collection.
function detail.showing()
    return shown
end

-- Whether anything shown has changed since the window was built (e.g. an artifact handed in).
local function statusChanged()
    local now = collections.status(shown)
    if now.everCompleted ~= lastStatus.everCompleted or now.completable ~= lastStatus.completable then return true end
    for _, key in ipairs(shown.artifacts) do
        if (now.handed[key] or false) ~= (lastStatus.handed[key] or false) then return true end
    end
    return false
end

-- Rebuilds the window when counts or rewards change, or an artifact is handed in, at most once a tick.
function detail.start()
    storage.onUpdate(function() dirty = true end)
    tracker.onChange(function() dirty = true end)
    chronotes.onChange(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerCollectionDetailRedraw", function()
        ticks = ticks + 1
        if shown and (dirty or (ticks % 5 == 0 and statusChanged())) then detail.open(shown) end
        dirty = false
    end)
end

return detail
