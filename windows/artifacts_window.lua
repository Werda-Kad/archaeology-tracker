-- The Artifacts window: a grid of every artifact showing how many you own, with search,
-- filter and sort controls at the top.
-- Each square: a name header, a line showing the value being sorted by (e.g. "lvl 3"), the icon,
-- a total badge (gold), and a bar with damaged (grey) + restored (white).

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local progress = require("core/progress")
local log = require("core/log")
local detail = require("windows/artifact_detail")
local chronotes = require("core/chronotes")

local window = {}

local COLUMNS, ROWS = 6, 4
local CELL_W, CELL_H, SPACING = 84, 124, 4
local CHRONOTE_ICON = 10315              -- ARCH_ICON_CHRONOTES_16PX
local TOP = widgets.HEADER_HEIGHT + 8   -- controls row, just under the window header
local LIST_TOP = TOP + 34                -- the darker area holding the grid and scrollbar
local GRID_WIDTH = COLUMNS * (CELL_W + SPACING)
local ROW_HEIGHT = CELL_H + SPACING
local GRID_HEIGHT = ROWS * ROW_HEIGHT    -- the visible part of the list
local WHEEL_STEP = 38                    -- how far one notch of the mouse wheel scrolls
local LIST_WIDTH = GRID_WIDTH + widgets.SCROLLBAR_WIDTH + 12
local WINDOW_WIDTH = LIST_WIDTH + 16
local FILTER_ICON = 24449  -- RS3_ICON_FILTER_3: the funnel closest to the quest list's (picked from the round 9 probe)

local win = nil       -- the window (position etc.), while it's open
local box = nil       -- the window's frame, while it's open
local filterPanel = nil  -- the panel of filter boxes, shown by the Filter button
local cells = {}      -- the 24 squares, reused as you scroll
local pageText = nil
local scrollbar = nil
local scrolled = 0    -- how far down the list is scrolled, in interface units
local view = nil      -- the clipping layer the squares slide around in
local list = {}       -- artifacts that pass the search and filter, in display order
local dirty = false   -- counts changed; redraw on the next tick

-- What the controls are set to. Kept while the window is closed.
local search, sort = "", 1
-- Filter boxes the user has unticked. Misc and event artifacts can't be dug up, so they start hidden.
local unticked = { misc = true, event = true }

-- Sort choices, in dropdown order. Chronotes: the most any of its collections gives (learned as you play).
local SORTS = { "Level", "Dig site", "Number owned", "Chronotes earned", "XP gained" }

-- Filter boxes. Unticking a box hides every artifact that matches it, whatever else is ticked.
-- Dig sites are added when the panel is built.
local FILTER_GROUPS = {
    { title = "Collections", boxes = {
        { key = "needed", label = "Needed for a collection" },
        { key = "inCollection", label = "Already in a collection" },
        { key = "complete", label = "Complete collections" } } },
    { title = "Level", boxes = { { key = "locked", label = "Show locked" } } },
    { title = "Kind", boxes = {
        { key = "misc", label = "Misc (mysteries, quests)" },
        { key = "event", label = "Event (e.g. Halloween)" },
        { key = "tetracompass", label = "Tetracompass and pieces" } } },
    { title = "Owned", boxes = {
        { key = "damaged", label = "Damaged" },
        { key = "restored", label = "Restored" },
        { key = "owned", label = "Owned" },
        { key = "notOwned", label = "Not owned" } } },
}

-- How many damaged and restored copies of an artifact you own.
local function counts(artifact)
    return storage.count(artifact.damagedId).total, storage.count(artifact.restoredId).total
end

-- Fuzzy search: the letters typed appear in the name in the same order ("lgl" finds "Legionary gladius").
local function matchesSearch(artifact)
    local name, at = string.lower(artifact.name), 1
    for letter in string.lower(search):gmatch("%S") do
        at = string.find(name, letter, at, true)
        if not at then return false end
        at = at + 1
    end
    return true
end

-- A catalog group (dig sites or cultures) as a list sorted by name, for the filter panel.
local function byName(group)
    local items = {}
    for _, item in pairs(group) do table.insert(items, item) end
    table.sort(items, function(a, b) return (a.name or "") < (b.name or "") end)
    return items
end

-- Whether a filter box is ticked.
local function ticked(key)
    return not unticked[key]
end

-- Which groups' boxes an artifact matches, e.g. { needed = true, damaged = true, owned = true }.
local function filterMatches(artifact)
    local m = {}
    local damaged, restored = counts(artifact)
    m.damaged, m.restored = damaged > 0, restored > 0
    m.owned, m.notOwned = damaged + restored > 0, damaged + restored == 0
    local allComplete = #artifact.collections > 0
    for _, collection in ipairs(artifact.collections) do
        if progress.collectionHas(collection, artifact.key) then m.inCollection = true else m.needed = true end
        if not progress.collectionEverCompleted(collection) then allComplete = false end
    end
    m.complete = allComplete
    m.misc, m.event, m.tetracompass = artifact.kind == "misc", artifact.kind == "event", artifact.kind == "tetracompass"
    return m
end

-- Whether an artifact passes every filter: it matches none of the unticked boxes.
local function matchesFilter(artifact)
    local m = filterMatches(artifact)
    m.locked = (artifact.level or 0) > (progress.level() or 0)
    for _, group in ipairs(FILTER_GROUPS) do
        for _, b in ipairs(group.boxes) do
            if m[b.key] and not ticked(b.key) then return false end
        end
    end
    -- Dig sites and cultures: an artifact with several hides only when all of them are unticked.
    local function anyTicked(keys, prefix)
        if #keys == 0 then return true end
        for _, key in ipairs(keys) do
            if ticked(prefix .. key) then return true end
        end
        return false
    end
    return anyTicked(artifact.sites, "site:") and anyTicked(artifact.cultures, "culture:")
end

-- The first dig site's name, for sorting by site.
local function siteName(artifact)
    local key = artifact.sites[1]
    return key and catalog.sites[key] and catalog.sites[key].name or "~"  -- "~" sorts artifacts with no site last
end

-- The artifacts to show: those passing search and filter, in the chosen order.
local function buildList()
    list = {}
    for _, artifact in pairs(catalog.artifacts) do
        if matchesSearch(artifact) and matchesFilter(artifact) then table.insert(list, artifact) end
    end
    -- Lowest level first, then by name; also breaks ties for the other sorts.
    local function byLevel(a, b)
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
        return a.name < b.name
    end
    table.sort(list, function(a, b)
        if sort == 2 and siteName(a) ~= siteName(b) then return siteName(a) < siteName(b) end
        if sort == 3 then
            local ad, ar = counts(a)
            local bd, br = counts(b)
            if ad + ar ~= bd + br then return ad + ar > bd + br end
        end
        if sort == 5 and (a.xp or 0) ~= (b.xp or 0) then return (a.xp or 0) > (b.xp or 0) end   -- most XP first
        if sort == 4 then
            -- Most chronotes first; ones not seen yet go last.
            local ca, cb = chronotes.bestForArtifact(a.key) or -1, chronotes.bestForArtifact(b.key) or -1
            if ca ~= cb then return ca > cb end
        end
        return byLevel(a, b)
    end)
end

-- Game text doesn't wrap by itself, so long names are split over two lines at a space
-- ("<br>" is the game's line break). About 11 characters fit on a line in a square.
local LINE_CHARS = 11
-- Splits a name into at most two short lines.
local function wrapName(name)
    if #name <= LINE_CHARS then return name end
    local first, second = "", ""
    for word in name:gmatch("%S+") do
        if second == "" and (first == "" or #first + 1 + #word <= LINE_CHARS) then
            first = first == "" and word or (first .. " " .. word)
        else
            second = second == "" and word or (second .. " " .. word)
        end
    end
    -- One very long word: cut it in two.
    if #first > LINE_CHARS then
        second = first:sub(LINE_CHARS + 1) .. (second ~= "" and (" " .. second) or "")
        first = first:sub(1, LINE_CHARS)
    end
    if #second > LINE_CHARS then second = second:sub(1, LINE_CHARS - 2) .. ".." end
    return second == "" and first or (first .. "<br>" .. second)
end

-- Icon look: faint if you have none, dark if only damaged, full colour once restored.
local function iconColour(damaged, restored)
    if restored > 0 then return Vector4.new(1.0, 1.0, 1.0, 1.0) end
    if damaged > 0 then return Vector4.new(0.25, 0.25, 0.25, 1.0) end
    return Vector4.new(0.25, 0.25, 0.25, 0.35)
end

-- Builds one empty square; fillCell puts an artifact in it.
local function makeCell(grid)
    local cell = {}
    cell.layer = ui.Layer.new(grid)
    cell.layer:SetSize(0, 0, 1.0, 1.0)
    cell.button = widgets.button(cell.layer, "", function()
        if cell.artifact then detail.open(cell.artifact) end
    end)
    cell.button:SetSize(0, 0, 1.0, 1.0)
    -- Name header: the game's tab-header style as the background, with our own text on top.
    -- The header's built-in label only fits one short line, so it's left empty.
    local header = ui.Button.new(cell.layer)
    header.stylesheetID = id.StyleSheet.TAB_HEADER_24PX
    header:SetPos(2, 2)
    header:SetSize(-4, 34, 1.0, 0)
    header.clickthrough = true  -- lets clicks through to the square's button
    cell.name = widgets.text(cell.layer, "", widgets.NAME, widgets.SMALL_FONT)
    cell.name:SetPos(3, 3)
    cell.name:SetSize(-6, 32, 1.0, 0)
    cell.name.maxLines = 2
    cell.name:AlignTo(ui.AlignMode.CENTRE)
    -- The value being sorted by, just under the header (with the chronote icon when sorting by chronotes).
    cell.sortValue = widgets.text(cell.layer, "", widgets.DIM, widgets.SMALL_FONT)
    cell.sortValue:SetPos(3, 37)
    cell.sortValue:SetSize(-6, 16, 1.0, 0)
    cell.sortValue:AlignTo(ui.AlignMode.CENTRE)
    cell.coin = ui.Sprite.new(cell.layer)
    cell.coin.sprite = CHRONOTE_ICON
    cell.coin:SetPos(CELL_W // 2 - 26, 37)
    cell.coin:SetSize(14, 14)
    cell.coin.clickthrough = true
    cell.coin.hidden = true
    cell.icon = ui.Sprite.new(cell.layer)
    cell.icon:SetPos(6, 52)
    cell.icon:SetSize(46, 44)
    cell.icon.clickthrough = true
    -- Total in its own badge to the right of the icon.
    local badge = widgets.box(cell.layer, widgets.PANEL)
    badge:SetPos(-32, 60, 1.0, 0)
    badge:SetSize(28, 26)
    cell.total = widgets.text(cell.layer, "", widgets.GOLD, widgets.BOLD_FONT)
    cell.total:SetPos(-32, 60, 1.0, 0)
    cell.total:SetSize(28, 26)
    cell.total:AlignTo(ui.AlignMode.CENTRE)
    -- Bottom bar: "damaged + restored", each number in its own colour.
    local bar = widgets.box(cell.layer, widgets.PANEL)
    bar:SetPos(3, -25, 0, 1.0)
    bar:SetSize(-6, 22, 1.0, 0)
    cell.damaged = widgets.text(cell.layer, "", widgets.DIM, widgets.SMALL_FONT)
    cell.damaged:SetPos(0, -25, 0, 1.0)
    cell.damaged:SetSize(-12, 22, 0.5, 0)
    cell.damaged:AlignTo(ui.AlignMode.BOTTOMRIGHT, ui.AlignMode.CENTRE)
    local plus = widgets.text(cell.layer, "+", widgets.DIM, widgets.SMALL_FONT)
    plus:SetPos(-6, -25, 0.5, 1.0)
    plus:SetSize(12, 22)
    plus:AlignTo(ui.AlignMode.CENTRE)
    cell.restored = widgets.text(cell.layer, "", widgets.WHITE, widgets.SMALL_FONT)
    cell.restored:SetPos(12, -25, 0.5, 1.0)
    cell.restored:SetSize(-12, 22, 0.5, 0)
    cell.restored:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return cell
end

-- The line under a square's name for the chosen sort: "lvl 3", the dig site, chronotes, "480 XP",
-- or nothing for number owned (the square already shows it). Also whether to show the chronote icon.
local function sortValueText(artifact)
    if sort == 1 then return "lvl " .. tostring(artifact.level or "?"), false end
    if sort == 2 then return widgets.fit(siteName(artifact) == "~" and "No dig site" or siteName(artifact), CELL_W - 8), false end
    if sort == 4 then
        local n = chronotes.bestForArtifact(artifact.key)
        return n and widgets.withCommas(n) or "?", true
    end
    if sort == 5 then return artifact.xp and ((string.format("%.1f", artifact.xp):gsub("%.0$", "")) .. " XP") or "", false end
    return "", false
end

-- Shows an artifact in a square, or hides the square if there's none.
local function fillCell(cell, artifact)
    cell.artifact = artifact
    cell.layer.hidden = artifact == nil
    if not artifact then return end
    local damaged, restored = counts(artifact)
    cell.name.content = wrapName(artifact.name)
    local value, withCoin = sortValueText(artifact)
    cell.sortValue.content = value
    cell.coin.hidden = not withCoin
    cell.icon:SetAssociatedObject(artifact.restoredId)
    cell.icon.colour = iconColour(damaged, restored)
    cell.total.content = tostring(damaged + restored)
    cell.damaged.content = tostring(damaged)
    cell.restored.content = tostring(restored)
end

-- How far the list can scroll before the last row reaches the bottom.
local function maxScroll()
    return math.max(0, math.ceil(#list / COLUMNS) * ROW_HEIGHT - GRID_HEIGHT)
end

-- Refills the squares for the current scroll position, and the "Showing" line.
-- Smooth scrolling: one extra row of squares is kept below the visible ones, the squares
-- show the rows from the top visible one down, and the clipping layer is slid by the part
-- of a row that's scrolled past.
local function redraw()
    if not box then return end
    scrolled = math.max(0, math.min(scrolled, maxScroll()))
    local topRow = scrolled // ROW_HEIGHT
    local first = topRow * COLUMNS + 1
    for i, cell in ipairs(cells) do fillCell(cell, list[first + i - 1]) end
    view:SetScrollPos(0, scrolled - topRow * ROW_HEIGHT)
    local lastVisible = math.min(math.ceil((scrolled + GRID_HEIGHT) / ROW_HEIGHT) * COLUMNS, #list)
    pageText.content = #list == 0 and "No artifacts match"
        or ("Showing " .. first .. "-" .. lastVisible .. " of " .. #list .. " artifacts")
    -- Scrollbar: how far down the list is, and how much of it fits.
    local total = math.ceil(#list / COLUMNS) * ROW_HEIGHT
    scrollbar:show(maxScroll() > 0 and scrolled / maxScroll() or 0, total > 0 and GRID_HEIGHT / total or 1)
    dirty = false
end

-- Scrolls by a distance in interface units (negative = up), staying within the list.
local function scrollBy(distance)
    scrolled = scrolled + distance
    redraw()
end

-- Jumps to a point in the list (0 = top, 1 = bottom), from dragging the scrollbar.
local function scrollTo(at)
    scrolled = math.floor(at * maxScroll() + 0.5)
    redraw()
end

-- After the search, filter or sort changes: rebuild the list and go back to the start.
local function refilter()
    buildList()
    scrolled = 0
    redraw()
end

-- The search box, Filter button and Sort dropdown at the top.
local function buildControls()
    local searchBox = ui.InputField.new(box)
    searchBox.stylesheetID = id.StyleSheet.INPUT_DEFAULT
    searchBox:SetPos(8, TOP)
    searchBox:SetSize(WINDOW_WIDTH - 230, 26)
    searchBox.emptyText = "Search..."
    searchBox:Subscribe(ui.Hook.ONCONTENTCHANGED, function(_, _, text)
        search = text or ""
        refilter()
    end)

    -- The Filter button opens and closes the panel of filter boxes (built in buildFilterPanel).
    local filterButton = widgets.iconButton(box, FILTER_ICON, function()
        filterPanel.hidden = not filterPanel.hidden
        if not filterPanel.hidden then filterPanel:MoveToFront() end
    end)
    filterButton:SetPos(WINDOW_WIDTH - 216, TOP)
    filterButton:SetSize(26, 26)

    local sortBox = ui.ComboField.new(box)
    sortBox.stylesheetID = id.StyleSheet.COMBO_DEFAULT
    sortBox:SetPos(WINDOW_WIDTH - 184, TOP)
    sortBox:SetSize(176, 26)
    for i, label in ipairs(SORTS) do sortBox:Add(label, i) end
    -- Show the current sort; if the dropdown won't, sort by what it does show, so they agree.
    local shown = widgets.choose(sortBox, sort)
    if shown and shown > 0 and shown ~= sort then sort = shown end
    -- Read the dropdown's own choice: the event's values may be numbers rather than names.
    sortBox:Subscribe(ui.Hook.ONSELECTIONCHANGED, function()
        if sortBox.selectedID and sortBox.selectedID > 0 and sortBox.selectedID ~= sort then
            sort = sortBox.selectedID
            log.say("Sort: " .. tostring(SORTS[sort]))
            refilter()
        end
    end)
end

local COLUMN_WIDTH = 200 -- the panel has two columns

-- The panel of filter boxes under the Filter button, in two columns: dig sites and cultures
-- (indented under their headings, which tick or untick them all) on the left, the other boxes on
-- the right in the design doc's order. Hidden until the button is pressed. Built after the grid
-- so it draws on top.
local function buildFilterPanel()
    local left = { { header = "Dig site" } }
    for _, site in ipairs(byName(catalog.sites)) do
        table.insert(left, { key = "site:" .. site.key, label = site.name or "?", indent = true })
    end
    table.insert(left, { header = "Culture" })
    for _, culture in ipairs(byName(catalog.cultures)) do
        table.insert(left, { key = "culture:" .. culture.key, label = culture.name, indent = true })
    end
    local right = {}
    for _, group in ipairs(FILTER_GROUPS) do
        for _, b in ipairs(group.boxes) do table.insert(right, b) end
    end
    filterPanel = widgets.filterPanel(box, WINDOW_WIDTH - 2 * COLUMN_WIDTH - 16, TOP + 28, COLUMN_WIDTH, { left, right },
        unticked, refilter)
end

-- Legend under the grid, in the same colours as the numbers.
local function buildLegend(y)
    -- { word, colour, width, gap after }
    local parts = { { "Total", widgets.GOLD, 40, 16 }, { "Damaged", widgets.DIM, 64, 0 },
        { "+", widgets.DIM, 12, 0 }, { "Restored", widgets.WHITE, 66, 0 } }
    local x = -99  -- half the legend's width, so it sits centred
    for _, part in ipairs(parts) do
        -- "Total" gets the same dark badge as the totals in the squares.
        if part[1] == "Total" then
            local badge = widgets.box(box, widgets.PANEL)
            badge:SetPos(x, y, 0.5, 0)
            badge:SetSize(part[3], 20)
        end
        local t = widgets.text(box, part[1], part[2], widgets.SMALL_FONT)
        t:SetPos(x, y, 0.5, 0)
        t:SetSize(part[3], 20)
        t:AlignTo(ui.AlignMode.CENTRE)
        x = x + part[3] + part[4]
    end
end

-- Closes the window (the search, filter and sort are remembered).
function window.close()
    if scrollbar then scrollbar:remove() end
    widgets.destroyWindow(box)
    win, box, cells, filterPanel, scrollbar, view = nil, nil, {}, nil, nil, nil
end

-- Opens the window, or does nothing if it's already open.
function window.open()
    if box then return end
    win = widgets.window("artifacts", "Artifacts", WINDOW_WIDTH, LIST_TOP + GRID_HEIGHT + 66, window.close)
    box = win.box
    buildControls()

    -- The list area: the game's darker content background, with the grid and scrollbar on it.
    local background = ui.Sprite.new(box)
    background.sprite = 18035  -- RS3_CHILD_CONTENT_TILE
    background.isTiling = true
    background:SetPos(8, LIST_TOP)
    background:SetSize(LIST_WIDTH, GRID_HEIGHT + 8)
    -- The squares sit in a grid inside a layer that cuts off anything outside the visible area
    -- (layers clip, grids don't). The grid has one spare row, for the row sliding into view.
    view = ui.Layer.new(box)
    view:SetPos(12, LIST_TOP + 4)
    view:SetSize(GRID_WIDTH, GRID_HEIGHT)
    view:SetScrollSize(GRID_WIDTH, GRID_HEIGHT + ROW_HEIGHT)
    local grid = ui.Grid.new(view)
    grid:SetSize(GRID_WIDTH, GRID_HEIGHT + ROW_HEIGHT)
    grid.spacing = SPACING
    grid:SetColumnRows(COLUMNS, ROWS + 1)  -- fixed 6 x 5, so all 30 squares always get a cell
    for i = 1, COLUMNS * (ROWS + 1) do cells[i] = makeCell(grid) end
    scrollbar = widgets.scrollbar(win, box, 16 + GRID_WIDTH, LIST_TOP + 4, GRID_HEIGHT,
        function(step) scrollBy(step * WHEEL_STEP) end, scrollTo, function(page) scrollBy(page * GRID_HEIGHT) end)
    -- The mouse wheel: only layers receive it (round 10 probe). Positive means down.
    view:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta) scrollBy((delta or 0) * WHEEL_STEP) end)

    buildLegend(LIST_TOP + GRID_HEIGHT + 14)
    pageText = widgets.text(box, "", widgets.DIM, widgets.SMALL_FONT)
    pageText:SetPos(8, LIST_TOP + GRID_HEIGHT + 36)
    pageText:SetSize(-16, 20, 1.0, 0)
    pageText:AlignTo(ui.AlignMode.CENTRE)
    buildFilterPanel()

    refilter()
end

-- Whether the window is open.
function window.isOpen()
    return box ~= nil
end

-- Redraws when counts change, at most once per server tick.
function window.start()
    storage.onUpdate(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerArtifactsRedraw", function()
        if dirty then redraw() end
    end)
end

return window
