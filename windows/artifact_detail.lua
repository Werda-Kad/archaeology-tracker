-- The artifact window: opens when an artifact's square is clicked. Shows its level, XP and
-- description, how many you have and where they are, the materials to restore it
-- (needed / owned), the hotspots it's dug up at (each with a Track button), and the
-- collections that take it.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local tracking = require("tracking/tracking")
local progress = require("core/progress")
local hotspotTable = require("ui/hotspot_table")
local tracker = require("core/restoration_tracker")
local trackerWindow = require("windows/restoration_tracker_window")
local chronotes = require("core/chronotes")

local detail = {}

local WIDTH = 560
local PAD = 10
local LINE = 20                    -- height of one line of text
local DESCRIPTION_CHARS = 72       -- characters per line of the description at this width
local SQUARE_W, SQUARE_H, GAP = 86, 96, 6
local COLLECTION_ROW = 30          -- height of one collection's button
local CHRONOTE_ICON = 10315        -- ARCH_ICON_CHRONOTES_16PX
local PER_ROW = 5                  -- material squares per row
-- Storages in the order they're listed, with the words shown for them.
local STORAGES = { { "backpack", "backpack" }, { "bank", "bank" },
    { "artifactStorage", "artifact storage" }, { "materialStorage", "material storage" } }

local win, box = nil, nil   -- the window and its frame, while it's open
local hotspotArea = nil      -- the Found at table's scrolling section, removed when it closes
local shown = nil    -- the artifact it's showing
local dirty = false  -- counts changed; rebuild on the next tick

-- "3 (bank 2, backpack 1)": how many of an item you have, and where.
local function whereStored(itemId)
    local c, parts = storage.count(itemId), {}
    for _, s in ipairs(STORAGES) do
        if c[s[1]] > 0 then table.insert(parts, s[2] .. " " .. c[s[1]]) end
    end
    return c.total, #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
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

-- One material square: name header, icon, and "needed / owned" (green if you have enough).
-- Clicking it opens the material's window.
local function materialSquare(material, amount, x, y)
    local square = ui.Layer.new(box)
    square:SetPos(x, y)
    square:SetSize(SQUARE_W, SQUARE_H)
    local button = widgets.button(square, "", function() require("windows/material_detail").open(material) end)
    button:SetSize(0, 0, 1.0, 1.0)
    local header = ui.Button.new(square)
    header.stylesheetID = id.StyleSheet.TAB_HEADER_24PX
    header:SetPos(2, 2)
    header:SetSize(-4, 34, 1.0, 0)
    header.clickthrough = true
    local name = widgets.text(square, widgets.wrap(material.name, 11), widgets.NAME, widgets.SMALL_FONT)
    name:SetPos(3, 3)
    name:SetSize(-6, 32, 1.0, 0)
    name.maxLines = 2
    name:AlignTo(ui.AlignMode.CENTRE)
    local icon = ui.Sprite.new(square)
    icon:SetAssociatedObject(material.itemId)
    icon:SetPos(SQUARE_W // 2 - 20, 38)
    icon:SetSize(40, 34)
    icon.clickthrough = true
    local owned = storage.count(material.itemId).total
    local counts = widgets.text(square, amount .. " / " .. owned, owned >= amount and widgets.ENOUGH or widgets.SHORT,
        widgets.SMALL_FONT)
    counts:SetPos(0, -22, 0, 1.0)
    counts:SetSize(0, 20, 1.0, 0)
    counts:AlignTo(ui.AlignMode.CENTRE)
end

-- One collection that takes this artifact, as a button that opens it: its name (green once
-- ever completed), the artifact's icon in a slot (a black shape until handed in to it), and its chronotes.
local function collectionRow(artifact, collection, y)
    local row = ui.Layer.new(box)
    row:SetPos(PAD, y)
    row:SetSize(-2 * PAD, COLLECTION_ROW - 2, 1.0, 0)
    local button = widgets.button(row, "", function() require("windows/collection_detail").open(collection) end)
    button:SetSize(0, 0, 1.0, 1.0)
    local collector = catalog.collectors[collection.collector]
    local name = widgets.text(row, collection.name .. "  -  " .. (collector and collector.name or "?"),
        progress.collectionEverCompleted(collection.key) and widgets.ENOUGH or widgets.WHITE, widgets.SMALL_FONT)
    name:SetPos(8, 4)
    name:SetSize(-150, LINE, 1.0, 0)
    name:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    local icon, slot = widgets.slotIcon(row, 0, 0, COLLECTION_ROW - 2)
    slot:SetPos(-136, 0, 1.0, 0)
    icon:SetPos(-132, 4, 1.0, 0)
    widgets.showArtifact(icon, artifact.restoredId, progress.collectionHas(collection.key, artifact.key))
    local reward = chronotes.forArtifact(collection.key, artifact.key)
    local amount = widgets.text(row, reward and tostring(reward) or "?", reward and widgets.GOLD or widgets.DIM, widgets.SMALL_FONT)
    amount:SetPos(-96, 4, 1.0, 0)
    amount:SetSize(60, LINE)
    amount:AlignTo(ui.AlignMode.BOTTOMRIGHT, ui.AlignMode.CENTRE)
    local coin = ui.Sprite.new(row)
    coin.sprite = CHRONOTE_ICON
    coin:SetPos(-30, 6, 1.0, 0)
    coin:SetSize(16, 16)
    coin.clickthrough = true
end

-- Builds the window's contents for an artifact. The window is sized to fit them.
local function build(artifact)
    local description, descriptionLines = widgets.wrap(artifact.description or "", DESCRIPTION_CHARS)
    local hotspots = hotspotTable.list(artifact.hotspots)
    local materialRows = math.max(1, math.ceil(#artifact.materials / PER_ROW))
    local height = widgets.HEADER_HEIGHT + 70 + LINE + descriptionLines * 16 + 3 * LINE + 8 + LINE + 8
        + materialRows * (SQUARE_H + GAP) + LINE + 8 + hotspotTable.height(#hotspots)
        + LINE + 8 + math.max(1, #artifact.collections) * COLLECTION_ROW + PAD
    win = widgets.window("artifact", artifact.name, WIDTH, height, detail.close)
    box = win.box

    -- Top: the restored artifact's icon, its level and XP, then the game's description.
    local y = widgets.HEADER_HEIGHT + 6
    local icon = ui.Sprite.new(box)
    icon:SetAssociatedObject(artifact.restoredId)
    icon:SetPos(PAD, y)
    icon:SetSize(56, 52)
    -- XP with at most one decimal place: 430.8, or 300 rather than 300.0.
    local xp = artifact.xp and (string.format("%.1f", artifact.xp):gsub("%.0$", "")) or "?"
    local facts = widgets.text(box, "Level " .. tostring(artifact.level or "?") .. "<br>"
        .. xp .. " XP", widgets.WHITE, widgets.FONT)
    facts:SetPos(PAD + 66, y)
    facts:SetSize(-2 * PAD - 66 - 140, 52, 1.0, 0)
    trackerWindow.addButton(box, "artifact", artifact.key, y + 4)
    facts:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    y = y + 60
    -- What the museum donation bin gives for it (40% of its collection reward).
    local donation = chronotes.forDonation(artifact.key)
    if donation then
        local coin = ui.Sprite.new(box)
        coin.sprite = CHRONOTE_ICON
        coin:SetPos(PAD, y + 2)
        coin:SetSize(16, 16)
        local text = widgets.text(box, "Museum donation bin: " .. widgets.withCommas(donation) .. " chronotes", widgets.DIM,
            widgets.SMALL_FONT)
        text:SetPos(PAD + 22, y)
        text:SetSize(-2 * PAD - 22, LINE, 1.0, 0)
        text:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end
    y = y + LINE
    if descriptionLines > 0 then
        local d = widgets.text(box, description, widgets.DIM, widgets.SMALL_FONT)
        d:SetPos(PAD, y)
        d:SetSize(-2 * PAD, descriptionLines * 16 + 4, 1.0, 0)
        d:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.TOPLEFT)
        y = y + descriptionLines * 16 + 4
    end

    -- How many you have, and where.
    y = heading("You have", y)
    local damaged, damagedWhere = whereStored(artifact.damagedId)
    local restored, restoredWhere = whereStored(artifact.restoredId)
    -- The Tetracompass and its pieces have no damaged version.
    if artifact.damagedId then y = line(damaged .. " damaged" .. damagedWhere, y, widgets.DIM) end
    y = line(restored .. " restored" .. restoredWhere, y, widgets.WHITE)

    -- Materials to restore it, in rows of squares.
    y = heading("Materials to restore", y)
    if #artifact.materials == 0 then
        y = line("None", y, widgets.DIM)
    else
        for i, m in ipairs(artifact.materials) do
            local col, row = (i - 1) % PER_ROW, (i - 1) // PER_ROW
            materialSquare(catalog.materials[m.itemId], m.amount, PAD + col * (SQUARE_W + GAP), y + row * (SQUARE_H + GAP))
        end
        y = y + materialRows * (SQUARE_H + GAP)
    end

    -- Where it's dug up.
    y = heading("Found at", y)
    y, hotspotArea = hotspotTable.build(win, box, WIDTH, hotspots, y, "No hotspot (not dug up)")

    -- The collections that take it.
    y = heading("Collections", y)
    if #artifact.collections == 0 then line("Not part of any collection", y, widgets.DIM) end
    for _, key in ipairs(artifact.collections) do
        collectionRow(artifact, catalog.collections[key], y)
        y = y + COLLECTION_ROW
    end
end

-- Closes the window.
function detail.close()
    if hotspotArea then hotspotArea:remove() end
    hotspotArea = nil
    widgets.destroyWindow(box)
    box, shown = nil, nil
end

-- Opens the window for an artifact (replacing whichever artifact it was showing).
function detail.open(artifact)
    detail.close()
    shown = artifact
    build(artifact)
end

-- Whether the window is open, and for which artifact.
function detail.showing()
    return shown
end

-- Rebuilds the window when counts or tracking change, at most once per server tick.
function detail.start()
    storage.onUpdate(function() dirty = true end)
    tracker.onChange(function() dirty = true end)
    tracking.onChange(function() dirty = true end)
    chronotes.onChange(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerDetailRedraw", function()
        if dirty and shown then detail.open(shown) end
        dirty = false
    end)
end

return detail
