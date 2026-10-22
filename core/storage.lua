-- Remembers what's in each archaeology-related storage, separately for each character.
-- Storages can only be read while open, so a copy is saved every time one opens or changes.

local log = require("core/log")

local storage = {}

-- Storages we track: game inventory id -> our name.
local TRACKED = {
    [93] = "backpack",
    [95] = "bank",
    [1008] = "artifactStorage",
    [885] = "materialStorage",
}
local BACKPACK = 93

local character = nil  -- display name of the logged-in character
local copies = {}      -- our name -> { items = { [itemId] = count }, estimated = true if adjusted by guesswork }
local unsaved = {}     -- our names with changes not yet written to the save file
local listeners = {}   -- functions called with (storage name, old items, new items) after each update

-- Where a storage copy is kept in the save file, e.g. "storage/<character>/bank".
local function saveKey(name)
    return "storage/" .. character .. "/" .. name
end

-- Reads every slot of an open storage and adds up each item.
local function readStorage(invId)
    local inv = Inventory.Find(invId)
    if not (inv and inv.isValid) then return nil end
    local items, names = {}, {}
    for _, slot in ipairs(inv:GetSlots() or {}) do
        if slot.obj and slot.count > 0 then
            items[slot.obj.id] = (items[slot.obj.id] or 0) + slot.count
            names[slot.obj.id] = slot.obj.name
        end
    end
    return items, names
end

local itemNames = {}  -- test log only: item id -> name, remembered so removed items still show a name

-- Test log only: lists what changed between the old and new copy, e.g. "Orgone 10 -> 15".
local function describeChanges(old, new, names)
    for id, name in pairs(names) do itemNames[id] = name end
    names = itemNames
    local changes = {}
    for id, count in pairs(new) do
        if old[id] ~= count then table.insert(changes, (names[id] or id) .. " " .. (old[id] or 0) .. " -> " .. count) end
    end
    for id, count in pairs(old) do
        if new[id] == nil then table.insert(changes, (names[id] or ("item " .. id)) .. " " .. count .. " -> 0") end
    end
    if #changes == 0 then return "no changes" end
    if #changes > 5 then return #changes .. " items changed" end
    return table.concat(changes, ", ")
end

-- The save file needs text keys, so item ids are saved as text and turned back into numbers on load.
-- Amounts come back as decimals (3.0), so they're turned back into whole numbers too.
local function toSaved(copy)
    local items = {}
    for id, count in pairs(copy.items) do items[tostring(id)] = count end
    return { items = items, estimated = copy.estimated }
end

-- Turns a saved copy back into the form used in memory (see toSaved).
local function fromSaved(saved)
    local items = {}
    for id, count in pairs(saved.items or {}) do items[tonumber(id)] = math.tointeger(count) or count end
    return { items = items, estimated = saved.estimated }
end

-- Writes changed copies to the save file.
function storage.save()
    if not character then return end
    for name in pairs(unsaved) do
        local ok = PersistentDB:SetStructuredData(saveKey(name), toSaved(copies[name]))
        -- Read it back too, in case the save file quietly refused it.
        if not ok or PersistentDB:GetStructuredData(saveKey(name)) == nil then
            log.say("Couldn't save " .. name)
        end
    end
    unsaved = {}
end

-- Re-reads an open storage, keeps the new copy, and tells listeners what changed.
local function update(invId)
    local name = TRACKED[invId]
    if not name or not character then return end
    local items, names = readStorage(invId)
    if not items then
        log.say(name .. " couldn't be read")
        return
    end
    local oldCopy = copies[name]
    local old = oldCopy and oldCopy.items or {}
    copies[name] = { items = items }
    unsaved[name] = true
    if log.enabled then
        log.say(name .. " updated: " .. describeChanges(old, items, names))
        -- After a guess (see restore.lua), the first real update shows whether the guess was right.
        if oldCopy and oldCopy.estimated then
            log.say(name .. " estimate check: " .. describeChanges(old, items, names):gsub("^no changes$", "matched"))
        end
    end
    for _, listener in ipairs(listeners) do listener(name, old, items) end
end

-- Calls listener(storage name, old items, new items) after every storage update.
function storage.onUpdate(listener)
    table.insert(listeners, listener)
end

-- Whether a storage is open right now (the game is sending its real contents).
function storage.isOpen(name)
    for invId, trackedName in pairs(TRACKED) do
        if trackedName == name then
            local inv = Inventory.Find(invId)
            return inv ~= nil and inv.isValid
        end
    end
    return false
end

-- Changes a closed storage's copy by guesswork, e.g. -10 Third Age iron after a restore.
-- Marked as estimated until the storage is next opened.
function storage.adjust(name, itemId, change)
    local copy = copies[name]
    if change == 0 or not copy or storage.isOpen(name) then return end
    local count = math.max(0, (copy.items[itemId] or 0) + change)
    copy.items[itemId] = count > 0 and count or nil
    copy.estimated = true
    unsaved[name] = true
    log.say(name .. " estimated: " .. (itemNames[itemId] or ("item " .. itemId)) .. " " .. change)
    for _, listener in ipairs(listeners) do listener(name, copy.items, copy.items) end
end

-- The logged-in character's display name, or nil.
function storage.currentCharacter()
    return character
end

-- The logged-in character's display name, or nil.
local function currentCharacter()
    if not Player.IsAvailable() then return nil end
    local me = Player.GetEntity()
    return me and me.displayName
end

-- Loads the logged-in character's saved copies. Also handles logging out or switching characters.
local function checkCharacter()
    local name = currentCharacter()
    if name == character then return end
    storage.save()
    character, copies, unsaved = name, {}, {}
    if not name then return end
    local remembered = {}
    for _, storageName in pairs(TRACKED) do
        local saved = PersistentDB:GetStructuredData(saveKey(storageName))
        if saved then
            copies[storageName] = fromSaved(saved)
            table.insert(remembered, storageName)
        end
    end
    log.say("Character " .. name .. ", remembered: " .. (#remembered > 0 and table.concat(remembered, ", ") or "nothing yet"))
    update(BACKPACK)  -- the backpack is always readable, so refresh it straight away
end

-- How many of an item the character has in each storage, plus the total.
-- Storages never seen open count as 0; check storage.isKnown to tell the difference.
function storage.count(itemId)
    local result = { total = 0 }
    for _, name in pairs(TRACKED) do
        local copy = copies[name]
        local n = copy and copy.items[itemId] or 0
        result[name] = n
        result.total = result.total + n
    end
    return result
end

-- Whether we have a copy of this storage (it has been opened at least once).
function storage.isKnown(name)
    return copies[name] ~= nil
end

-- Starts listening for storages opening and changing.
function storage.start()
    -- A storage opened or changed: make sure the character is known, then re-read it.
    local function onInventory(event)
        checkCharacter()
        update(event.inv.id)
    end
    Event.InventoryAdded.Subscribe("trackerInvAdded", onInventory)
    Event.InventoryUpdated.Subscribe("trackerInvUpdated", onInventory)
    Event.InventoryRemoved.Subscribe("trackerInvRemoved", function(event)
        if TRACKED[event.inv.id] then log.say(TRACKED[event.inv.id] .. " closed") end
    end)
    -- Every server tick (0.6 seconds): notice character changes and save anything new.
    Event.ServerLogic.Subscribe("trackerStorageTick", function()
        checkCharacter()
        storage.save()
    end)
    checkCharacter()
end

return storage
