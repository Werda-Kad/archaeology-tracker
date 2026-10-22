-- The Overview window: a summary of your archaeology.
-- Top, in a darker box: your next guild qualification and, for each stat it asks for, where
-- you are against what it needs (e.g. "30 / 40"). Guildmasters just see their stats.
-- Then: your research team, as a card like the game's research window: out on research (with
-- the report ETA), report ready, or not out.
-- Middle: a small version of the Restoration Tracker, with a button to open the full one.
-- Bottom: buttons to the plugin's other windows.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local storage = require("core/storage")
local progress = require("core/progress")
local tracker = require("core/restoration_tracker")
local trackerWindow = require("windows/restoration_tracker_window")
local researchTeam = require("core/research_team")

local window = {}

local WIDTH = 560
local PAD = 10
local LINE = 20
local STAT_W, STAT_H = (WIDTH - 2 * PAD - 16) // 3, 46   -- one stat's cell, three to a row
local QUAL_H = 32 + 2 * STAT_H + 12                      -- the qualification box
local SQUARE_W, SQUARE_H, GAP = 80, 92, 6               -- one needed thing's square (as in the tracker)
local STRIP_H = SQUARE_H + 2 * 10 + 12 + 4                -- the row of squares in its frame, with its scrollbar
local CHECK_EVERY = 5                                    -- ticks between checks for changed stats (3 s)
-- The stats a qualification asks for, in display order, with their headings.
local STATS = { { "level", "Archaeology level" }, { "discovered", "Artifacts uncovered" },
    { "restored", "Artifacts restored" }, { "collections", "Collections completed" },
    { "mysteries", "Mysteries solved" }, { "researchHours", "Research hours" } }
-- The other windows, opened by the buttons at the bottom.
local WINDOWS = { { "Artifacts", "windows/artifacts_window" }, { "Collections", "windows/collections_window" },
    { "Materials", "windows/materials_window" }, { "Relic Powers", "windows/relic_powers_window" } }

local win, box, body = nil, nil, nil
local strip = nil       -- the tracker summary's sideways-scrolling row, removed on redraw
local lastState = nil   -- what the window last showed, to spot changes
local dirty = false
local ticks = 0

-- Text at a place in a part of the window.
local function text(parent, content, x, y, w, h, colour, font)
    local t = widgets.text(parent, content, colour, font or widgets.SMALL_FONT)
    t:SetPos(x, y)
    t:SetSize(w, h)
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    return t
end

-- Everything the qualification box shows, as text, to notice when it changes.
local function state()
    local parts = { tostring(progress.qualification()) }
    for _, stat in pairs(progress.qualificationStats()) do table.insert(parts, tostring(stat)) end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- The qualification box: your next qualification and each stat against what it needs.
local function qualificationBox(y)
    local panel = ui.Layer.new(body)
    panel:SetPos(PAD, y)
    panel:SetSize(WIDTH - 2 * PAD, QUAL_H)
    local background = widgets.box(panel, widgets.PANEL)
    background:SetSize(0, 0, 1.0, 1.0)
    local current = progress.qualification()
    local upcoming = catalog.qualifications[current + 1]   -- nil once you're Guildmaster
    local title = upcoming and ("Next qualification: " .. (upcoming.name or "?"))
        or ((catalog.qualifications[current] or {}).name or "Guildmaster")
    text(panel, title, 10, 4, WIDTH - 2 * PAD - 20, 24, widgets.TITLE, widgets.TITLE_FONT)
    local stats = progress.qualificationStats()
    local needs = upcoming and upcoming.needs or {}
    for i, stat in ipairs(STATS) do
        local col, row = (i - 1) % 3, (i - 1) // 3
        local x, top = 10 + col * (STAT_W + 4), 32 + row * STAT_H
        local have, need = stats[stat[1]] or 0, needs[stat[1]]
        text(panel, stat[2], x, top, STAT_W, 18, widgets.DIM)
        local value = need and (widgets.withCommas(have) .. " / " .. widgets.withCommas(need)) or widgets.withCommas(have)
        text(panel, value, x, top + 18, STAT_W, 22, need and (have >= need and widgets.ENOUGH or widgets.WHITE) or widgets.WHITE,
            widgets.BOLD_FONT)
    end
    -- Intern asks for no stats, only the tutorial: say what it asks for instead.
    if upcoming and upcoming.details and not upcoming.needs.level then
        text(panel, upcoming.details, 10, QUAL_H - 22, WIDTH - 2 * PAD - 20, 18, widgets.DIM)
    end
    return y + QUAL_H
end

-- "1h 20m" or "34m".
local function duration(minutes)
    if minutes >= 60 then return (minutes // 60) .. "h " .. (minutes % 60) .. "m" end
    return minutes .. "m"
end

-- The research card's images, as in the game's research window (round 25 probe).
local BANNERS = { ARCH_SITE_KHARIDET = 10291, ARCH_SITE_EVERLIGHT = 10289, ARCH_SITE_INFERNALSOURCE = 10290,
    ARCH_SITE_STORMGUARD = 10292, ARCH_SITE_WARFORGE = 10293, ARCH_SITE_ORTHEN = 12027, ARCH_SITE_SENNTISTEN = 15139,
    ARCH_SITE_DAEMONHEIM = 33842, ARCH_SITE_MOONRISE = 36062 }   -- ARCH_RESEARCH_SITE_BANNER_*: each site's picture and culture symbol
local GUILD_BANNER = 10288                    -- for research at no dig site
local GENERAL_OVERLAY, SPECIAL_OVERLAY = 10286, 10287   -- drawn over the banner for general / special research
local ARCHAEOLOGY_ICON = 10782                -- SKILL_ICON_ARCHAEOLOGY_25PX_0
local HOURGLASS = 14885
local CARD_W = WIDTH - 2 * PAD
local BANNER_H = math.floor((CARD_W - 16) * 90 / 385)   -- the banner's own shape (385 x 90), filling the card
local CARD_H = BANNER_H + 16

-- What the card's second line says: the time left, ready, or how to find out.
local function etaText(s)
    if s.state == "ready" then return "Report ready to inspect", widgets.ENOUGH end
    if s.minutes and s.exact then return "Report ETA: " .. duration(s.minutes), widgets.WHITE end
    -- Time passed while logged out isn't known without the real time, so this is only an upper limit.
    if s.minutes then return "Report ETA: under " .. duration(s.minutes) .. " (open the research window)", widgets.WHITE end
    return "Report ETA: open the research window to see it", widgets.WHITE
end

-- Your research team, as a card like the game's research window: the dig site's banner (with its
-- culture symbol at the bottom right) in a bevelled frame, the Archaeology symbol and level at
-- the bottom left to match it, and the research's name and report ETA along the bottom on a
-- dark strip so they read over the picture.
local function researchCard(y)
    text(body, "Research team", PAD, y, 300, LINE, widgets.GOLD, widgets.BOLD_FONT)
    y = y + LINE + 4
    local s = researchTeam.status()
    local card = widgets.bevelBox(body, PAD, y, CARD_W, CARD_H)
    local banner = ui.Sprite.new(card)
    banner.sprite = s.state == "none" and GUILD_BANNER or (BANNERS[s.site or ""] or GUILD_BANNER)
    banner:SetPos(8, 8)
    banner:SetSize(CARD_W - 16, BANNER_H)
    banner.clickthrough = true
    if s.state == "none" then banner.colour = Vector4.new(0.45, 0.45, 0.45, 1.0) end   -- dimmed: nothing on
    local overlay = ui.Sprite.new(card)
    overlay.sprite = s.kind == 2 and SPECIAL_OVERLAY or GENERAL_OVERLAY
    overlay:SetPos(8, 8)
    overlay:SetSize(CARD_W - 16, BANNER_H)
    overlay.clickthrough = true
    local bottom = 8 + BANNER_H   -- the banner's bottom edge
    if s.state ~= "none" then
        -- Bottom left: the Archaeology symbol, with the research's level under it.
        local icon = ui.Sprite.new(card)
        icon.sprite = ARCHAEOLOGY_ICON
        icon:SetPos(22, bottom - 54)
        icon:SetSize(30, 30)
        icon.clickthrough = true
        local levelBack = widgets.box(card, widgets.PANEL)
        levelBack:SetPos(14, bottom - 24)
        levelBack:SetSize(46, 18)
        local level = text(card, "Lvl " .. tostring(s.level or "?"), 14, bottom - 24, 46, 18, widgets.WHITE)
        level:AlignTo(ui.AlignMode.CENTRE)
    end
    -- Along the bottom beside it: the name and the report ETA on a dark strip.
    local stripX, stripW, stripY = 70, CARD_W - 70 - 80, bottom - 58
    local strip = widgets.box(card, Vector4.new(0.0, 0.0, 0.0, 0.65))
    strip:SetPos(stripX, stripY)
    strip:SetSize(stripW, 52)
    text(card, widgets.fit(s.state == "none" and "Not out on research" or s.name, stripW - 16), stripX + 8, stripY + 2, stripW - 16, 22,
        widgets.NAME, widgets.BOLD_FONT)
    if s.state ~= "none" then
        local wait, colour = etaText(s)
        if s.state ~= "ready" then
            local hourglass = ui.Sprite.new(card)
            hourglass.sprite = HOURGLASS
            hourglass:SetPos(stripX + 6, stripY + 27)
            hourglass:SetSize(20, 20)
            hourglass.clickthrough = true
        end
        local x = s.state == "ready" and stripX + 8 or stripX + 30
        text(card, widgets.fit(wait, stripW - (x - stripX) - 8), x, stripY + 26, stripW - (x - stripX) - 8, 22, colour)
    end
    return y + CARD_H
end

-- The small Restoration Tracker: what's tracked, then everything it needs in a row that scrolls
-- sideways (the things still short first), and a button to open the full tracker.
local function trackerSummary(y)
    text(body, "Restoration Tracker", PAD, y, 300, LINE, widgets.GOLD, widgets.BOLD_FONT)
    local open = widgets.button(body, "Open", function() trackerWindow.open() end)
    open:SetPos(-PAD - 90, y - 2, 1.0, 0)
    open:SetSize(90, 24)
    y = y + LINE + 6
    local entries = tracker.entries()
    if #entries == 0 then
        text(body, "Nothing tracked yet. Use \"Add to tracker\" in an artifact or collection window.", PAD, y,
            WIDTH - 2 * PAD, LINE, widgets.DIM)
        return y + SQUARE_H
    end
    local _, damaged, materials = trackerWindow.needsLists()
    -- Things still short come first, so the most useful ones show in this small space.
    local short = {}
    for _, list in ipairs({ damaged, materials }) do
        for _, s in ipairs(list) do
            if s.owned < s.needed then table.insert(short, s) end
        end
    end
    local summary = #entries .. (#entries == 1 and " goal tracked" or " goals tracked") .. ", "
        .. (#short == 0 and "you have everything needed" or (#short .. " things still needed"))
    text(body, summary, PAD, y, WIDTH - 2 * PAD, LINE, #short == 0 and widgets.ENOUGH or widgets.WHITE)
    y = y + LINE + 4
    -- Every needed thing in one row that scrolls sideways: the ones still short first, then the
    -- ones you already have enough of.
    local row = {}
    for _, s in ipairs(short) do table.insert(row, s) end
    for _, list in ipairs({ damaged, materials }) do
        for _, s in ipairs(list) do
            if s.owned >= s.needed then table.insert(row, s) end
        end
    end
    local step = SQUARE_W + GAP
    strip = widgets.scrollAreaSideways(win, body, PAD, y, WIDTH - 2 * PAD, STRIP_H, #row * step - GAP, step)
    for i, s in ipairs(row) do
        trackerWindow.needSquare(strip.content, s.name, s.itemId, s.owned, s.needed, s.open, (i - 1) * step, 0)
    end
    return y + STRIP_H
end

-- The buttons to the plugin's other windows.
local function windowButtons(y)
    for i, entry in ipairs(WINDOWS) do
        local b = widgets.button(body, entry[1], function() require(entry[2]).open() end)
        b:SetPos(PAD + (i - 1) % 2 * ((WIDTH - 2 * PAD) // 2 + 4), y + (i - 1) // 2 * 32)
        b:SetSize((WIDTH - 2 * PAD) // 2 - 4, 28)
    end
    return y + math.ceil(#WINDOWS / 2) * 32
end

-- Builds (or rebuilds) everything inside the window, in one layer that lets clicks through to
-- the header (so it can still be dragged).
local function draw()
    if strip then strip:remove() end
    strip = nil
    if body then body:Destroy() end
    body = ui.Layer.new(box)
    body:SetSize(0, 0, 1.0, 1.0)
    body.clickthrough = true
    lastState = state()
    local y = qualificationBox(widgets.HEADER_HEIGHT + 8)
    y = researchCard(y + 14)
    y = trackerSummary(y + 14)
    windowButtons(y + 14)
end

-- Closes the window.
function window.close()
    if strip then strip:remove() end
    strip = nil
    widgets.destroyWindow(box)
    win, box, body = nil, nil, nil
end

-- Opens the window, or does nothing if it's already open.
function window.open()
    if box then return end
    local height = widgets.HEADER_HEIGHT + 8 + QUAL_H + 14 + LINE + 4 + CARD_H + 14 + LINE + 6 + LINE + 4 + STRIP_H + 14
        + math.ceil(#WINDOWS / 2) * 32 + PAD
    win = widgets.window("overview", "Archaeology Overview", WIDTH, height, window.close)
    box = win.box
    draw()
end

-- Whether the window is open.
function window.isOpen()
    return box ~= nil
end

-- Redraws when the tracker, your research team or your storages change, and every few ticks if your stats changed.
function window.start()
    tracker.onChange(function() dirty = true end)
    -- The team's status changes about once a minute at most, so redraw straight away.
    researchTeam.onChange(function() if box then draw() end end)
    storage.onUpdate(function() dirty = true end)
    Event.ServerLogic.Subscribe("trackerOverviewRedraw", function()
        ticks = ticks + 1
        if box and (dirty or (ticks % CHECK_EVERY == 0 and state() ~= lastState)) then draw() end
        dirty = false
    end)
end

return window
