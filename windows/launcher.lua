-- The tracker's menu inside the game's Plugins window. "hasRibbonIcon" in plugin.json gives
-- the tracker an icon there; clicking it gives us an empty area to fill with our buttons.

local widgets = require("ui/widgets")
local catalog = require("core/catalog")
local artifactsWindow = require("windows/artifacts_window")
local artifactDetail = require("windows/artifact_detail")
local collectionsWindow = require("windows/collections_window")
local collectionDetail = require("windows/collection_detail")
local materialsWindow = require("windows/materials_window")
local materialDetail = require("windows/material_detail")
local hotspotDetail = require("windows/hotspot_detail")
local relicPowersWindow = require("windows/relic_powers_window")
local relicPowerDetail = require("windows/relic_power_detail")
local relicDetail = require("windows/relic_detail")
local restoreTrackerWindow = require("windows/restoration_tracker_window")
local overviewWindow = require("windows/overview_window")
local pinnedNeeds = require("windows/pinned_needs_window")
local log = require("core/log")

local launcher = {}

local area = nil   -- the area in the Plugins window, while it's showing
local buttons = {}

-- Windows in the menu. Ones without an open function aren't built yet.
local WINDOWS = {
    { label = "Overview", open = overviewWindow.open },
    { label = "Artifacts", open = artifactsWindow.open },
    { label = "Collections", open = collectionsWindow.open },
    { label = "Materials", open = materialsWindow.open },
    { label = "Relic Powers", open = relicPowersWindow.open },
    { label = "Restoration Tracker", open = restoreTrackerWindow.open },
}

-- Fills the area with one button per window. Disabled until the catalog is ready.
local function buildMenu()
    if not area then return end
    for _, old in ipairs(buttons) do pcall(old.Destroy, old) end
    buttons = {}
    for i, entry in ipairs(WINDOWS) do
        local label = entry.open and entry.label or (entry.label .. " (soon)")
        if entry.open and not catalog.ready then label = entry.label .. " (loading)" end
        local b = widgets.button(area, label, function()
            local ok, err = pcall(entry.open)
            if not ok then log.say("Couldn't open " .. entry.label .. ": " .. tostring(err)) end
        end)
        b:SetPos(4, 4 + (i - 1) * 32)
        b:SetSize(-8, 28, 1.0, 0)
        b.enabled = entry.open ~= nil and catalog.ready
        table.insert(buttons, b)
    end
end

-- Shows the menu in an area the Plugins window gave us. Errors go to the test log.
local function useArea(component)
    area, buttons = component, {}  -- the game empties it just before this event
    local ok, err = pcall(buildMenu)
    if not ok then log.say("Couldn't build the menu: " .. tostring(err)) end
end

-- Listens for the Plugins window asking for our menu.
function launcher.start()
    Event.ContentLayerReady.Subscribe("trackerContentLayer", function(event) useArea(event.component) end)
    -- If the menu was shown while loading, rebuild it with the buttons enabled.
    catalog.onReady(function()
        if area then
            local ok = pcall(buildMenu)
            if not ok then area = nil end  -- the Plugins window was closed meanwhile
        end
    end)
end

-- Closes any open window (used when the plugin stops).
function launcher.remove()
    artifactsWindow.close()
    artifactDetail.close()
    collectionsWindow.close()
    collectionDetail.close()
    materialsWindow.close()
    materialDetail.close()
    hotspotDetail.close()
    relicPowersWindow.close()
    relicPowerDetail.close()
    relicDetail.close()
    overviewWindow.close()
    pinnedNeeds.closeAll()
    restoreTrackerWindow.close()
end

return launcher
