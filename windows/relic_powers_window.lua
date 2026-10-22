-- The Relic Powers window, laid out like the monolith's relic window: on the left your three
-- loadouts (tabs, the active one glowing gold) and the powers in the chosen one; on the right
-- every relic power as a button with its icon and name, greyed out until unlocked and ticked if
-- in your active loadout. Search, filter and sort controls at the top. Clicking a power opens its window.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local progress = require("core/progress")
local log = require("core/log")

local window = {}

local WIDTH = 660
local TOP = widgets.HEADER_HEIGHT + 8   -- controls row
local BODY = TOP + 34                    -- where the loadouts and grid start
local LEFT_W = 190                       -- the loadouts panel
local COLUMNS = 4
local CELL_W, CELL_H, SPACING = 98, 100, 4
local GRID_W = COLUMNS * (CELL_W + SPACING) + widgets.SCROLLBAR_WIDTH + 8
local GRID_H = 4 * (CELL_H + SPACING)    -- four rows of powers show; the rest scroll
local FILTER_ICON = 24449                -- the funnel, as in the other windows
local LOADOUTS = 3                       -- loadouts (numbered 0-2 in the game)
local CHECK_EVERY = 5                    -- ticks between checks for relic changes (3 s)

local win, box, area, filterPanel, loadoutPanel = nil, nil, nil, nil, nil
local shownLoadout = nil  -- the loadout tab chosen (0-3); the active one when the window opens
local lastState = nil     -- unlocks and loadouts last drawn, to spot changes
local ticks = 0

-- What the controls are set to. Kept while the window is closed.
local search, sort = "", 1
local unticked = {}
local SORTS = { "Name", "Unlocked first" }
local FILTERS = { { key = "unlocked", label = "Unlocked" }, { key = "locked", label = "Locked" } }

-- Whether a relic power is unlocked.
local function unlocked(relic)
    return progress.relicUnlocked(relic.key)
end

-- The relic numbers in a loadout's slots (0 = empty).
local function loadout(n)
    return progress.loadoutRelics(n)
end

-- Relic numbers in the active loadout, as a set.
local function equipped()
    local set = {}
    for _, number in ipairs(loadout(progress.activeLoadout() or 0)) do
        if number and number ~= 0 then set[number] = true end
    end
    return set
end

-- A summary of everything the window shows from your progress, to notice when it changes.
local function state()
    local parts = { tostring(progress.activeLoadout()) }
    for n = 0, LOADOUTS - 1 do table.insert(parts, table.concat(loadout(n), ",")) end
    for _, relic in pairs(catalog.relics) do
        if unlocked(relic) then table.insert(parts, relic.key) end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- The relics to show: matching the search and filter, in the chosen order.
local function relicList()
    local list = {}
    for _, relic in pairs(catalog.relics) do
        local name, at, matches = string.lower(relic.name or ""), 1, true
        for letter in string.lower(search):gmatch("%S") do
            at = string.find(name, letter, at, true)
            if not at then matches = false; break end
            at = at + 1
        end
        local isUnlocked = unlocked(relic)
        if matches and not (isUnlocked and unticked.unlocked) and not (not isUnlocked and unticked.locked) then
            table.insert(list, relic)
        end
    end
    table.sort(list, function(a, b)
        if sort == 2 and unlocked(a) ~= unlocked(b) then return unlocked(a) end
        return (a.name or "") < (b.name or "")
    end)
    return list
end

-- A relic's icon at x, y in parent, `size` across: full colour if unlocked, greyed out if not.
local function relicIcon(parent, relic, x, y, size)
    local icon = ui.Sprite.new(parent)
    icon.sprite = relic.icon
    icon:SetPos(x, y)
    icon:SetSize(size, size)
    icon.clickthrough = true
    if not unlocked(relic) then icon.colour = Vector4.new(0.3, 0.3, 0.3, 0.7) end
    return icon
end

-- One relic's button in the grid: name header, icon, and a tick if it's in your active loadout.
local function cell(parent, relic, x, y, isEquipped)
    local layer = ui.Layer.new(parent)
    layer:SetPos(x, y)
    layer:SetSize(CELL_W, CELL_H)
    local button = widgets.button(layer, "", function() require("windows/relic_power_detail").open(relic) end)
    button:SetSize(0, 0, 1.0, 1.0)
    local header = ui.Button.new(layer)
    header.stylesheetID = id.StyleSheet.TAB_HEADER_24PX
    header:SetPos(2, 2)
    header:SetSize(-4, 34, 1.0, 0)
    header.clickthrough = true
    local name = widgets.text(layer, (widgets.wrap(relic.name or "?", 13)), unlocked(relic) and widgets.NAME or widgets.DIM,
        widgets.SMALL_FONT)
    name:SetPos(3, 3)
    name:SetSize(-6, 32, 1.0, 0)
    name.maxLines = 2
    name:AlignTo(ui.AlignMode.CENTRE)
    relicIcon(layer, relic, CELL_W // 2 - 26, 40, 52)
    if isEquipped then
        local tick = ui.Sprite.new(layer)
        tick.sprite = widgets.TICK_IMAGE
        tick:SetPos(-26, -26, 1.0, 1.0)
        tick:SetSize(22, 22)
        tick.clickthrough = true
    end
end

-- The left panel: the three loadout tabs, then the chosen loadout's relic powers.
local function drawLoadouts()
    if loadoutPanel then loadoutPanel:Destroy() end
    loadoutPanel = ui.Layer.new(box)
    loadoutPanel:SetPos(8, BODY)
    loadoutPanel:SetSize(LEFT_W, GRID_H + 8)
    local background = widgets.box(loadoutPanel, widgets.PANEL)
    background:SetSize(0, 0, 1.0, 1.0)
    local active = progress.activeLoadout() or 0
    local heading = widgets.text(loadoutPanel, "Relic loadouts", widgets.GOLD, widgets.BOLD_FONT)
    heading:SetPos(8, 4)
    heading:SetSize(-16, 20, 1.0, 0)
    -- Tabs 1-3: the chosen one shown pressed. The active one glows gold: a gold box just
    -- bigger than the tab, behind it.
    for n = 0, LOADOUTS - 1 do
        local x = 8 + n * 58
        if n == active then
            local glow = widgets.box(loadoutPanel, Vector4.new(1.0, 0.75, 0.15, 0.9))
            glow:SetPos(x - 3, 25)
            glow:SetSize(58, 30)
        end
        local tab = widgets.button(loadoutPanel, tostring(n + 1), function()
            shownLoadout = n
            drawLoadouts()
        end)
        tab:SetPos(x, 28)
        tab:SetSize(52, 24)
        tab.enabled = n ~= shownLoadout
    end
    local note = widgets.text(loadoutPanel, shownLoadout == active and "Active loadout" or "Not active", widgets.DIM,
        widgets.SMALL_FONT)
    note:SetPos(8, 56)
    note:SetSize(-16, 18, 1.0, 0)
    -- The loadout's slots: each relic's icon and name, or "Empty".
    for slot, number in ipairs(loadout(shownLoadout)) do
        local y = 80 + (slot - 1) * 82
        local relic = number and catalog.relics[number]
        local layer = ui.Layer.new(loadoutPanel)
        layer:SetPos(8, y)
        layer:SetSize(-16, 76, 1.0, 0)
        local button = widgets.button(layer, "", relic and function() require("windows/relic_power_detail").open(relic) end or nil)
        button:SetSize(0, 0, 1.0, 1.0)
        if relic then
            relicIcon(layer, relic, 6, 10, 56)
            local name = widgets.text(layer, (widgets.wrap(relic.name or "?", 14)), widgets.NAME, widgets.SMALL_FONT)
            name:SetPos(68, 4)
            name:SetSize(-72, 68, 1.0, 0)
            name:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        else
            local empty = widgets.text(layer, "Empty slot " .. slot, widgets.DIM, widgets.SMALL_FONT)
            empty:SetSize(0, 0, 1.0, 1.0)
            empty:AlignTo(ui.AlignMode.CENTRE)
        end
    end
end

-- The right side: every relic matching the search and filter, in a scrolling grid.
local function drawGrid()
    if area then area:remove(); area.content:Destroy() end
    local list = relicList()
    local isEquipped = equipped()
    local rows = math.ceil(#list / COLUMNS)
    area = widgets.scrollArea(win, box, LEFT_W + 16, BODY, GRID_W, GRID_H, rows * (CELL_H + SPACING), CELL_H + SPACING)
    for i, relic in ipairs(list) do
        local col, row = (i - 1) % COLUMNS, (i - 1) // COLUMNS
        cell(area.content, relic, col * (CELL_W + SPACING), row * (CELL_H + SPACING), isEquipped[relic.number])
    end
    if #list == 0 then
        local none = widgets.text(area.content, "No relic powers match", widgets.DIM, widgets.SMALL_FONT)
        none:SetSize(0, 40, 1.0, 0)
        none:AlignTo(ui.AlignMode.CENTRE)
    end
end

-- Redraws both sides.
local function redraw()
    if not box then return end
    lastState = state()
    drawLoadouts()
    drawGrid()
end

-- The search box, Filter button and Sort dropdown at the top.
local function buildControls()
    local searchBox = ui.InputField.new(box)
    searchBox.stylesheetID = id.StyleSheet.INPUT_DEFAULT
    searchBox:SetPos(8, TOP)
    searchBox:SetSize(WIDTH - 230, 26)
    searchBox.emptyText = "Search relic powers..."
    searchBox:Subscribe(ui.Hook.ONCONTENTCHANGED, function(_, _, text)
        search = text or ""
        drawGrid()
    end)
    local filterButton = widgets.iconButton(box, FILTER_ICON, function()
        filterPanel.hidden = not filterPanel.hidden
        if not filterPanel.hidden then filterPanel:MoveToFront() end
    end)
    filterButton:SetPos(WIDTH - 216, TOP)
    filterButton:SetSize(26, 26)
    local sortBox = ui.ComboField.new(box)
    sortBox.stylesheetID = id.StyleSheet.DROPDOWN_DEFAULT
    sortBox:SetPos(WIDTH - 184, TOP)
    sortBox:SetSize(176, 26)
    for i, label in ipairs(SORTS) do sortBox:Add(label, i) end
    -- Show the current sort; if the dropdown won't, sort by what it does show, so they agree.
    local shown = widgets.choose(sortBox, sort)
    if shown and shown > 0 and shown ~= sort then sort = shown end
    sortBox:Subscribe(ui.Hook.ONSELECTIONCHANGED, function()
        if sortBox.selectedID and sortBox.selectedID > 0 and sortBox.selectedID ~= sort then
            sort = sortBox.selectedID
            log.say("Relic powers sort: " .. tostring(SORTS[sort]))
            drawGrid()
        end
    end)
end

-- The filter boxes under the Filter button. Hidden until the button is pressed.
local function buildFilterPanel()
    filterPanel = ui.GroupBox.new(box)
    filterPanel.stylesheetID = id.StyleSheet.DEFAULT
    filterPanel:SetHeaderLayout(0, 0, 0, 0, 0)
    filterPanel:SetPos(WIDTH - 216, TOP + 28)
    filterPanel:SetSize(208, #FILTERS * 20 + 10)
    filterPanel.clickthrough = false
    for i, f in ipairs(FILTERS) do
        local check = ui.Check.new(filterPanel)
        check.stylesheetID = id.StyleSheet.CHECKBOX_DEFAULT
        check.alignment = ui.CheckAlignMode.LEFT
        check.buttonSize = 16
        check.label = f.label
        check.text.font = widgets.SMALL_FONT
        check.value = not unticked[f.key]
        check:SetPos(8, 5 + (i - 1) * 20)
        check:SetSize(192, 20)
        -- The box's own state is read after the press; it may be true/false or 1/0.
        check:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
            local isTicked = check.value == true or check.value == 1
            unticked[f.key] = not isTicked or nil
            drawGrid()
        end)
    end
    filterPanel.hidden = true
end

-- Closes the window (the search, filter and sort are remembered).
function window.close()
    if area then area:remove() end
    widgets.destroyWindow(box)
    win, box, area, filterPanel, loadoutPanel = nil, nil, nil, nil, nil
end

-- Opens the window on your active loadout, or does nothing if it's already open.
function window.open()
    if box then return end
    win = widgets.window("relicPowers", "Relic Powers", WIDTH, BODY + GRID_H + 16, window.close)
    box = win.box
    shownLoadout = progress.activeLoadout() or 0
    buildControls()
    redraw()
    buildFilterPanel()   -- built last, so it draws on top
end

-- Whether the window is open.
function window.isOpen()
    return box ~= nil
end

-- Every few ticks, redraws if relics were unlocked or loadouts changed (the game doesn't announce it).
function window.start()
    Event.ServerLogic.Subscribe("trackerRelicPowersRedraw", function()
        ticks = ticks + 1
        if box and ticks % CHECK_EVERY == 0 and state() ~= lastState then
            redraw()
            filterPanel:MoveToFront()
        end
    end)
end

return window
