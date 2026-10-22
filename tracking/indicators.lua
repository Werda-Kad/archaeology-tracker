-- The tracking arrows:
-- 1. a yellow arrow standing over the destination, with a gold frame around its tiles on the ground.
--    These are 3D shapes in the game world, so the game keeps them exactly in place;
-- 2. an arrow at the edge of the screen pointing towards it, with the distance in tiles,
--    when it's off screen (or behind the camera);
-- 3. a small arrow at the edge of the minimap pointing towards it.
-- 2 and 3 are game images (numbers from `pan Sprite`), placed on screen every frame.

local widgets = require("ui/widgets")

local indicators = {}

-- Images (sprite numbers) and which way each one points with no rotation, in degrees
-- clockwise from straight up, as seen in the round 13 probe's gallery.
local EDGE_IMAGE, EDGE_POINTS = 11, 180       -- HINT_HEADICONS: the game's yellow arrow, points down
local MINIMAP_IMAGE, MINIMAP_POINTS = 14, 0   -- HINT_MAPEDGE: the game's minimap-edge arrow, points up

-- The image rotation that makes an image pointing `points` point at `angle` (both clockwise
-- from up). The game turns images anticlockwise for positive degrees (round 13 probe).
local function turn(points, angle)
    return points - angle
end
local MARKER_HEIGHT = 500       -- how far above the ground the arrow's tip floats, in world units
-- The arrow's colours: shapes aren't lit by the game, so light and shade are painted on.
local LIGHT, GOLD, AMBER, EDGE = 0xFFE680FF, 0xFFCC00FF, 0xD99A00FF, 0x4D3300FF
-- The frame on the ground: how far in from the area's edge, how wide its band, its rim colour.
local FRAME_INSET, FRAME_BAND, FRAME_RIM = 0, 40, 0x4D330099
local frameSize = "512x512"   -- the size the frame was last built for
local EDGE_MARGIN = 60          -- how far in from the screen edge the edge arrow sits
local MINIMAP_ID = 96010240     -- TOPLEVEL_V2_MINIMAP__MINIMAP (from `pan Component`)

local marker, outline = nil, nil   -- the 3D arrow and tile outline
local edge, edgeText, minimapArrow = nil, nil, nil
local minimap = nil
local time = 0

-- One image on the screen layer, hidden until placed.
local function image(parent, spriteId, w, h)
    local s = ui.Sprite.new(parent)
    s.sprite = spriteId
    s:SetSize(w, h)
    s.clickthrough = true
    s.hidden = true
    return s
end

-- The mouse and screen positions are pixels; components use interface units.
local function scale()
    local ok, s = pcall(function() return game.options.InterfaceScale.setting / 100 end)
    return (ok and s and s > 0) and s or 1
end

-- Which way the camera faces along the ground, as a unit vector (x, z).
local function cameraFacing()
    local from, to = Camera.GetPosition(), Camera.GetFocusPosition()
    local dx, dz = to.x - from.x, to.z - from.z
    local length = math.sqrt(dx * dx + dz * dz)
    if length == 0 then return 0, 1 end
    return dx / length, dz / length
end

-- The direction from you to a world position as seen on screen: degrees clockwise from
-- straight up (up on screen = the way the camera faces). The minimap turns with the camera,
-- so the same angle works there.
local function screenAngle(me, target)
    local fx, fz = cameraFacing()
    local dx, dz = target.x - me.x, target.z - me.z
    local right = dx * fz - dz * fx   -- along the screen's right
    local ahead = dx * fx + dz * fz   -- along the screen's up
    return math.deg(math.atan(right, ahead)), ahead
end

-- A flat chevron arrowhead pointing down, its tip at 0,0,0, with a notch cut in its top.
-- Bright at the tip, fading to amber at the wings, with a dark edge.
local function arrowShape()
    local tip, left, notch, right = Vector3.new(0, 0, 0), Vector3.new(-170, 230, 0),
        Vector3.new(0, 140, 0), Vector3.new(170, 230, 0)
    local shape = ShapeData.new()
    -- Points 0-3 fill the shape; 4-7 are the same corners again, dark, for the edge.
    shape.positions = { tip, left, notch, right, tip, left, notch, right }
    shape.rgba = { LIGHT, AMBER, GOLD, AMBER, EDGE, EDGE, EDGE, EDGE }
    shape.tris = { 0, 1, 2, 0, 2, 3 }
    shape.lines = { 4, 5, 5, 6, 6, 7, 7, 4 }
    return shape
end

-- A flat gold frame lying on the ground, centred on 0,0,0, just inside the edges of an area
-- width x length (world units), like the game's click-to-walk marker. Its band is pale down the
-- middle and gold at the sides, so it looks rounded, with a faint dark rim either side.
local function frameShape(width, length)
    local positions, rgba, tris, lines = {}, {}, {}, {}
    -- One ring of four corners, `inset` in from the area's edges, in a colour. Returns their numbers.
    local function ring(inset, colour)
        local hw, hl, first = width / 2 - inset, length / 2 - inset, #positions
        for _, c in ipairs({ { -hw, -hl }, { hw, -hl }, { hw, hl }, { -hw, hl } }) do
            table.insert(positions, Vector3.new(c[1], 0, c[2]))
            table.insert(rgba, colour)
        end
        return { first, first + 1, first + 2, first + 3 }
    end
    -- Fills the band between two rings, seen from either side.
    local function band(a, b)
        for i = 1, 4 do
            local j = i % 4 + 1
            for _, n in ipairs({ a[i], a[j], b[j], a[i], b[j], b[i], a[i], b[j], a[j], a[i], b[i], b[j] }) do
                table.insert(tris, n)
            end
        end
    end
    -- Draws a dark line around a ring.
    local function rim(r)
        for i = 1, 4 do
            table.insert(lines, r[i])
            table.insert(lines, r[i % 4 + 1])
        end
    end
    local outer, middle, inner = ring(FRAME_INSET, GOLD), ring(FRAME_INSET + FRAME_BAND / 2, LIGHT), ring(FRAME_INSET + FRAME_BAND, GOLD)
    band(outer, middle)
    band(middle, inner)
    rim(ring(FRAME_INSET, FRAME_RIM))
    rim(ring(FRAME_INSET + FRAME_BAND, FRAME_RIM))
    local shape = ShapeData.new()
    shape.positions, shape.rgba, shape.tris, shape.lines = positions, rgba, tris, lines
    return shape
end

-- A 3D shape in the world, hidden until placed.
local function shapeInstance(name, data, colour)
    local instance = ShapeList.CreateInstance(name)
    instance:SetShapeData(data)
    instance.colour = 0xFFFFFFFF
    instance.lineWidth = 3
    instance.visible = false
    if colour then instance.colour = colour end
    return instance
end

-- Creates the shapes and images. The minimap arrow goes inside the game's minimap, if it can.
function indicators.start()
    marker = shapeInstance("trackerMarker", arrowShape())
    marker.asBillboard = true    -- always faces the camera
    marker.ignoreDepth = true    -- stays visible through walls and scenery
    marker.lineWidth = 3
    outline = shapeInstance("trackerOutline", frameShape(512, 512))
    outline.ignoreDepth = true   -- not hidden by bumps in the ground
    outline.lineWidth = 1
    local screen = widgets.gameWindow()
    edge = image(screen, EDGE_IMAGE, 40, 32)
    edgeText = widgets.text(screen, "", widgets.GOLD, widgets.BOLD_FONT)
    edgeText:SetSize(100, 24)
    edgeText.hidden = true
    -- The minimap may not be able to hold our image; then there's just no minimap arrow.
    local ok, found = pcall(function() return ui.Interfaces:GetComponent(MINIMAP_ID) end)
    minimap = ok and found or nil
    if minimap and not pcall(function() minimapArrow = image(minimap, MINIMAP_IMAGE, 18, 18) end) then
        minimapArrow = nil
    end
end

-- Hides everything (nothing being tracked).
function indicators.hide()
    for _, c in ipairs({ edge, edgeText, minimapArrow }) do
        if c then c.hidden = true end
    end
    if marker then marker.visible, outline.visible = false, false end
end

-- Places all three for this frame. me: your PlayerEntity. aim: the destination's centre at
-- ground height (the hotspot, or the entrance on the way). width, length: its size in world
-- units, for the outline. tiles: distance to show. seconds: frame time.
function indicators.show(me, aim, width, length, tiles, seconds)
    time = time + (seconds or 0)
    local s = scale()
    local screen = widgets.gameWindow()
    local w, h = screen.width or 1000, screen.height or 700
    local angle, ahead = screenAngle(me.position, aim)

    -- 1. The arrow over the destination (gently bobbing) and its tiles outlined, always drawn;
    --    the game places them, so they're exact. Off screen they're simply not seen.
    marker.translation = aim + Vector3.new(0, MARKER_HEIGHT + math.sin(time * 3) * 40, 0)
    outline.translation = aim + Vector3.new(0, 15, 0)
    -- Rebuilt only when the size changes, so the band stays the same width on bigger hotspots.
    if frameSize ~= width .. "x" .. length then
        outline:SetShapeData(frameShape(width, length))
        frameSize = width .. "x" .. length
    end
    marker.visible, outline.visible = true, true

    -- Is the arrow on screen? (Its middle, in front of the camera and inside the screen.)
    local spot = ScreenConvert.Vector3ToScreen(aim + Vector3.new(0, MARKER_HEIGHT + 260, 0))
    local onScreen = false
    if spot and ahead > 0 then
        local x, y = spot.x / s, spot.y / s
        onScreen = x >= 0 and x <= w and y >= 0 and y <= h
    end

    -- 2. The edge arrow, pointing the way, with the distance, when the destination is off screen.
    edge.hidden, edgeText.hidden = onScreen, onScreen
    if not onScreen then
        local r = math.rad(angle)
        local rx, ry = w / 2 - EDGE_MARGIN, h / 2 - EDGE_MARGIN
        -- Push out from the centre until the arrow meets the edge of the screen (minus a margin).
        local sx, sy = math.sin(r), -math.cos(r)
        local reach = math.min(rx / math.max(math.abs(sx), 0.001), ry / math.max(math.abs(sy), 0.001))
        local x, y = w / 2 + sx * reach, h / 2 + sy * reach
        edge:SetPos(math.floor(x) - 20, math.floor(y) - 16)
        edge.rotationDegrees = turn(EDGE_POINTS, angle)
        edgeText.content = tiles .. " tiles"
        edgeText:SetPos(math.floor(x) + (sx > 0 and -130 or 26), math.floor(y) - 12)
    end

    -- 3. The minimap arrow, near the minimap's edge in the same direction.
    if minimapArrow then
        local mw, mh = minimap.width or 200, minimap.height or 200
        local r = math.rad(angle)
        local x = mw / 2 + math.sin(r) * (mw / 2 - 16)
        local y = mh / 2 - math.cos(r) * (mh / 2 - 16)
        minimapArrow:SetPos(math.floor(x) - 9, math.floor(y) - 9)
        minimapArrow.rotationDegrees = turn(MINIMAP_POINTS, angle)
        minimapArrow.hidden = false
    end
end

return indicators
