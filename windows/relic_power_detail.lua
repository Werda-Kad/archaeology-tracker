-- The relic power window: opens when a relic power is clicked. Shows its large icon, name and
-- effect, whether you've unlocked it and which of your loadouts use it, and the relic (the item
-- that unlocks it), as a button opening the relic's own window.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local progress = require("core/progress")

local detail = {}

local WIDTH = 480
local PAD = 10
local LINE = 20                    -- height of one line of text
local CHARS = 60                   -- characters per line of wrapped text at this width

local box = nil      -- the window's frame, while it's open
local shown = nil    -- the relic power it's showing
local lastState = nil -- unlocked and loadouts when last drawn, to spot changes
local ticks = 0

-- Which of your loadouts (numbered 1-3) hold this power, as text like "1, 3", and whether the active one does.
local function inLoadouts(relic)
    local found, inActive = {}, false
    for n = 0, 2 do   -- the three loadouts
        for _, number in ipairs(progress.loadoutRelics(n)) do
            if number == relic.number then
                table.insert(found, tostring(n + 1))
                if n == progress.activeLoadout() then inActive = true end
            end
        end
    end
    return table.concat(found, ", "), inActive
end

-- Wrapped text at a height in the window; returns the height below it.
local function paragraph(text, y, colour, font)
    local wrapped, lines = widgets.wrap(text, CHARS)
    local t = widgets.text(box, wrapped, colour, font or widgets.SMALL_FONT)
    t:SetPos(PAD, y)
    t:SetSize(-2 * PAD, math.max(1, lines) * 16 + 4, 1.0, 0)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.TOPLEFT)
    return y + math.max(1, lines) * 16 + 4
end

-- A section heading with a little space above it; returns the height below it.
local function heading(text, y)
    local t = widgets.text(box, text, widgets.GOLD, widgets.BOLD_FONT)
    t:SetPos(PAD, y + 8)
    t:SetSize(-2 * PAD, LINE, 1.0, 0)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return y + 8 + LINE
end

-- How many lines a text takes when wrapped.
local function linesOf(text)
    local _, lines = widgets.wrap(text or "", CHARS)
    return math.max(1, lines)
end

-- Builds the window's contents for a relic power. The window is sized to fit them.
local function build(relic)
    local height = widgets.HEADER_HEIGHT + 6 + 84 + linesOf(relic.effect) * 16 + 4
        + (LINE + 8) + 2 * LINE + (LINE + 8) + 52 + PAD
    box = widgets.window("relicPower", relic.name or "Relic power", WIDTH, height, detail.close).box
    lastState = nil

    -- The large icon (greyed out if locked), then the effect.
    local y = widgets.HEADER_HEIGHT + 6
    local isUnlocked = progress.relicUnlocked(relic.key)
    local icon = ui.Sprite.new(box)
    icon.sprite = relic.bigIcon or relic.icon
    icon:SetPos(WIDTH // 2 - 39, y)
    icon:SetSize(78, 78)
    if not isUnlocked then icon.colour = Vector4.new(0.3, 0.3, 0.3, 0.7) end
    y = y + 84
    y = paragraph(relic.effect or "", y, widgets.WHITE)

    -- Unlocked or not, and which loadouts use it.
    y = heading("Your progress", y)
    local t = widgets.text(box, isUnlocked and "Unlocked" or "Locked", isUnlocked and widgets.ENOUGH or widgets.SHORT, widgets.SMALL_FONT)
    t:SetPos(PAD, y)
    t:SetSize(-2 * PAD, LINE, 1.0, 0)
    y = y + LINE
    local loadouts, inActive = inLoadouts(relic)
    local where = loadouts == "" and "Not in any loadout"
        or ("In loadout " .. loadouts .. (inActive and " (including your active one)" or ""))
    t = widgets.text(box, where, widgets.DIM, widgets.SMALL_FONT)
    t:SetPos(PAD, y)
    t:SetSize(-2 * PAD, LINE, 1.0, 0)
    y = y + LINE

    -- The relic that unlocks it: a button opening the relic's window (its recipe and how to get it).
    y = heading("Relic", y)
    if relic.itemId then
        local row = ui.Layer.new(box)
        row:SetPos(PAD, y)
        row:SetSize(-2 * PAD, 48, 1.0, 0)
        local button = widgets.button(row, "", function() require("windows/relic_detail").open(relic) end)
        button:SetSize(0, 0, 1.0, 1.0)
        local item = ui.Sprite.new(row)
        item:SetAssociatedObject(relic.itemId)
        item:SetPos(6, 4)
        item:SetSize(44, 40)
        item.clickthrough = true
        local name = widgets.text(row, relic.itemName or "?", widgets.NAME, widgets.SMALL_FONT)
        name:SetPos(58, 0)
        name:SetSize(-64, 48, 1.0, 0)
        name:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    end
end

-- Closes the window.
function detail.close()
    widgets.destroyWindow(box)
    box, shown = nil, nil
end

-- Opens the window for a relic (replacing whichever it was showing).
function detail.open(relic)
    detail.close()
    shown = relic
    build(relic)
    lastState = tostring(progress.relicUnlocked(relic.key)) .. "|" .. (inLoadouts(relic))
end

-- Whether the window is open, and for which relic.
function detail.showing()
    return shown
end

-- Every few ticks, rebuilds if the relic was unlocked or your loadouts changed.
function detail.start()
    Event.ServerLogic.Subscribe("trackerRelicPowerDetailRedraw", function()
        ticks = ticks + 1
        if shown and ticks % 5 == 0 then
            local now = tostring(progress.relicUnlocked(shown.key)) .. "|" .. (inLoadouts(shown))
            if now ~= lastState then detail.open(shown) end
        end
    end)
end

return detail
