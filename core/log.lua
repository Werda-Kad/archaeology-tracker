-- Test messages: printed to the console and saved, so they can be read as exact text
-- with tools/read_plugin_output.py. Off unless main.lua turns it on.

local log = { enabled = false, lines = {}, unsaved = false }
local MAX_LINES = 500  -- keep only the newest lines so the save doesn't grow forever

-- Prints a test message and keeps it for saving. Does nothing unless enabled.
function log.say(text)
    if not log.enabled then return end
    text = "[Tracker] " .. text
    print(text)
    table.insert(log.lines, text)
    if #log.lines > MAX_LINES then table.remove(log.lines, 1) end
    log.unsaved = true
end

-- Writes new messages to the plugin's save file.
function log.save()
    if not log.unsaved then return end
    PersistentDB:SetString("output", table.concat(log.lines, "\n"))
    log.unsaved = false
end

-- Keeps earlier messages across reloads, then saves new ones at most once per server tick (0.6 seconds).
function log.start()
    local earlier = PersistentDB:GetString("output")
    if earlier then
        for line in earlier:gmatch("[^\n]+") do table.insert(log.lines, line) end
        table.insert(log.lines, "--- reloaded ---")
    end
    Event.ServerLogic.Subscribe("trackerSaveLog", log.save)
end

return log
