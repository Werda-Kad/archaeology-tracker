-- The material window: opens when a material is clicked (in the Materials window or an
-- artifact's recipe). Shows its level, how many you have and where, the artifacts it's used to
-- restore (with how many each needs; click one to open it), and the hotspots and caches it's
-- dug up at, each with a Track button.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local tracking = require("tracking/tracking")
local hotspotTable = require("ui/hotspot_table")

local detail = {}

local WIDTH = 560
local PAD = 10
local LINE = 20                    -- height of one line of text
local SQUARE, SQUARE_GAP = 60, 6   -- an artifact's square in "Used to restore"
local PER_ROW = 7                  -- artifact squares per row (room left for the scrollbar)
local USED_ROWS = 3                -- rows of artifacts shown before the rest scroll
-- Storages in the order they're listed, with the words shown for them.
local STORAGES = { { "backpack", "backpack" }, { "bank", "bank" }, { "materialStorage", "material storage" } }

local win, box = nil, nil   -- the window and its frame, while it's open
local areas = {}     -- its scrolling sections, removed when it closes
local shown = nil    -- the material it's showing
local dirty = false  -- counts or tracking changed; rebuild on the next tick

-- The artifacts whose recipe uses this material, lowest level first, with the amount each needs.
local function usedBy(material)
    local list = {}
    for _, artifact in pairs(catalog.artifacts) do
        for _, m in ipairs(artifact.materials) do
            if m.itemId == material.itemId then table.insert(list, { artifact = artifact, amount = m.amount }) end
        end
    end
    table.sort(list, function(a, b)
        if (a.artifact.level or 0) ~= (b.artifact.level or 0) then return (a.artifact.level or 0) < (b.artifact.level or 0) end
        return a.artifact.name < b.artifact.name
    end)
    return list
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

-- One artifact that uses the material: its icon and how many of the material it needs.
-- Clicking it opens the artifact's window.
local function artifactSquare(parent, entry, x, y)
    local square = ui.Layer.new(parent)
    square:SetPos(x, y)
    square:SetSize(SQUARE, SQUARE)
    local button = widgets.button(square, "", function() require("windows/artifact_detail").open(entry.artifact) end)
    button:SetSize(0, 0, 1.0, 1.0)
    local icon = ui.Sprite.new(square)
    icon:SetAssociatedObject(entry.artifact.restoredId)
    icon:SetPos(SQUARE // 2 - 18, 4)
    icon:SetSize(36, 34)
    icon.clickthrough = true
    local amount = widgets.text(square, "x" .. entry.amount, widgets.WHITE, widgets.SMALL_FONT)
    amount:SetPos(0, -20, 0, 1.0)
    amount:SetSize(0, 18, 1.0, 0)
    amount:AlignTo(ui.AlignMode.CENTRE)
end

-- Builds the window's contents for a material. The window is sized to fit them.
local function build(material)
    local users = usedBy(material)
    local hotspots = hotspotTable.list(material.hotspots or {})
    local userRows = math.max(1, math.min(USED_ROWS, math.ceil(#users / PER_ROW)))
    local height = widgets.HEADER_HEIGHT + 6 + 52 + 8 + 2 * LINE + 8 + LINE + userRows * (SQUARE + SQUARE_GAP)
        + LINE + 8 + hotspotTable.height(#hotspots) + PAD
    win = widgets.window("material", material.name or "Material", WIDTH, height, detail.close)
    box = win.box

    -- Top: the icon, and for archaeology materials their level. Ordinary items (white candles,
    -- rubies...) just show the icon.
    local y = widgets.HEADER_HEIGHT + 6
    local icon = ui.Sprite.new(box)
    icon:SetAssociatedObject(material.itemId)
    icon:SetPos(PAD, y)
    icon:SetSize(56, 52)
    if material.isArchaeologyMaterial then
        local facts = widgets.text(box, "Level " .. tostring(material.level or "?") .. "<br>Archaeology material",
            widgets.WHITE, widgets.FONT)
        facts:SetPos(PAD + 66, y)
        facts:SetSize(-2 * PAD - 66, 52, 1.0, 0)
        facts:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end
    y = y + 52

    -- How many you have, and where.
    y = heading("You have", y)
    local c, parts = storage.count(material.itemId), {}
    for _, s in ipairs(STORAGES) do
        if (c[s[1]] or 0) > 0 then table.insert(parts, s[2] .. " " .. c[s[1]]) end
    end
    y = line(c.total .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""), y, c.total > 0 and widgets.WHITE or widgets.DIM)

    -- The artifacts it's used to restore, in rows of squares; more than three rows scroll.
    y = heading("Used to restore", y)
    if #users == 0 then
        y = line("No artifacts", y, widgets.DIM)
    else
        local step = SQUARE + SQUARE_GAP
        local area = widgets.scrollArea(win, box, PAD, y, WIDTH - 2 * PAD, userRows * step,
            math.ceil(#users / PER_ROW) * step, step)
        table.insert(areas, area)
        for i, entry in ipairs(users) do
            local col, row = (i - 1) % PER_ROW, (i - 1) // PER_ROW
            artifactSquare(area.content, entry, col * step, row * step)
        end
        y = y + userRows * step
    end

    -- Where it's dug up: hotspots and material caches.
    y = heading("Found at", y)
    local _, area = hotspotTable.build(win, box, WIDTH, hotspots, y, "Not dug up")
    if area then table.insert(areas, area) end
end

-- Closes the window.
function detail.close()
    for _, area in ipairs(areas) do area:remove() end
    widgets.destroyWindow(box)
    win, box, shown, areas = nil, nil, nil, {}
end

-- Opens the window for a material (replacing whichever it was showing).
function detail.open(material)
    detail.close()
    shown = material
    build(material)
end

-- Whether the window is open, and for which material.
function detail.showing()
    return shown
end

-- Rebuilds the window when counts or tracking change, at most once per server tick.
function detail.start()
    storage.onUpdate(function() dirty = true end)
    tracking.onChange(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerMaterialDetailRedraw", function()
        if dirty and shown then detail.open(shown) end
        dirty = false
    end)
end

return detail
