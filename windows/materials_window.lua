-- The Materials window: a grid of every material used to restore artifacts, showing how many
-- you have, with search, filter and sort controls at the top, like the Artifacts window.
-- Each square: a name header, the icon (darkened if you have none), and your total below it.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local progress = require("core/progress")
local log = require("core/log")

local window = {}

local COLUMNS, ROWS = 6, 4
local CELL_W, CELL_H, SPACING = 84, 104, 4
local TOP = widgets.HEADER_HEIGHT + 8   -- controls row, just under the window header
local LIST_TOP = TOP + 34                -- the darker area holding the grid and scrollbar
local GRID_WIDTH = COLUMNS * (CELL_W + SPACING)
local ROW_HEIGHT = CELL_H + SPACING
local GRID_HEIGHT = ROWS * ROW_HEIGHT    -- the visible part of the list
local WHEEL_STEP = 38                    -- how far one notch of the mouse wheel scrolls
local LIST_WIDTH = GRID_WIDTH + widgets.SCROLLBAR_WIDTH + 12
local WINDOW_WIDTH = LIST_WIDTH + 16
local FILTER_ICON = 24449                -- the funnel, as in the Artifacts window
local FILTER_COLUMN = 200   -- filter panel column width

local win, box, filterPanel, pageText, scrollbar, view = nil, nil, nil, nil, nil, nil
local cells = {}      -- the squares, reused as you scroll
local scrolled = 0    -- how far down the list is scrolled, in interface units
local list = {}       -- materials that pass the search and filter, in display order
local dirty = false   -- counts changed; redraw on the next tick

-- What the controls are set to. Kept while the window is closed.
local search, sort = "", 1
-- Filter boxes the user has unticked. Ordinary items used in a few recipes start hidden.
local unticked = { other = true }

-- Sort choices, in dropdown order.
local SORTS = { "Level required", "Number owned" }
-- Filter boxes. Unticking a box hides every material that matches it. Dig sites are added
-- when the panel is built.
local FILTER_GROUPS = {
    { title = "Level", boxes = { { key = "locked", label = "Show locked" } } },
    { title = "Kind", boxes = {
        { key = "archaeology", label = "Archaeology materials" },
        { key = "other", label = "Other ingredients" } } },
    { title = "Owned", boxes = {
        { key = "owned", label = "Owned" },
        { key = "notOwned", label = "Not owned" } } },
}

-- How many of a material you have, across all storages.
local function owned(material)
    return storage.count(material.itemId).total
end

-- The dig sites a material is dug up at (through its hotspots and caches).
function window.sitesOf(material)
    local sites, seen = {}, {}
    for _, key in ipairs(material.hotspots or {}) do
        local site = catalog.hotspots[key] and catalog.hotspots[key].site
        if site and not seen[site] then
            seen[site] = true
            table.insert(sites, site)
        end
    end
    return sites
end

-- Fuzzy search: the letters typed appear in the name in the same order.
local function matchesSearch(material)
    local name, at = string.lower(material.name or ""), 1
    for letter in string.lower(search):gmatch("%S") do
        at = string.find(name, letter, at, true)
        if not at then return false end
        at = at + 1
    end
    return true
end

-- Whether a material passes every filter: it matches none of the unticked boxes, and (if it's
-- dug up anywhere) at least one of its dig sites is ticked.
local function matchesFilter(material)
    local count = owned(material)
    local m = { locked = (material.level or 0) > (progress.level() or 0),
        archaeology = material.isArchaeologyMaterial, other = not material.isArchaeologyMaterial,
        owned = count > 0, notOwned = count == 0 }
    for _, group in ipairs(FILTER_GROUPS) do
        for _, b in ipairs(group.boxes) do
            if m[b.key] and unticked[b.key] then return false end
        end
    end
    local sites = window.sitesOf(material)
    if #sites == 0 then return true end
    for _, site in ipairs(sites) do
        if not unticked["site:" .. site] then return true end
    end
    return false
end

-- The materials to show: those passing search and filter, in the chosen order.
local function buildList()
    list = {}
    for _, material in pairs(catalog.materials) do
        if matchesSearch(material) and matchesFilter(material) then table.insert(list, material) end
    end
    table.sort(list, function(a, b)
        if sort == 2 and owned(a) ~= owned(b) then return owned(a) > owned(b) end
        -- Lowest level first, then by name; also breaks ties for the other sort.
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
        return (a.name or "") < (b.name or "")
    end)
end

-- Builds one empty square; fillCell puts a material in it.
local function makeCell(grid)
    local cell = {}
    cell.layer = ui.Layer.new(grid)
    cell.layer:SetSize(0, 0, 1.0, 1.0)
    cell.button = widgets.button(cell.layer, "", function()
        if cell.material then require("windows/material_detail").open(cell.material) end
    end)
    cell.button:SetSize(0, 0, 1.0, 1.0)
    -- Name header: the game's tab-header style, with our own two-line text on top.
    local header = ui.Button.new(cell.layer)
    header.stylesheetID = id.StyleSheet.TAB_HEADER_24PX
    header:SetPos(2, 2)
    header:SetSize(-4, 34, 1.0, 0)
    header.clickthrough = true
    cell.name = widgets.text(cell.layer, "", widgets.NAME, widgets.SMALL_FONT)
    cell.name:SetPos(3, 3)
    cell.name:SetSize(-6, 32, 1.0, 0)
    cell.name.maxLines = 2
    cell.name:AlignTo(ui.AlignMode.CENTRE)
    cell.icon = ui.Sprite.new(cell.layer)
    cell.icon:SetPos(CELL_W // 2 - 22, 38)
    cell.icon:SetSize(44, 38)
    cell.icon.clickthrough = true
    local bar = widgets.box(cell.layer, widgets.PANEL)
    bar:SetPos(3, -25, 0, 1.0)
    bar:SetSize(-6, 22, 1.0, 0)
    cell.total = widgets.text(cell.layer, "", widgets.GOLD, widgets.BOLD_FONT)
    cell.total:SetPos(3, -25, 0, 1.0)
    cell.total:SetSize(-6, 22, 1.0, 0)
    cell.total:AlignTo(ui.AlignMode.CENTRE)
    return cell
end

-- Shows a material in a square, or hides the square if there's none.
local function fillCell(cell, material)
    cell.material = material
    cell.layer.hidden = material == nil
    if not material then return end
    local count = owned(material)
    cell.name.content = (widgets.wrap(material.name or "?", 11))
    cell.icon:SetAssociatedObject(material.itemId)
    -- Darkened if you have none.
    cell.icon.colour = count > 0 and Vector4.new(1.0, 1.0, 1.0, 1.0) or Vector4.new(0.25, 0.25, 0.25, 0.6)
    cell.total.content = tostring(count)
    cell.total.colour = count > 0 and widgets.GOLD or widgets.DIM
end

-- How far the list can scroll before the last row reaches the bottom.
local function maxScroll()
    return math.max(0, math.ceil(#list / COLUMNS) * ROW_HEIGHT - GRID_HEIGHT)
end

-- Refills the squares for the scroll position, and the "Showing" line (smooth scrolling as in
-- the Artifacts window: one spare row, and the clipping layer slid by the part of a row scrolled past).
local function redraw()
    if not box then return end
    scrolled = math.max(0, math.min(scrolled, maxScroll()))
    local topRow = scrolled // ROW_HEIGHT
    local first = topRow * COLUMNS + 1
    for i, cell in ipairs(cells) do fillCell(cell, list[first + i - 1]) end
    view:SetScrollPos(0, scrolled - topRow * ROW_HEIGHT)
    local lastVisible = math.min(math.ceil((scrolled + GRID_HEIGHT) / ROW_HEIGHT) * COLUMNS, #list)
    pageText.content = #list == 0 and "No materials match"
        or ("Showing " .. first .. "-" .. lastVisible .. " of " .. #list .. " materials")
    local total = math.ceil(#list / COLUMNS) * ROW_HEIGHT
    scrollbar:show(maxScroll() > 0 and scrolled / maxScroll() or 0, total > 0 and GRID_HEIGHT / total or 1)
    dirty = false
end

-- Scrolls by a distance in interface units (negative = up).
local function scrollBy(distance)
    scrolled = scrolled + distance
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
    local filterButton = widgets.iconButton(box, FILTER_ICON, function()
        filterPanel.hidden = not filterPanel.hidden
        if not filterPanel.hidden then filterPanel:MoveToFront() end
    end)
    filterButton:SetPos(WINDOW_WIDTH - 216, TOP)
    filterButton:SetSize(26, 26)
    local sortBox = ui.ComboField.new(box)
    sortBox.stylesheetID = id.StyleSheet.DROPDOWN_DEFAULT
    sortBox:SetPos(WINDOW_WIDTH - 184, TOP)
    sortBox:SetSize(176, 26)
    for i, label in ipairs(SORTS) do sortBox:Add(label, i) end
    -- Show the current sort; if the dropdown won't, sort by what it does show, so they agree.
    local shown = widgets.choose(sortBox, sort)
    if shown and shown > 0 and shown ~= sort then sort = shown end
    sortBox:Subscribe(ui.Hook.ONSELECTIONCHANGED, function()
        if sortBox.selectedID and sortBox.selectedID > 0 and sortBox.selectedID ~= sort then
            sort = sortBox.selectedID
            log.say("Materials sort: " .. tostring(SORTS[sort]))
            refilter()
        end
    end)
end

-- The panel of filter boxes under the Filter button, in two columns: dig sites (indented under
-- their heading) on the left, the other boxes on the right. Each heading ticks or unticks the
-- boxes under it. Hidden until the button is pressed.
local function buildFilterPanel()
    local sites = {}
    for _, site in pairs(catalog.sites) do table.insert(sites, site) end
    table.sort(sites, function(a, b) return (a.name or "") < (b.name or "") end)
    local left = { { header = "Dig site" } }
    for _, site in ipairs(sites) do table.insert(left, { key = "site:" .. site.key, label = site.name or "?", indent = true }) end
    local right = {}
    for _, group in ipairs(FILTER_GROUPS) do
        table.insert(right, { header = group.title })
        for _, b in ipairs(group.boxes) do table.insert(right, { key = b.key, label = b.label, indent = true }) end
    end
    filterPanel = widgets.filterPanel(box, WINDOW_WIDTH - 2 * FILTER_COLUMN - 16, TOP + 28, FILTER_COLUMN, { left, right },
        unticked, refilter)
end

-- Closes the window (the search, filter and sort are remembered).
function window.close()
    if scrollbar then scrollbar:remove() end
    widgets.destroyWindow(box)
    win, box, cells, filterPanel, scrollbar, view, pageText = nil, nil, {}, nil, nil, nil, nil
end

-- Opens the window, or does nothing if it's already open.
function window.open()
    if box then return end
    win = widgets.window("materials", "Materials", WINDOW_WIDTH, LIST_TOP + GRID_HEIGHT + 44, window.close)
    box = win.box
    buildControls()
    -- The list area: the game's darker content background, with the grid and scrollbar on it.
    local background = ui.Sprite.new(box)
    background.sprite = 18035  -- RS3_CHILD_CONTENT_TILE
    background.isTiling = true
    background:SetPos(8, LIST_TOP)
    background:SetSize(LIST_WIDTH, GRID_HEIGHT + 8)
    -- The squares sit in a grid inside a clipping layer, with one spare row (as in the Artifacts window).
    view = ui.Layer.new(box)
    view:SetPos(12, LIST_TOP + 4)
    view:SetSize(GRID_WIDTH, GRID_HEIGHT)
    view:SetScrollSize(GRID_WIDTH, GRID_HEIGHT + ROW_HEIGHT)
    local grid = ui.Grid.new(view)
    grid:SetSize(GRID_WIDTH, GRID_HEIGHT + ROW_HEIGHT)
    grid.spacing = SPACING
    grid:SetColumnRows(COLUMNS, ROWS + 1)
    for i = 1, COLUMNS * (ROWS + 1) do cells[i] = makeCell(grid) end
    scrollbar = widgets.scrollbar(win, box, 16 + GRID_WIDTH, LIST_TOP + 4, GRID_HEIGHT,
        function(step) scrollBy(step * WHEEL_STEP) end,
        function(at) scrolled = math.floor(at * maxScroll() + 0.5); redraw() end,
        function(page) scrollBy(page * GRID_HEIGHT) end)
    view:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta) scrollBy((delta or 0) * WHEEL_STEP) end)
    pageText = widgets.text(box, "", widgets.DIM, widgets.SMALL_FONT)
    pageText:SetPos(8, LIST_TOP + GRID_HEIGHT + 16)
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
    Event.ServerLogic.Subscribe("trackerMaterialsRedraw", function()
        if dirty and box then
            buildList()
            redraw()
        end
        dirty = false
    end)
end

return window
