-- GroupDesigner Actor Script
-- This runs on ALL characters including the master
local mq = require('mq')
local actors = require('actors')
local Write = require('utils.Write')
local Common = require('utils.common')

local myName = mq.TLO.Me.Name()
local myActor = nil
local isRunning = true
local peerData = {}  -- Store peer data on master
local isMaster = false

-- Get character data
local function getCharData()
    local function safe(fn, default)
        local success, result = pcall(fn)
        if success and Common.isSafeString(result) then
            return tostring(result)
        end
        return default or "---"
    end
    
    return {
        name = safe(function() return mq.TLO.Me.Name() end, "Unknown"),
        class = safe(function() return mq.TLO.Me.Class.ShortName() end),
        level = safe(function() return mq.TLO.Me.Level() end),
        ac = safe(function() return mq.TLO.Window("InventoryWindow").Child("IW_ACNumber").Text() end),
        maxhp = safe(function() return mq.TLO.Me.MaxHPs() end),
        maxmana = safe(function() return mq.TLO.Me.MaxMana() end),
        maxendurance = safe(function() return mq.TLO.Me.MaxEndurance() end),
        zone = safe(function() return mq.TLO.Zone.ShortName() end)
    }
end

-- Message handler
local function messageHandler(message)
    if not message or not message.content then return end
    
    local content = message.content
    local sender = message.sender
    
    -- Don't process our own messages
    if sender and sender.character == myName then
        return
    end
    
    -- Handle data request from master (for peers)
    if content.type == "request_data" and not isMaster then
        --Write.Debug("%s: Received data request from %s", myName, sender.character or "unknown")
        local data = getCharData()
        -- Reply with our data
        myActor:send(sender, {
            type = "peer_data",
            name = data.name,
            class = data.class,
            level = data.level,
            ac = data.ac,
            maxhp = data.maxhp,
            maxmana = data.maxmana,
            maxendurance = data.maxendurance,
            zone = data.zone
        })
        --Write.Debug("%s: Sent data reply to %s", myName, sender.character)
    
    -- Handle peer data responses (for master)
    elseif content.type == "peer_data" and isMaster then
        --Write.Debug("%s: Received data reply", myName)
        -- Extract peer data from the response
        if content.name then
            --Write.Debug("%s (Master): Received peer data from %s", myName, content.name)
            peerData[content.name] = {
                name = content.name,
                class = content.class or "---",
                level = content.level or "---",
                ac = content.ac or "---",
                maxhp = content.maxhp or "---",
                maxmana = content.maxmana or "---",
                maxendurance = content.maxendurance or "---",
                zone = content.zone or "---"
            }
            
            -- Write peer data to a file that main script can read
            local dataFile = mq.configDir .. "/GroupDesigner_peers.lua"
            local f = io.open(dataFile, "w")
            if f then
                f:write("return {\n")
                for name, data in pairs(peerData) do
                    f:write(string.format("  ['%s'] = {\n", name))
                    f:write(string.format("    name = '%s',\n", data.name))
                    f:write(string.format("    class = '%s',\n", data.class))
                    f:write(string.format("    level = '%s',\n", data.level))
                    f:write(string.format("    ac = '%s',\n", data.ac))
                    f:write(string.format("    maxhp = '%s',\n", data.maxhp))
                    f:write(string.format("    maxmana = '%s',\n", data.maxmana))
                    f:write(string.format("    maxendurance = '%s',\n", data.maxendurance))
                    f:write(string.format("    zone = '%s'\n", data.zone))
                    f:write("  },\n")
                end
                f:write("}\n")
                f:close()
            end
        end
        
    elseif content.type == "shutdown" then
        Write.Info("%s: Shutdown requested", myName)
        isRunning = false
    end
end

-- Main
Write.Debug("GroupDesigner actor starting on %s", myName)

-- Register actor
myActor = actors.register(messageHandler)
if not myActor then
    Write.Error("%s: Failed to register actor", myName)
    return
end

Write.Debug("%s: Actor registered successfully", myName)

-- Check if we're the master (first argument)
local args = {...}
if args[1] == "master" then
    isMaster = true
    Write.Debug("%s: Running as MASTER", myName)
    
    -- Add master's own data to peerData
    local myData = getCharData()
    peerData[myName] = {
        name = myData.name,
        class = myData.class,
        level = myData.level,
        ac = myData.ac,
        maxhp = myData.maxhp,
        maxmana = myData.maxmana,
        maxendurance = myData.maxendurance,
        zone = myData.zone
    }
    Write.Debug("%s: Added self to peer list", myName)
    
    -- Wait for other actors to start
    mq.delay(3000)
    
    -- Periodically request data and report status
    local lastRequest = 0
    local lastReport = 0
    while isRunning do
        local now = os.time()
        
        -- Request data every 10 seconds
        if now - lastRequest >= 10 then
            Write.Debug("%s: Broadcasting data request", myName)
            myActor:send({type = "request_data", from = myName})
            lastRequest = now
        end
        
        -- Report peer count every 15 seconds
        if now - lastReport >= 15 then
            local count = 0
            for _ in pairs(peerData) do
                count = count + 1
            end
            Write.Debug("%s (Master): Currently tracking %d peers", myName, count)
            lastReport = now
        end
        
        mq.delay(1000)
    end
else
    Write.Debug("%s: Running as PEER", myName)
    
    -- Just wait for requests
    while isRunning do
        mq.delay(1000)
    end
end

-- Cleanup
if myActor then
    myActor:unregister()
end
Write.Debug("%s: Actor stopped", myName)