-- Follows your research team's assignment: which research it's on, whether it's still out or
-- its report is ready to inspect, and how long is left.
-- The game saves the assignment and an out/ready flag (round 22-23 probes), but not the time
-- left. That's only shown in the research window ("Report ETA: 46m"), so it's read from there
-- whenever the window is open, and turned into the time it will be ready, using the real time
-- from core/clock.lua. That works across logging out. Without the real time (the chatAccess
-- permission not granted), it's counted down by game ticks while you're logged in, and after
-- logging back in is only an upper limit ("under 34m") until the window is opened again.

local catalog = require("core/catalog")
local storage = require("core/storage")
local progress = require("core/progress")
local clock = require("core/clock")

local team = {}

local WINDOW, WINDOW_PARTS = 693, 400   -- the research window (ARCH_RESEARCH_MANAGEMENT)
local TICKS_PER_MINUTE = 100             -- server ticks of 0.6 s

-- { research, readyAt = real time it's ready (if known), ticks = ticks left, exact = false if only an upper limit }
local left = nil
local character = nil   -- whose saved time is loaded
local listeners = {}    -- called when the status changes, e.g. to redraw a window
local lastStatus = nil  -- status text last told to listeners
local savedMinute = nil -- minutes left when last saved, so it's saved about once a minute

-- Calls listener() whenever the team's status changes.
function team.onChange(listener)
    table.insert(listeners, listener)
end

-- The assignment as the game saves it: research number (0 = none), and whether the team is out.
local function assignment()
    return progress.value("ARCH_RESEARCH_CONTRACT_1_RESEARCH_ID") or 0, progress.value("ARCH_RESEARCH_CONTRACT_1_ASYNCH_ID") == 1
end

-- Your team's status: state ("none", "out" or "ready"), the research's name, level, dig site and
-- kind (1 general, 2 special), and while out, the minutes left (nil if not seen yet) and whether
-- that's exact or only an upper limit.
function team.status()
    local number, out = assignment()
    if number == 0 then return { state = "none" } end
    local research = catalog.research[number] or {}
    local status = { state = out and "out" or "ready", name = research.name or "Research", site = research.site,
        kind = research.kind, level = progress.value("ARCH_RESEARCH_CONTRACT_1_RESEARCH_LEVEL") }
    if out and left and left.research == number then
        local now = clock.now()
        if left.readyAt and now then
            status.minutes, status.exact = math.max(0, math.ceil((left.readyAt - now) / 60)), true
        else
            status.minutes = math.max(0, math.ceil(left.ticks / TICKS_PER_MINUTE))
            status.exact = left.exact
        end
    end
    return status
end

-- "1h 20m" or "46m" as a number of minutes, or nil if it isn't a time.
local function minutesIn(text)
    local hours, minutes = text:match("(%d+)h"), text:match("(%d+)m")
    if not hours and not minutes then return nil end
    return (tonumber(hours) or 0) * 60 + (tonumber(minutes) or 0)
end

-- While the research window is open, reads "Report ETA: 46m" from it.
local function readWindow(number)
    local texts = progress.windowTexts(WINDOW, WINDOW_PARTS)
    if not texts then return end
    for _, text in ipairs(texts) do
        local eta = text:match("Report ETA:%s*(.+)")
        local minutes = eta and minutesIn(eta)
        if minutes then
            local now = clock.now()
            left = { research = number, ticks = minutes * TICKS_PER_MINUTE, exact = true, readyAt = now and (now + minutes * 60) }
            return
        end
    end
end

-- Saves the time left for this character, about once a minute.
local function save()
    if not character then return end
    local minute = left and math.ceil(left.ticks / TICKS_PER_MINUTE) or -1
    if minute == savedMinute then return end
    savedMinute = minute
    PersistentDB:SetStructuredData("researchTeam/" .. character,
        left and { research = left.research, ticks = left.ticks, readyAt = left.readyAt } or {})
end

-- Loads the logged-in character's saved time left. With the real time it's ready at, it's still
-- exact; otherwise it can only be an upper limit now, as time passed while logged out.
local function checkCharacter()
    local now = storage.currentCharacter()
    if now == character then return end
    character, left, savedMinute = now, nil, nil
    if not now then return end
    local saved = PersistentDB:GetStructuredData("researchTeam/" .. now) or {}
    if saved.research then
        left = { research = math.tointeger(saved.research) or saved.research, ticks = math.tointeger(saved.ticks) or saved.ticks or 0,
            readyAt = saved.readyAt, exact = false }
    end
end

-- Each tick: count the time down, read the window if it's open, and tell listeners of changes.
local function onTick()
    checkCharacter()
    local number, out = assignment()
    if not out or (left and left.research ~= number) then left = nil end   -- back, or a different research
    if left then left.ticks = math.max(0, left.ticks - 1) end
    if out then readWindow(number) end
    save()
    local status = team.status()
    local summary = status.state .. "|" .. tostring(status.minutes) .. "|" .. tostring(status.exact) .. "|" .. tostring(status.name)
    if summary ~= lastStatus then
        lastStatus = summary
        for _, listener in ipairs(listeners) do listener() end
    end
end

-- Starts following the team once the catalog has the research names.
function team.start()
    catalog.onReady(function()
        Event.ServerLogic.Subscribe("trackerResearchTeam", function() pcall(onTick) end)
    end)
end

return team
