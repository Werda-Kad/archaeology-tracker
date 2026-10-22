-- The Collections window: every museum collection in one list, laid out like the game's own
-- collection window: the name (with a ticked circle once ever completed, an empty one if not), the artifacts in sunken
-- slots (full colour once handed in, black shapes until then), then the chronote reward.
-- Search, filter and sort controls at the top, like the Artifacts window.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local progress = require("core/progress")
local chronotes = require("core/chronotes")
local log = require("core/log")

local window = {}

local WIDTH = 560
local TOP = widgets.HEADER_HEIGHT + 8    -- controls row, just under the window header
local LIST_TOP = TOP + 34                -- the darker area holding the list and scrollbar
local ROW_W = WIDTH - widgets.SCROLLBAR_WIDTH - 32
local SLOT, SLOT_STEP = 40, 42           -- artifact slot size, and the distance from one to the next
local PER_LINE = (ROW_W - 16) // SLOT_STEP   -- slots on one line (12)
local ROW_GAP = 4
local LIST_HEIGHT = 5 * 100              -- the visible part of the list
-- Rows are one size, tall enough for the biggest collection's slots (set when the window opens).
local lines, rowH, rowStep, visible, maxIcons = 1, 0, 0, 0, 0
local WHEEL_STEP = 38                    -- how far one notch of the mouse wheel scrolls
local FILTER_ICON = 24449                -- the funnel, as in the Artifacts window
local CHRONOTE_ICON = 10315              -- ARCH_ICON_CHRONOTES_16PX
local CHECK_EVERY = 5                    -- ticks between checks for hand-ins while open (3 s)

-- Sort choices, in dropdown order.
local SORTS = { "Level required", "Chronote reward", "Collector" }
-- Filter boxes. Unticking a box hides every collection that matches it.
local FILTERS = {
    { key = "completable", label = "Completable" },
    { key = "notCompletable", label = "Not completable yet" },
    { key = "neverCompleted", label = "Never completed" },
    { key = "completedBefore", label = "Completed before" },
}

local win, box, view, scrollbar, pageText, filterPanel = nil, nil, nil, nil, nil, nil
local rows = {}         -- the row displays, reused as you scroll
local list = {}         -- collections that pass the search and filter, in display order
local scrolled = 0      -- how far down the list is scrolled, in interface units
local dirty = false     -- something changed; rebuild on the next tick
local ticks = 0

-- What the controls are set to. Kept while the window is closed.
local search, sort = "", 1
local unticked = {}

-- "2635" as "2,635".
local function withCommas(n)
    local s = tostring(n)
    while true do
        local changed
        s, changed = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if changed == 0 then return s end
    end
end
window.withCommas = withCommas

-- Facts about a collection worked out from your progress and storages:
-- level (highest artifact level), handed (artifact -> true), completable, completed before.
function window.status(collection)
    local s = { level = 0, handed = {}, completable = true, everCompleted = progress.collectionEverCompleted(collection.key) }
    for _, key in ipairs(collection.artifacts) do
        local artifact = catalog.artifacts[key]
        s.level = math.max(s.level, artifact.level or 0)
        if progress.collectionHas(collection.key, key) then
            s.handed[key] = true
        elseif storage.count(artifact.restoredId).total == 0 then
            s.completable = false   -- still to hand in, and none restored ready
        end
    end
    return s
end

-- Fuzzy search on the collection's and collector's names: the letters typed appear in order.
local function matchesSearch(collection)
    local collector = catalog.collectors[collection.collector]
    local name, at = string.lower(collection.name .. " " .. (collector and collector.name or "")), 1
    for letter in string.lower(search):gmatch("%S") do
        at = string.find(name, letter, at, true)
        if not at then return false end
        at = at + 1
    end
    return true
end

-- Whether a collection passes the filter: it matches none of the unticked boxes, and its
-- collector's box is ticked.
local function matchesFilter(collection, s)
    local m = { completable = s.completable, notCompletable = not s.completable,
        neverCompleted = not s.everCompleted, completedBefore = s.everCompleted }
    for _, f in ipairs(FILTERS) do
        if m[f.key] and unticked[f.key] then return false end
    end
    return not unticked["collector:" .. tostring(collection.collector)]
end

-- The collections to show, in the chosen order, each with its status.
local function buildList()
    list = {}
    for _, collection in pairs(catalog.collections) do
        local s = window.status(collection)
        if matchesSearch(collection) and matchesFilter(collection, s) then table.insert(list, { collection = collection, status = s }) end
    end
    -- Collector name, then the game's order within a collector (its key ends in 01, 02...).
    local function byCollector(a, b)
        local ca, cb = catalog.collectors[a.collection.collector].name, catalog.collectors[b.collection.collector].name
        if ca ~= cb then return ca < cb end
        return a.collection.key < b.collection.key
    end
    table.sort(list, function(a, b)
        if sort == 1 and a.status.level ~= b.status.level then return a.status.level < b.status.level end
        if sort == 2 then
            -- Biggest reward first; rewards not seen yet go last.
            local ra, rb = chronotes.forCompletion(a.collection.key) or -1, chronotes.forCompletion(b.collection.key) or -1
            if ra ~= rb then return ra > rb end
        end
        return byCollector(a, b)
    end)
end

-- Builds one empty row; fillRow puts a collection in it. Like the game's panel: a header with
-- the name and collector (and the tick), slots for the artifacts, and the reward underneath.
local function makeRow(parent, i)
    local row = {}
    row.layer = ui.Layer.new(parent)
    row.layer:SetPos(0, (i - 1) * rowStep)
    row.layer:SetSize(ROW_W, rowH)
    row.button = widgets.button(row.layer, "", function()
        if row.collection then require("windows/collection_detail").open(row.collection) end
    end)
    row.button:SetSize(0, 0, 1.0, 1.0)
    local header = widgets.box(row.layer, widgets.PANEL)
    header:SetPos(2, 2)
    header:SetSize(-4, 26, 1.0, 0)
    row.name = widgets.text(row.layer, "", widgets.TITLE, widgets.TITLE_FONT)
    row.name:SetPos(10, 4)
    row.name:SetSize(-200, 22, 1.0, 0)
    row.name:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    row.collector = widgets.text(row.layer, "", widgets.DIM, widgets.SMALL_FONT)
    row.collector:SetPos(-190, 4, 1.0, 0)
    row.collector:SetSize(150, 22)
    row.collector:AlignTo(ui.AlignMode.BOTTOMRIGHT, ui.AlignMode.CENTRE)
    row.tick = ui.Sprite.new(row.layer)
    row.tick:SetPos(-30, 3, 1.0, 0)
    row.tick:SetSize(24, 24)
    row.tick.clickthrough = true
    row.icons, row.slots = {}, {}
    for n = 1, maxIcons do
        local x, y = 8 + ((n - 1) % PER_LINE) * SLOT_STEP, 32 + ((n - 1) // PER_LINE) * SLOT_STEP
        row.icons[n], row.slots[n] = widgets.slotIcon(row.layer, x, y, SLOT)
    end
    -- The reward: the chronote icon and the amount.
    local rewardY = 32 + lines * SLOT_STEP + 2
    row.coin = ui.Sprite.new(row.layer)
    row.coin.sprite = CHRONOTE_ICON
    row.coin:SetPos(10, rewardY + 2)
    row.coin:SetSize(16, 16)
    row.coin.clickthrough = true
    row.reward = widgets.text(row.layer, "", widgets.GOLD, widgets.SMALL_FONT)
    row.reward:SetPos(32, rewardY)
    row.reward:SetSize(-42, 20, 1.0, 0)
    row.reward:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return row
end

-- Shows a collection in a row, or hides the row if there's none.
local function fillRow(row, entry)
    row.collection = entry and entry.collection
    row.layer.hidden = entry == nil
    if not entry then return end
    local collection, s = entry.collection, entry.status
    local collector = catalog.collectors[collection.collector]
    row.name.content = string.upper(collection.name)
    row.collector.content = collector and collector.name or "?"
    row.tick.sprite = s.everCompleted and widgets.TICK_IMAGE or widgets.NO_TICK_IMAGE
    local reward = chronotes.forCompletion(collection.key)
    row.reward.content = reward and ("Reward: " .. withCommas(reward) .. " Chronotes")
        or "Reward: not seen yet (shown after you next complete it)"
    row.reward.colour = reward and widgets.WHITE or widgets.DIM
    for n, icon in ipairs(row.icons) do
        local key = collection.artifacts[n]
        icon.hidden, row.slots[n].hidden = key == nil, key == nil
        if key then widgets.showArtifact(icon, catalog.artifacts[key].restoredId, s.handed[key]) end
    end
end

-- How far the list can scroll before the last row reaches the bottom.
local function maxScroll()
    return math.max(0, #list * rowStep - LIST_HEIGHT)
end

-- Refills the rows for the scroll position, and the "Showing" line. Smooth scrolling as in the
-- Artifacts window: one spare row below, and the clipping layer slid by the part of a row scrolled past.
local function redraw()
    if not box then return end
    scrolled = math.max(0, math.min(scrolled, maxScroll()))
    local topRow = scrolled // rowStep
    for i, row in ipairs(rows) do fillRow(row, list[topRow + i]) end
    view:SetScrollPos(0, scrolled - topRow * rowStep)
    local lastVisible = math.min(math.ceil((scrolled + LIST_HEIGHT) / rowStep), #list)
    pageText.content = #list == 0 and "No collections match"
        or ("Showing " .. (topRow + 1) .. "-" .. lastVisible .. " of " .. #list .. " collections")
    local total = #list * rowStep
    scrollbar:show(maxScroll() > 0 and scrolled / maxScroll() or 0, total > 0 and LIST_HEIGHT / total or 1)
end

-- Scrolls by a distance in interface units (negative = up).
local function scrollBy(distance)
    scrolled = scrolled + distance
    redraw()
end

-- After the search, filter or sort changes: rebuild the list and go back to the top.
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
    searchBox:SetSize(WIDTH - 230, 26)
    searchBox.emptyText = "Search collections or collectors..."
    searchBox:Subscribe(ui.Hook.ONCONTENTCHANGED, function(_, _, text)
        search = text or ""
        refilter()
    end)
    local filterButton = widgets.iconButton(box, FILTER_ICON, function()
        filterPanel.hidden = not filterPanel.hidden
        if not filterPanel.hidden then filterPanel:MoveToFront() end
    end)
    filterButton:SetPos(WIDTH - 216, TOP)
    filterButton:SetSize(26, 26)
    -- A plain dropdown: the typing kind (COMBO_DEFAULT) put its choices in A-Z order in game.
    local sortBox = ui.ComboField.new(box)
    sortBox.stylesheetID = id.StyleSheet.DROPDOWN_DEFAULT
    sortBox:SetPos(WIDTH - 184, TOP)
    sortBox:SetSize(176, 26)
    for i, label in ipairs(SORTS) do sortBox:Add(label, i) end
    -- Show the current sort; if the dropdown won't, sort by what it does show, so they agree.
    local shown = widgets.choose(sortBox, sort)
    if shown and shown > 0 and shown ~= sort then sort = shown end
    log.say("Collections sort shown: " .. tostring(SORTS[sort]))
    -- Read the dropdown's own choice (as in the Artifacts window).
    sortBox:Subscribe(ui.Hook.ONSELECTIONCHANGED, function()
        if sortBox.selectedID and sortBox.selectedID > 0 and sortBox.selectedID ~= sort then
            sort = sortBox.selectedID
            log.say("Collections sort: " .. tostring(SORTS[sort]))
            refilter()
        end
    end)
end

local FILTER_COLUMN = 200   -- filter panel column width

-- The panel of filter boxes under the Filter button, in two columns: each collector (indented
-- under a "Collectors" heading) on the left, the progress boxes on the right, as in the
-- Artifacts window. The Collectors heading ticks or unticks every collector. Hidden until the
-- button is pressed.
local function buildFilterPanel()
    local collectors = {}
    for _, collector in pairs(catalog.collectors) do
        if #collector.collections > 0 then table.insert(collectors, collector) end
    end
    table.sort(collectors, function(a, b) return (a.name or "") < (b.name or "") end)
    local left = { { header = "Collectors" } }
    for _, collector in ipairs(collectors) do
        table.insert(left, { key = "collector:" .. collector.key, label = collector.name or "?", indent = true })
    end
    local right = { { header = "Progress" } }
    for _, f in ipairs(FILTERS) do table.insert(right, f) end
    filterPanel = widgets.filterPanel(box, WIDTH - 2 * FILTER_COLUMN - 16, TOP + 28, FILTER_COLUMN, { left, right },
        unticked, refilter)
end

-- Closes the window (the search, filter and sort are remembered).
function window.close()
    if scrollbar then scrollbar:remove() end
    widgets.destroyWindow(box)
    win, box, view, scrollbar, pageText, filterPanel, rows = nil, nil, nil, nil, nil, nil, {}
end

-- Opens the window, or does nothing if it's already open.
function window.open()
    if box then return end
    win = widgets.window("collections", "Collections", WIDTH, LIST_TOP + LIST_HEIGHT + 44, window.close)
    box = win.box
    buildControls()
    -- The list area: the game's darker content background, with the rows and scrollbar on it.
    local background = ui.Sprite.new(box)
    background.sprite = 18035  -- RS3_CHILD_CONTENT_TILE
    background.isTiling = true
    background:SetPos(8, LIST_TOP)
    background:SetSize(WIDTH - 16, LIST_HEIGHT + 8)
    -- Row size: enough slot lines for the biggest collection.
    maxIcons = 1
    for _, collection in pairs(catalog.collections) do maxIcons = math.max(maxIcons, #collection.artifacts) end
    lines = math.ceil(maxIcons / PER_LINE)
    rowH = 32 + lines * SLOT_STEP + 26
    rowStep = rowH + ROW_GAP
    visible = math.ceil(LIST_HEIGHT / rowStep)
    -- Rows sit in a layer that cuts off anything outside the visible area, with one spare row.
    view = ui.Layer.new(box)
    view:SetPos(12, LIST_TOP + 4)
    view:SetSize(ROW_W, LIST_HEIGHT)
    view:SetScrollSize(ROW_W, (visible + 1) * rowStep)
    for i = 1, visible + 1 do rows[i] = makeRow(view, i) end
    scrollbar = widgets.scrollbar(win, box, 16 + ROW_W, LIST_TOP + 4, LIST_HEIGHT,
        function(step) scrollBy(step * WHEEL_STEP) end,
        function(at) scrolled = math.floor(at * maxScroll() + 0.5); redraw() end,
        function(page) scrollBy(page * LIST_HEIGHT) end)
    view:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta) scrollBy((delta or 0) * WHEEL_STEP) end)
    pageText = widgets.text(box, "", widgets.DIM, widgets.SMALL_FONT)
    pageText:SetPos(8, LIST_TOP + LIST_HEIGHT + 16)
    pageText:SetSize(-16, 20, 1.0, 0)
    pageText:AlignTo(ui.AlignMode.CENTRE)
    buildFilterPanel()
    refilter()
end

-- Whether the window is open.
function window.isOpen()
    return box ~= nil
end

-- Keeps the list up to date: after storage or reward changes, and every few ticks for hand-ins
-- (the game doesn't announce those). The scroll position is kept.
function window.start()
    storage.onUpdate(function() dirty = true end)
    chronotes.onChange(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerCollectionsRedraw", function()
        ticks = ticks + 1
        if box and (dirty or ticks % CHECK_EVERY == 0) then
            buildList()
            redraw()
        end
        dirty = false
    end)
end

return window
