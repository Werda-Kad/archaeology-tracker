-- The relic window: the relic itself, the item that unlocks a relic power. Opens from the
-- relic power's window. Shows the relic's icon, the power it unlocks, how many you have, its
-- recipe (when it's made from one: level and materials, needed / owned), and where to reclaim
-- it if lost.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")

local detail = {}

local WIDTH = 480
local PAD = 10
local LINE = 20                    -- height of one line of text
local CHARS = 60                   -- characters per line of wrapped text at this width
local SQUARE_W, SQUARE_H, GAP = 86, 96, 6   -- one recipe material's square
local PER_ROW = 5
-- Storages in the order they're listed, with the words shown for them.
local STORAGES = { { "backpack", "backpack" }, { "bank", "bank" } }

local box = nil      -- the window's frame, while it's open
local shown = nil    -- the relic power whose relic it's showing
local dirty = false  -- counts changed; rebuild on the next tick

-- Wrapped text at a height in the window; returns the height below it.
local function paragraph(text, y, colour)
    local wrapped, lines = widgets.wrap(text, CHARS)
    local t = widgets.text(box, wrapped, colour, widgets.SMALL_FONT)
    t:SetPos(PAD, y)
    t:SetSize(-2 * PAD, math.max(1, lines) * 16 + 4, 1.0, 0)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.TOPLEFT)
    return y + math.max(1, lines) * 16 + 4
end

-- How many lines a text takes when wrapped.
local function linesOf(text)
    local _, lines = widgets.wrap(text or "", CHARS)
    return math.max(1, lines)
end

-- A section heading with a little space above it; returns the height below it.
local function heading(text, y)
    local t = widgets.text(box, text, widgets.GOLD, widgets.BOLD_FONT)
    t:SetPos(PAD, y + 8)
    t:SetSize(-2 * PAD, LINE, 1.0, 0)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return y + 8 + LINE
end

-- One recipe material: name header, icon, and "needed / owned" (green if you have enough).
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
    local name = widgets.text(square, (widgets.wrap(material.name or "?", 11)), widgets.NAME, widgets.SMALL_FONT)
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

-- Builds the window's contents for a relic power's relic. The window is sized to fit them.
local function build(relic)
    local recipeRows = math.ceil(#relic.materials / PER_ROW)
    local height = widgets.HEADER_HEIGHT + 6 + 52 + 8 + (LINE + 8) + 52 + (LINE + 8) + LINE
        + (#relic.materials > 0 and (LINE + 8 + LINE + recipeRows * (SQUARE_H + GAP)) or 0)
        + (relic.reclaim and (linesOf(relic.reclaim) * 16 + 12) or 0) + PAD
    box = widgets.window("relic", relic.itemName or "Relic", WIDTH, height, detail.close).box

    -- The relic's icon.
    local y = widgets.HEADER_HEIGHT + 6
    local icon = ui.Sprite.new(box)
    icon:SetAssociatedObject(relic.itemId)
    icon:SetPos(WIDTH // 2 - 28, y)
    icon:SetSize(56, 52)
    y = y + 60

    -- The power it unlocks, as a button opening the power's window.
    y = heading("Unlocks", y)
    local row = ui.Layer.new(box)
    row:SetPos(PAD, y)
    row:SetSize(-2 * PAD, 48, 1.0, 0)
    local button = widgets.button(row, "", function() require("windows/relic_power_detail").open(relic) end)
    button:SetSize(0, 0, 1.0, 1.0)
    local powerIcon = ui.Sprite.new(row)
    powerIcon.sprite = relic.icon
    powerIcon:SetPos(6, 4)
    powerIcon:SetSize(40, 40)
    powerIcon.clickthrough = true
    local name = widgets.text(row, relic.name or "?", widgets.NAME, widgets.SMALL_FONT)
    name:SetPos(54, 0)
    name:SetSize(-60, 48, 1.0, 0)
    name:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    y = y + 52

    -- How many you have, and where.
    y = heading("You have", y)
    local c, parts = storage.count(relic.itemId), {}
    for _, s in ipairs(STORAGES) do
        if (c[s[1]] or 0) > 0 then table.insert(parts, s[2] .. " " .. c[s[1]]) end
    end
    local have = widgets.text(box, c.total .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""),
        c.total > 0 and widgets.WHITE or widgets.DIM, widgets.SMALL_FONT)
    have:SetPos(PAD, y)
    have:SetSize(-2 * PAD, LINE, 1.0, 0)
    y = y + LINE

    -- Its recipe, if it's made from one: the level needed, then the materials.
    if #relic.materials > 0 then
        y = heading("Recipe", y)
        local level = widgets.text(box, "Level " .. tostring(relic.level or "?"), widgets.WHITE, widgets.SMALL_FONT)
        level:SetPos(PAD, y)
        level:SetSize(-2 * PAD, LINE, 1.0, 0)
        y = y + LINE
        for i, m in ipairs(relic.materials) do
            local col, r = (i - 1) % PER_ROW, (i - 1) // PER_ROW
            materialSquare(catalog.materials[m.itemId], m.amount, PAD + col * (SQUARE_W + GAP), y + r * (SQUARE_H + GAP))
        end
        y = y + recipeRows * (SQUARE_H + GAP)
    end
    -- Where to get it back if lost (the game's own text).
    if relic.reclaim then paragraph(relic.reclaim, y + 8, widgets.DIM) end
end

-- Closes the window.
function detail.close()
    widgets.destroyWindow(box)
    box, shown = nil, nil
end

-- Opens the window for a relic power's relic (replacing whichever it was showing).
function detail.open(relic)
    detail.close()
    shown = relic
    build(relic)
end

-- Whether the window is open, and for which relic power's relic.
function detail.showing()
    return shown
end

-- Rebuilds the window when counts change (materials or the relic itself), at most once per tick.
function detail.start()
    storage.onUpdate(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerRelicDetailRedraw", function()
        if dirty and shown then detail.open(shown) end
        dirty = false
    end)
end

return detail
