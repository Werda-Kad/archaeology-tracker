-- The "Found at" table, shared by the artifact and material windows: one button per hotspot (or
-- material cache) showing its dig site, area and level and whether its location is known yet,
-- with a Track (or Stop) button. Clicking a hotspot opens its window. Long names are shortened to fit their column. More than four
-- hotspots scroll.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local tracking = require("tracking/tracking")

local hotspotTable = {}

local PAD = 10
local LINE = 20                    -- height of one line of text
local ROW = 42                     -- one hotspot's button: its details, then what's known about it
local VISIBLE = 4                  -- hotspots shown before the rest scroll
-- Columns: { heading, x position, width }, inside each button; the Track button is at the right.
local COLUMNS = { { "Hotspot", 6, 146 }, { "Dig site", 156, 98 }, { "Area", 258, 120 }, { "Level", 382, 40 } }

-- The hotspots with these keys, sorted by dig site then name, each with the text for its
-- columns: hotspot, dig site, area within the site (e.g. "Barracks"), level.
function hotspotTable.list(keys)
    local list = {}
    for _, key in ipairs(keys) do
        local hotspot = catalog.hotspots[key]
        local site = hotspot.site and catalog.sites[hotspot.site]
        table.insert(list, { key = key, cells = { hotspot.name or "?", site and site.name or "-", hotspot.area or "-",
            tostring(hotspot.level or "?") } })
    end
    table.sort(list, function(a, b)
        if a.cells[2] ~= b.cells[2] then return a.cells[2] < b.cells[2] end
        return a.cells[1] < b.cells[1]
    end)
    return list
end

-- A piece of text in one column, shortened to fit it.
local function cell(parent, text, column, y, colour)
    local t = widgets.text(parent, widgets.fit(text, column[3]), colour, widgets.SMALL_FONT)
    t:SetPos(column[2], y)
    t:SetSize(column[3], LINE)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
end

-- One hotspot's button, at height y in parent.
local function row(parent, hotspot, y)
    local layer = ui.Layer.new(parent)
    layer:SetPos(0, y)
    layer:SetSize(0, ROW - 2, 1.0, 0)
    local background = widgets.button(layer, "", function()   -- opens the hotspot's window
        require("windows/hotspot_detail").open(catalog.hotspots[hotspot.key])
    end)
    background:SetSize(0, 0, 1.0, 1.0)
    for i, column in ipairs(COLUMNS) do cell(layer, hotspot.cells[i], column, 1, widgets.WHITE) end
    local spots = tracking.spotsKnown(hotspot.key)
    local status = spots > 0 and ("Location known (" .. spots .. (spots == 1 and " spot)" or " spots)"))
        or "Not seen yet: visit it once in order to track it"
    local note = widgets.text(layer, status, spots > 0 and widgets.ENOUGH or widgets.DIM, widgets.SMALL_FONT)
    note:SetPos(18, LINE - 2)
    note:SetSize(-110, LINE, 1.0, 0)
    note:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    local isTracked = tracking.target() == hotspot.key
    local button = widgets.button(layer, isTracked and "Stop" or "Track", function()
        tracking.track(not isTracked and hotspot.key or nil)
    end)
    button:SetPos(-84, 8, 1.0, 0)
    button:SetSize(76, 24)
    button.enabled = spots > 0 or isTracked
end

-- How tall the table is for this many hotspots: headings plus up to four rows (or a line saying there are none).
function hotspotTable.height(count)
    return count == 0 and LINE or LINE + math.min(count, VISIBLE) * ROW
end

-- Draws the table at height y in the window (win, parent, `width` wide), saying `none` if there
-- are no hotspots. Returns the height below it, and the scrolling section (remove it on close), if any.
function hotspotTable.build(win, parent, width, list, y, none)
    if #list == 0 then
        local t = widgets.text(parent, none, widgets.DIM, widgets.SMALL_FONT)
        t:SetPos(PAD, y)
        t:SetSize(-2 * PAD, LINE, 1.0, 0)
        t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        return y + LINE, nil
    end
    for _, column in ipairs(COLUMNS) do
        cell(parent, column[1], { column[1], PAD + column[2], column[3] }, y, widgets.NAME)
    end
    y = y + LINE
    local shown = math.min(#list, VISIBLE)
    local area = widgets.scrollArea(win, parent, PAD, y, width - 2 * PAD, shown * ROW, #list * ROW, ROW)
    for i, hotspot in ipairs(list) do row(area.content, hotspot, (i - 1) * ROW) end
    return y + shown * ROW, area
end

return hotspotTable
