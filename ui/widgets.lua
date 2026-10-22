-- Shared look and small building blocks for the tracker's windows.

local widgets = {}

-- Returns the first font this client has. Missing fonts come back as -1 and draw nothing.
local function pickFont(...)
    for _, name in ipairs({ ... }) do
        local ok, font = pcall(function() return id.Font[name] end)
        if ok and font and font ~= -1 then return font end
    end
end

-- Fonts the client was seen to have: Museo Sans 13/15pt, 15pt bold; Cinzel bold 12/13/15/18pt.
widgets.FONT = pickFont("MUSEO_SANS_15PT_REGULAR")
widgets.TITLE_FONT = pickFont("CINZEL_13PT_BOLD", "MUSEO_SANS_15PT_BOLD", "MUSEO_SANS_15PT_REGULAR")  -- the game's window title font
widgets.SMALL_FONT = pickFont("MUSEO_SANS_13PT_REGULAR", "MUSEO_SANS_15PT_REGULAR")
widgets.BOLD_FONT = pickFont("MUSEO_SANS_15PT_BOLD", "MUSEO_SANS_15PT_REGULAR")

widgets.WHITE = Vector4.new(1.0, 1.0, 1.0, 1.0)
widgets.DIM = Vector4.new(0.6, 0.6, 0.6, 1.0)
widgets.GOLD = Vector4.new(1.0, 0.85, 0.3, 1.0)
widgets.TITLE = Vector4.new(0.95, 0.8, 0.45, 1.0)  -- window title gold
widgets.PANEL = Vector4.new(0.05, 0.05, 0.05, 0.6)  -- darker inset behind numbers
widgets.NAME = Vector4.new(0.95, 0.85, 0.6, 1.0)    -- pale gold for headings inside a window
widgets.ENOUGH = Vector4.new(0.45, 0.9, 0.45, 1.0)  -- green: you have enough
widgets.SHORT = Vector4.new(0.95, 0.45, 0.4, 1.0)   -- red: you don't have enough

-- Collection look, as in the game's collection window: each artifact in a sunken slot, full
-- colour once handed in, a black shape until then. Images picked by name from `pan Sprite`.
widgets.SLOT_IMAGE = 18269    -- RS3_ICON_SLOT_STANDARD
widgets.TICK_IMAGE = 17127    -- RS3_ICON_CHECK_MARK_24PX_0: ticked circle, on collections completed before
widgets.NO_TICK_IMAGE = 17128 -- RS3_ICON_CHECK_MARK_24PX_1: empty circle, on collections never completed
local HANDED_IN = Vector4.new(1.0, 1.0, 1.0, 1.0)
local NOT_HANDED_IN = Vector4.new(0.02, 0.02, 0.02, 1.0)  -- near black: pure 0 might count as "no tint"

-- An artifact in a sunken slot at x, y, `size` across. Returns the icon, so it can be changed later.
function widgets.slotIcon(parent, x, y, size)
    local slot = ui.Sprite.new(parent)
    slot.sprite = widgets.SLOT_IMAGE
    slot:SetPos(x, y)
    slot:SetSize(size, size)
    slot.clickthrough = true
    local icon = ui.Sprite.new(parent)
    icon:SetPos(x + 4, y + 4)
    icon:SetSize(size - 8, size - 8)
    icon.clickthrough = true
    return icon, slot
end

-- Shows an artifact in an icon: full colour if handed in, a black shape if not.
function widgets.showArtifact(icon, itemId, handedIn)
    icon:SetAssociatedObject(itemId)
    icon.colour = handedIn and HANDED_IN or NOT_HANDED_IN
end

-- Game text doesn't wrap by itself, so this splits text into lines of about lineChars
-- characters at spaces, joined with "<br>" (the game's line break). Returns the text and line count.
function widgets.wrap(text, lineChars)
    local lines, line = {}, ""
    for word in (text or ""):gmatch("%S+") do
        if line ~= "" and #line + 1 + #word > lineChars then
            table.insert(lines, line)
            line = word
        else
            line = line == "" and word or (line .. " " .. word)
        end
    end
    if line ~= "" then table.insert(lines, line) end
    return table.concat(lines, "<br>"), #lines
end

-- A filled box for decoration. Lets clicks through, so a button underneath still works.
function widgets.box(parent, colour)
    local r = ui.Rectangle.new(parent)
    r.colour = colour
    r.fill = true
    r.clickthrough = true
    return r
end

-- The layer plugins draw on, above most of the game's own windows.
function widgets.gameWindow()
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
end

-- Text that doesn't block clicks, so a button underneath still works.
-- Set up in the same order as Jagex's tutorial, which is known to show.
function widgets.text(parent, content, colour, font)
    local t = ui.Text.new(parent)
    t.content = content or ""
    t.font = font or widgets.FONT
    if colour then t.colour = colour end
    t.clickthrough = true
    return t
end

-- A button in the game's standard style that calls onPress when clicked.
function widgets.button(parent, label, onPress)
    local b = ui.Button.new(parent)
    b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    b.label = label or ""
    if onPress then b:Subscribe(ui.Hook.ONBUTTONPRESSED, onPress) end
    return b
end

-- Makes a dropdown show the choice with this number. In game, dropdowns list their choices
-- A-Z and Select(number) didn't take, so this also tries the choice's place in the list.
-- Returns the number of the choice it ended up showing.
function widgets.choose(dropdown, wanted)
    local place = nil
    pcall(function()
        for i, entry in ipairs(dropdown.entries) do
            if entry.id == wanted then place = i end
        end
    end)
    for _, try in ipairs({ wanted, place, place and place - 1 }) do
        pcall(function() dropdown:Select(try, false) end)
        if dropdown.selectedID == wanted then return wanted end
    end
    return dropdown.selectedID
end

-- Window dragging: while the title bar is held, the window follows the mouse every frame.
-- The game ends a press as soon as the mouse leaves the part pressed, so a fast mouse used to
-- outrun the header and drop the window. Instead each window has an invisible grip over its
-- header; while it's held, the grip covers the whole screen, so the mouse can't leave it and the
-- drag only ends when the button is let go (round 24 probe).
local dragging = nil  -- { window, mouse start, window start }
local grips = {}      -- window frame -> its grip, so closing the window can remove it

-- Puts a window's grip over its header (not the close button), or over the whole screen while dragging.
local function placeGrip(win)
    if not win.grip then return end
    if dragging and dragging.window == win then
        win.grip:SetPos(0, 0)
        win.grip:SetSize(0, 0, 1.0, 1.0)
    else
        win.grip:SetPos(win.x, win.y)
        win.grip:SetSize(win.width - widgets.HEADER_HEIGHT, widgets.HEADER_HEIGHT)
    end
end

-- Moves a window, keeping at least part of its header on screen.
local function placeWindow(win, x, y)
    -- Keep at least the title bar on screen.
    local screen = widgets.gameWindow()
    if screen.width then x = math.min(x, screen.width - 60) end
    if screen.height then y = math.min(y, screen.height - 30) end
    x, y = math.max(0, x), math.max(0, y)
    win.x, win.y = x, y
    win.box:SetPos(x, y)
    placeGrip(win)
end

-- Remembers where a window is, so it reopens there.
local function savePosition(win)
    PersistentDB:SetStructuredData("window/" .. win.name, { x = win.x, y = win.y })
end

-- The mouse is measured in screen pixels, but windows are placed in interface units, which
-- differ when the game's Interface Scale option isn't 100%. Without this the window drifts
-- away from the mouse and the drag drops. The option's setting is the percentage (e.g. 120).
local function interfaceScale()
    local ok, scale = pcall(function() return game.options.InterfaceScale.setting / 100 end)
    return (ok and scale and scale > 0) and scale or 1
end

Event.Draw.Subscribe("trackerWindowDrag", function()
    if not dragging then return end
    local mx, my = Mouse.GetX(), Mouse.GetY()
    if not (mx and my) then return end
    local s = dragging.scale
    placeWindow(dragging.window, dragging.startX + math.floor((mx - dragging.mouseX) / s),
        dragging.startY + math.floor((my - dragging.mouseY) / s))
end)

-- Header pressed: remember where the mouse and window started, and spread the grip over the screen.
local function startDrag(win)
    local mx, my = Mouse.GetX(), Mouse.GetY()
    if not (mx and my) then return end
    dragging = { window = win, mouseX = mx, mouseY = my, startX = win.x, startY = win.y, scale = interfaceScale() }
    placeGrip(win)
end

-- Header released: stop following the mouse, remember the spot, and put the grip back on the header.
local function stopDrag()
    local win = dragging and dragging.window
    if win then savePosition(win) end
    dragging = nil
    if win then placeGrip(win) end
end

-- The game's own window images (RS3_CHILD_* in `pan Sprite`), the same ones its windows use.
local HEADER_TILE, HEADER_RIGHT = 18000, 17997
local CLOSE, CLOSE_HOVER = 18442, 18443
local MOVE_CURSOR = 194  -- TOPLEVEL_V2_MOVE: the four-arrow cursor the game shows on window headers
local HEADER_HEIGHT = 28
widgets.HEADER_HEIGHT = HEADER_HEIGHT

-- One of the game's images that blocks clicks to the game world behind it.
local function sprite(parent, spriteId)
    local s = ui.Sprite.new(parent)
    s.sprite = spriteId
    s.clickthrough = false  -- clicks on the window must not reach the game world behind it
    return s
end

-- A window with the game's header (drag it to move the window) and close button.
-- It opens where it was last left, or in the middle of the screen the first time.
-- Content goes below widgets.HEADER_HEIGHT. Returns { box = the window to build inside, ... }.
function widgets.window(name, title, width, height, onClose)
    local box = ui.GroupBox.new(widgets.gameWindow())
    box.stylesheetID = id.StyleSheet.DEFAULT
    box:SetHeaderLayout(0, 0, 0, 0, 0)  -- no built-in header; we draw the game's own below
    box:SetSize(width, height)
    box.clickthrough = false
    local win = { name = name, box = box, width = width }

    -- Header: a middle piece repeated from the left edge, then the right corner (behind the
    -- close button).
    local middle = sprite(box, HEADER_TILE)
    middle.isTiling = true
    middle:SetSize(-HEADER_HEIGHT, HEADER_HEIGHT, 1.0, 0)
    local right = sprite(box, HEADER_RIGHT)
    right:SetPos(-HEADER_HEIGHT, 0, 1.0, 0)
    right:SetSize(HEADER_HEIGHT, HEADER_HEIGHT)

    local heading = widgets.text(box, string.upper(title), widgets.TITLE, widgets.TITLE_FONT)
    heading:SetSize(0, HEADER_HEIGHT, 1.0, 0)
    heading:AlignTo(ui.AlignMode.CENTRE)

    -- Close button, lit up while the mouse is over it.
    local close = sprite(box, CLOSE)
    close:SetPos(-HEADER_HEIGHT + 3, 3, 1.0, 0)
    close:SetSize(HEADER_HEIGHT - 6, HEADER_HEIGHT - 6)
    close:Subscribe(ui.Hook.ONMOUSEOVER, function() close.sprite = CLOSE_HOVER end)
    close:Subscribe(ui.Hook.ONMOUSELEAVE, function() close.sprite = CLOSE end)
    close:Subscribe(ui.Hook.ONCLICK, function()
        stopDrag()
        onClose()
    end)

    -- The grip that drags the window: invisible, over the header, on the screen layer (inside the
    -- window it would be cut off at the window's edges when it spreads over the screen).
    local grip = ui.Rectangle.new(widgets.gameWindow())
    grip.colour = Vector4.new(0, 0, 0, 0)
    grip.fill = true
    grip.clickthrough = false
    pcall(function() grip.cursorConfig.mouseOverCursor = MOVE_CURSOR end)
    grip:Subscribe(ui.Hook.ONCLICK, function() startDrag(win) end)
    grip:Subscribe(ui.Hook.ONRELEASE, stopDrag)
    win.grip, grips[box] = grip, grip

    local saved = PersistentDB:GetStructuredData("window/" .. name)
    if saved and saved.x then
        placeWindow(win, math.tointeger(saved.x) or 0, math.tointeger(saved.y) or 0)
    else
        local screen = widgets.gameWindow()
        placeWindow(win, ((screen.width or width) - width) // 2, ((screen.height or height) - height) // 2)
    end
    return win
end

-- Closes a window made by widgets.window: removes it and its header grip (which lives outside it).
function widgets.destroyWindow(box)
    if not box then return end
    if dragging and dragging.window.box == box then dragging = nil end
    if grips[box] then grips[box]:Destroy() end
    grips[box] = nil
    box:Destroy()
end

-- A small square button showing one of the game's icons (e.g. the filter funnel).
-- Buttons can't hold other components, so the button and icon share a layer.
-- Returns the layer: position and size it like a button.
function widgets.iconButton(parent, iconSprite, onPress)
    local holder = ui.Layer.new(parent)
    local b = widgets.button(holder, "", onPress)
    b:SetSize(0, 0, 1.0, 1.0)
    local icon = ui.Sprite.new(holder)
    icon.sprite = iconSprite
    icon:SetPos(4, 4)  -- fixed offset: centring by a share of its own size didn't show in game
    icon:SetSize(-8, -8, 1.0, 1.0)
    icon.clickthrough = true
    return holder
end

-- The game's default list scrollbar (DEFAULT_SCROLLBAR_* in `pan Sprite`). 
-- Each image holds 4 states stacked top to bottom: normal, mouse over, pressed, disabled.
local SCROLL_TRACK, SCROLL_BUTTON, SCROLL_HANDLE = 15108, 15110, 15112
local NORMAL, HOVER, PRESSED = 0, 1, 2
local BUTTON_LENGTH = 10  -- as the game's lists use
widgets.SCROLLBAR_WIDTH = 16
local activeBars = {}  -- scrollbars on screen, kept up to date every frame

-- Shows one state of a 4-state image: the image sits in a clipping layer one state tall,
-- and is slid up to the state wanted. Upside-down images (flipped) count states from the bottom.
local function stateImage(parent, spriteId, x, y, w, h, flipped)
    local holder = ui.Layer.new(parent)
    holder.clickthrough = false
    local image = ui.Sprite.new(holder)
    image.sprite = spriteId
    image.isFlippedVertical = flipped or false
    image.clickthrough = true
    local piece = { holder = holder, image = image, state = NORMAL }
    -- Moves and sizes the piece (the image is 4 states tall).
    function piece:place(px, py, pw, ph)
        self.h = ph
        holder:SetPos(px, py)
        holder:SetSize(pw, ph)
        image:SetSize(pw, ph * 4)
        self:set(self.state)
    end
    -- Shows normal, mouse-over or pressed.
    function piece:set(state)
        self.state = state
        image:SetPos(0, -(flipped and (3 - state) or state) * (self.h or 0))
    end
    piece:place(x, y, w, h)
    return piece
end

-- Lights a piece up while the mouse is over it, and shows it pressed while clicked.
local function hoverStates(piece, target)
    target = target or piece.holder
    target:Subscribe(ui.Hook.ONMOUSEOVER, function() piece:set(HOVER) end)
    target:Subscribe(ui.Hook.ONMOUSELEAVE, function() piece:set(NORMAL) end)
end

-- Every frame: keep each handle's grip over its handle, or under the mouse while it's held.
Event.Draw.Subscribe("trackerScrollbars", function()
    for bar in pairs(activeBars) do bar:update() end
end)

-- A vertical scrollbar like the game's lists have: arrow buttons, a track and a handle.
-- win is the window it's in; x, y, height are its place in parent.
-- onStep(-1 or 1): an arrow was clicked. onScrollTo(0 to 1): the handle was dragged.
-- onPage(-1 or 1): the track was clicked above or below the handle.
-- Call bar:show(at, visible) with how far down the list is (0-1) and how much fits (0-1).
function widgets.scrollbar(win, parent, x, y, height, onStep, onScrollTo, onPage)
    local w = widgets.SCROLLBAR_WIDTH
    local bar = { at = 0, visible = 1, trackTop = y + BUTTON_LENGTH, trackLength = height - 2 * BUTTON_LENGTH }

    local track = stateImage(parent, SCROLL_TRACK, x, bar.trackTop, w, bar.trackLength)
    track.holder:Subscribe(ui.Hook.ONCLICK, function(_, _, clickY)
        -- Clicks above the handle page up, below it page down.
        local handleMiddle = (bar.handleTop or 0) - bar.trackTop + (bar.handleLength or 0) / 2
        onPage((clickY or handleMiddle + 1) < handleMiddle and -1 or 1)
    end)
    local up = stateImage(parent, SCROLL_BUTTON, x, y, w, BUTTON_LENGTH)
    local down = stateImage(parent, SCROLL_BUTTON, x, y + height - BUTTON_LENGTH, w, BUTTON_LENGTH, true)
    for direction, button in pairs({ [-1] = up, [1] = down }) do
        hoverStates(button)
        button.holder:Subscribe(ui.Hook.ONCLICK, function()
            button:set(PRESSED)
            onStep(direction)
        end)
        button.holder:Subscribe(ui.Hook.ONRELEASE, function() button:set(HOVER) end)
    end
    local handle = stateImage(parent, SCROLL_HANDLE, x, bar.trackTop, w, 24)
    handle.holder.clickthrough = true  -- the grip below takes the clicks

    -- The grip: an invisible box on the screen layer (not inside the window, which would cut
    -- it off), kept over the handle. While held it covers the whole screen, so the mouse never
    -- leaves it and the game doesn't end the drag, however fast the mouse moves.
    local grip = ui.Rectangle.new(widgets.gameWindow())
    grip.colour = Vector4.new(0, 0, 0, 0)
    grip.fill = true
    grip.clickthrough = false
    hoverStates(handle, grip)
    local held = nil  -- { mouse start, position start, scale } while the handle is held
    grip:Subscribe(ui.Hook.ONCLICK, function()
        local my = Mouse.GetY()
        if my then held = { mouseY = my, startAt = bar.at, scale = interfaceScale() } end
        handle:set(PRESSED)
    end)
    grip:Subscribe(ui.Hook.ONRELEASE, function()
        held = nil
        handle:set(NORMAL)
    end)

    -- Every frame: follow the mouse while held, otherwise sit over the handle.
    function bar:update()
        if held then
            local mx, my = Mouse.GetX(), Mouse.GetY()
            if not (mx and my) then return end
            local room = self.trackLength - self.handleLength
            if room > 0 then onScrollTo(math.max(0, math.min(1, held.startAt + (my - held.mouseY) / held.scale / room))) end
            grip:SetPos(0, 0)   -- the whole screen while held, so the mouse can't leave it
            grip:SetSize(0, 0, 1.0, 1.0)
        else
            grip.hidden = self.visible >= 1
            grip:SetPos(win.x + x, win.y + self.handleTop)
            grip:SetSize(w, self.handleLength)
        end
    end

    -- Moves and sizes the handle. Hidden when everything fits.
    function bar:show(at, visible)
        self.at, self.visible = at, visible
        handle.holder.hidden = visible >= 1
        self.handleLength = math.max(24, math.floor(self.trackLength * math.min(visible, 1)))
        self.handleTop = self.trackTop + math.floor((self.trackLength - self.handleLength) * at)
        handle:place(x, self.handleTop, w, self.handleLength)
    end

    -- Removes the grip (it lives outside the window, so closing the window doesn't remove it).
    function bar:remove()
        activeBars[self] = nil
        grip:Destroy()
    end

    bar:show(0, 1)
    activeBars[bar] = true
    return bar
end

-- A scrolling section of a window: a clipping layer at x, y (w x h) with a scrollbar down its
-- right side, for contents `contentHeight` tall. Build the contents inside `area.content`; call
-- area:remove() when the window closes (the scrollbar's grip lives outside the window).
function widgets.scrollArea(win, parent, x, y, w, h, contentHeight, wheelStep)
    local area = { scrolled = 0 }
    local view = ui.Layer.new(parent)
    view:SetPos(x, y)
    view:SetSize(w - widgets.SCROLLBAR_WIDTH - 4, h)
    view:SetScrollSize(w - widgets.SCROLLBAR_WIDTH - 4, math.max(h, contentHeight))
    area.content = view
    local room = math.max(0, contentHeight - h)
    local bar
    -- Moves the contents to a scroll position, kept within the contents.
    local function scrollTo(position)
        area.scrolled = math.max(0, math.min(room, position))
        view:SetScrollPos(0, area.scrolled)
        bar:show(room > 0 and area.scrolled / room or 0, contentHeight > 0 and math.min(1, h / contentHeight) or 1)
    end
    bar = widgets.scrollbar(win, parent, x + w - widgets.SCROLLBAR_WIDTH, y, h,
        function(step) scrollTo(area.scrolled + step * wheelStep) end,
        function(at) scrollTo(math.floor(at * room + 0.5)) end,
        function(page) scrollTo(area.scrolled + page * h) end)
    view:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta) scrollTo(area.scrolled + (delta or 0) * wheelStep) end)
    -- Removes the scrollbar's grip.
    function area:remove() bar:remove() end
    scrollTo(0)
    return area
end

-- The game's bevelled frames (round 25 probe), each nine images: corners and edges around a
-- centre, in reading order. "panel" is the raised panel of its research window (edges 8 thick);
-- "slot" is the sunken item-slot look (RS3_ICON_SLOT_0-8, edges 10 thick).
local BEVELS = {
    panel = { edge = 8, 18081, 18082, 18083, 18084, 18085, 18086, 23881, 23882, 23883 },
    slot = { edge = 10, 18257, 18258, 18259, 18260, 18261, 18262, 18263, 18264, 18265 },
}

-- A bevelled box at x, y in parent, w x h, in the "panel" (default) or "slot" style. Returns a
-- layer covering it to build inside.
function widgets.bevelBox(parent, x, y, w, h, style)
    local layer = ui.Layer.new(parent)
    layer:SetPos(x, y)
    layer:SetSize(w, h)
    layer.clickthrough = true
    -- One piece of the frame, stretched to fit its place.
    local function piece(spriteId, px, py, pw, ph)
        local s = ui.Sprite.new(layer)
        s.sprite = spriteId
        s:SetPos(px, py)
        s:SetSize(pw, ph)
        s.clickthrough = true
    end
    local set = BEVELS[style or "panel"]
    local e = set.edge
    piece(set[1], 0, 0, e, e); piece(set[2], e, 0, w - 2 * e, e); piece(set[3], w - e, 0, e, e)
    piece(set[4], 0, e, e, h - 2 * e); piece(set[5], e, e, w - 2 * e, h - 2 * e); piece(set[6], w - e, e, e, h - 2 * e)
    piece(set[7], 0, h - e, e, e); piece(set[8], e, h - e, w - 2 * e, e); piece(set[9], w - e, h - e, e, e)
    return layer
end

-- A whole number with commas: 2635 as "2,635".
function widgets.withCommas(n)
    local s = tostring(math.tointeger(n) or n)
    while true do
        local changed
        s, changed = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if changed == 0 then return s end
    end
end

-- A section that scrolls sideways, in a sunken slot-style frame: a clipping layer for contents
-- `contentWidth` wide, and along the bottom a horizontal scrollbar (the game's horizontal handle,
-- SCROLLBAR_DRAGGER_HORIZONTAL_V2, on a dark track). Drag the handle (its grip covers the whole
-- screen while held, as for the other scrollbars), click the track to page, or use the mouse
-- wheel. Build inside `area.content`; call area:remove() when the window closes.
local SIDEWAYS_HANDLE = { normal = 25154, hover = 25155, pressed = 25156 }
local SIDEWAYS_BAR = 12   -- the scrollbar's height

function widgets.scrollAreaSideways(win, parent, x, y, w, h, contentWidth, step)
    local inset = 10                                  -- inside the frame's edges
    local frame = widgets.bevelBox(parent, x, y, w, h, "slot")
    local viewW, viewH = w - 2 * inset, h - 2 * inset - SIDEWAYS_BAR - 4
    local area = { scrolled = 0 }
    local view = ui.Layer.new(frame)
    view:SetPos(inset, inset)
    view:SetSize(viewW, viewH)
    view:SetScrollSize(math.max(viewW, contentWidth), viewH)
    area.content = view
    local room = math.max(0, contentWidth - viewW)
    -- The scrollbar: a dark track, and the handle sized to how much of the contents fits.
    local trackX, trackY, trackW = inset, h - inset - SIDEWAYS_BAR, viewW
    local track = widgets.box(frame, Vector4.new(0.0, 0.0, 0.0, 0.5))
    track:SetPos(trackX, trackY)
    track:SetSize(trackW, SIDEWAYS_BAR)
    track.clickthrough = false
    local handleW = math.max(30, math.floor(trackW * math.min(1, viewW / math.max(contentWidth, 1))))
    local handle = ui.Sprite.new(frame)
    handle.sprite = SIDEWAYS_HANDLE.normal
    handle:SetSize(handleW, SIDEWAYS_BAR)
    handle.clickthrough = true   -- the grip below takes the clicks
    handle.hidden = room == 0
    -- Moves the contents to a scroll position, kept within the contents, and the handle with it.
    local function scrollTo(position)
        area.scrolled = math.max(0, math.min(room, position))
        view:SetScrollPos(area.scrolled, 0)
        area.handleX = trackX + (room > 0 and math.floor((trackW - handleW) * area.scrolled / room) or 0)
        handle:SetPos(area.handleX, trackY)
    end
    -- Clicking the track pages left or right of the handle.
    track:Subscribe(ui.Hook.ONCLICK, function(_, clickX)
        local middle = area.handleX - trackX + handleW / 2
        scrollTo(area.scrolled + ((clickX or middle + 1) < middle and -viewW or viewW))
    end)
    -- The grip over the handle, on the screen layer (as for the other scrollbars).
    local grip = ui.Rectangle.new(widgets.gameWindow())
    grip.colour = Vector4.new(0, 0, 0, 0)
    grip.fill = true
    grip.clickthrough = false
    grip.hidden = room == 0
    local held = nil   -- { mouse start, scroll start, scale } while the handle is held
    grip:Subscribe(ui.Hook.ONMOUSEOVER, function() if not held then handle.sprite = SIDEWAYS_HANDLE.hover end end)
    grip:Subscribe(ui.Hook.ONMOUSELEAVE, function() if not held then handle.sprite = SIDEWAYS_HANDLE.normal end end)
    grip:Subscribe(ui.Hook.ONCLICK, function()
        local mx = Mouse.GetX()
        if mx then held = { mouseX = mx, startAt = area.scrolled, scale = interfaceScale() } end
        handle.sprite = SIDEWAYS_HANDLE.pressed
    end)
    grip:Subscribe(ui.Hook.ONRELEASE, function()
        held = nil
        handle.sprite = SIDEWAYS_HANDLE.normal
    end)
    local bar = {}
    -- Every frame: follow the mouse while held (the grip then covers the screen), otherwise sit
    -- over the handle. (`parent` is expected to sit at the window's top-left corner.)
    function bar:update()
        if held then
            local mx = Mouse.GetX()
            if not mx then return end
            local free = trackW - handleW
            if free > 0 then scrollTo(held.startAt + (mx - held.mouseX) / held.scale / free * room) end
            grip:SetPos(0, 0)
            grip:SetSize(0, 0, 1.0, 1.0)
        else
            grip:SetPos(win.x + x + area.handleX, win.y + y + trackY)
            grip:SetSize(handleW, SIDEWAYS_BAR)
        end
    end
    activeBars[bar] = true
    -- The mouse wheel: down scrolls right, up scrolls left.
    view:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta) scrollTo(area.scrolled + (delta or 0) * step) end)
    -- Removes the grip (it lives outside the window).
    function area:remove()
        activeBars[bar] = nil
        grip:Destroy()
    end
    scrollTo(0)
    return area
end

-- One filter checkbox in the game's style, at x, y in parent, `w` wide.
local function filterCheck(parent, label, x, y, w, value)
    local check = ui.Check.new(parent)
    check.stylesheetID = id.StyleSheet.CHECKBOX_DEFAULT
    check.alignment = ui.CheckAlignMode.LEFT
    check.buttonSize = 16
    check.label = label
    check.text.font = widgets.SMALL_FONT
    check.value = value
    check:SetPos(x, y)
    check:SetSize(w, 20)
    return check
end

-- Whether a checkbox is ticked: read after a press, it may be true/false or 1/0.
local function isTicked(check)
    return check.value == true or check.value == 1
end

-- The panel of filter boxes the windows' Filter buttons open, in columns `columnWidth` wide.
-- `columns` lists each column's rows: { header = "Dig site" } or { key, label, indent = true }.
-- A heading followed by indented boxes is a box too: ticking or unticking it does the same to all
-- of them, and it's ticked only while all of them are. `unticked` is the set of keys the user has
-- unticked (changed in place); `onChange()` is called after any change. Returns the panel, hidden.
function widgets.filterPanel(parent, x, y, columnWidth, columns, unticked, onChange)
    local ROW = 20
    local most = 0
    for _, rows in ipairs(columns) do most = math.max(most, #rows) end
    local panel = ui.GroupBox.new(parent)
    panel.stylesheetID = id.StyleSheet.DEFAULT
    panel:SetHeaderLayout(0, 0, 0, 0, 0)
    panel:SetPos(x, y)
    panel:SetSize(#columns * columnWidth + 8, most * ROW + 10)
    panel.clickthrough = false
    for c, rows in ipairs(columns) do
        local cx = 8 + (c - 1) * columnWidth
        local group = nil   -- the heading box whose children are being laid out: { check, children }
        -- Whether every box under a heading is ticked.
        local function allTicked(g)
            for _, child in ipairs(g.children) do
                if unticked[child.key] then return false end
            end
            return true
        end
        for i, row in ipairs(rows) do
            local ry = 5 + (i - 1) * ROW
            local nextRow = rows[i + 1]
            if row.header and nextRow and nextRow.indent then
                -- A heading with boxes under it: a box that ticks or unticks them all.
                local g = { children = {} }
                for j = i + 1, #rows do
                    if not rows[j].indent then break end
                    table.insert(g.children, rows[j])
                end
                g.check = filterCheck(panel, row.header, cx, ry, columnWidth - 8, allTicked(g))
                g.check.text.colour = widgets.NAME
                g.check:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                    local on = isTicked(g.check)
                    for _, child in ipairs(g.children) do
                        unticked[child.key] = not on or nil
                        if child.check then child.check.value = on end
                    end
                    onChange()
                end)
                group = g
            elseif row.header then
                -- A heading on its own: just a label.
                local t = widgets.text(panel, row.header, widgets.NAME, widgets.SMALL_FONT)
                t:SetPos(cx, ry)
                t:SetSize(columnWidth - 8, ROW)
                t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
                group = nil
            else
                local indent = row.indent and 20 or 0
                local owner = row.indent and group or nil
                local check = filterCheck(panel, row.label, cx + indent, ry, columnWidth - 8 - indent, not unticked[row.key])
                row.check = check
                if not row.indent then group = nil end
                check:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
                    unticked[row.key] = not isTicked(check) or nil
                    if owner then owner.check.value = allTicked(owner) end
                    onChange()
                end)
            end
        end
    end
    panel.hidden = true
    return panel
end

-- Shortens text that's too long for a space `width` units wide, ending it with "..".
-- About 7.3 units per character of the small font (11 characters fit in 80 units).
function widgets.fit(text, width)
    local most = math.floor(width / 7.3)
    if #text <= most then return text end
    return (text:sub(1, math.max(1, most - 2)):gsub("%s+$", "")) .. ".."
end

return widgets
