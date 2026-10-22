-- The real date and time, for working out how long was spent logged out (e.g. how long your
-- research team has left). Plugins have no clock of their own; the only real time the game
-- gives them is the timestamp on chat messages (seconds since 1 January 1970), which needs the
-- chatAccess permission. Only the timestamp is used: messages themselves are never read or kept.
-- Between messages, the time is carried forward by the game's 0.6-second ticks.

local clock = {}

local TICK_SECONDS = 0.6
local known = nil   -- { seconds = the last chat timestamp, tick = the tick it arrived on }
local ticks = 0

-- The current time in seconds since 1970, or nil if no chat message has arrived yet (e.g. the
-- chatAccess permission wasn't granted).
function clock.now()
    if not known then return nil end
    return known.seconds + (ticks - known.tick) * TICK_SECONDS
end

-- Starts counting ticks and noting chat timestamps.
function clock.start()
    Event.ServerLogic.Subscribe("trackerClockTicks", function() ticks = ticks + 1 end)
    -- Every chat message (the login message is enough) brings the time; nothing else is taken from it.
    Event.ChatMessage.Subscribe("trackerClock", function(event)
        local seconds = tonumber(event.timestamp)
        if seconds and seconds > 0 then known = { seconds = seconds, tick = ticks } end
    end)
end

return clock
