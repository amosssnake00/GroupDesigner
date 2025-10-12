-- GroupDesigner Actor Script
-- This runs on ALL characters including the master
local mq = require('mq')
local actors = require('actors')
local Write = require('utils.Write')

local myName = mq.TLO.Me.Name()
local myActor = nil
local isRunning = true
local peerData = {}  -- Store peer data on master
local isMaster = false

Write.prefix = 'GroupDesignerActor'
Write.loglevel = 'info'  -- Default to info level

-- Get character data
local function getCharData()
    local function safe(fn, default)
        local success, result = pcall(fn)
        if success and result ~= nil and result ~= "NULL" and tostring(result) ~= "" then
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

-- Get group member info
local function getGroupMembers()
    local members = {}
    for i = 0, 5 do
        local success, result = pcall(function() return mq.TLO.Group.Member(i)() end)
        if success and result and result ~= "" and result ~= "NULL" then
            table.insert(members, tostring(result))
        end
    end
    return members
end

-- Message handler
local function messageHandler(message)
    if not message or not message.content then return end

    local content = message.content
    local sender = message.sender

    -- Log ALL messages for debugging
    Write.Debug(string.format("%s: Received message type=%s from=%s", myName, content.type or "nil", sender and sender.character or "unknown"))

    -- Handle data request from master (for peers)
    if content.type == "request_data" and not isMaster then
        -- Don't process our own messages for data requests
        if sender and sender.character == myName then
            return
        end
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

    -- Handle group query request (respond if we're the target, whether master or peer)
    elseif content.type == "query_group" and content.target then
        Write.Debug(string.format("%s: Received query_group message for target: %s (I am %s)", myName, content.target, isMaster and "MASTER" or "PEER"))
        if string.lower(content.target) == string.lower(myName) then
            Write.Debug(string.format("%s: Processing group query request for myself", myName))
            local members = getGroupMembers()
            Write.Debug(string.format("%s: Found %d group members", myName, #members))
            -- If we're the master querying ourselves, write directly to file
            if isMaster then
                Write.Debug(string.format("%s: I am master, writing to file directly", myName))
                local dataFile = mq.configDir .. "/GroupDesigner_group_" .. myName .. ".lua"
                local f = io.open(dataFile, "w")
                if f then
                    f:write("return {\n")
                    for _, member in ipairs(members) do
                        f:write(string.format("  '%s',\n", member))
                    end
                    f:write("}\n")
                    f:close()
                    Write.Debug(string.format("%s: Wrote group data to file", myName))
                end
            else
                -- If we're a peer, send back to the sender (ActorManager)
                Write.Debug(string.format("%s: I am peer, sending response back", myName))
                myActor:send(sender, {
                    type = "group_data",
                    character = myName,
                    members = members
                })
            end
        else
            Write.Debug(string.format("%s: Ignoring query for %s (not me)", myName, content.target))
        end

    -- Handle group data responses (for master from peers)
    elseif content.type == "group_data" and isMaster then
        -- Store group data in a file for the main script to read
        local dataFile = mq.configDir .. "/GroupDesigner_group_" .. content.character .. ".lua"
        local f = io.open(dataFile, "w")
        if f then
            f:write("return {\n")
            for _, member in ipairs(content.members) do
                f:write(string.format("  '%s',\n", member))
            end
            f:write("}\n")
            f:close()
        end

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

-- Auto-accept group invites
local function checkAndAcceptGroupInvite()
    local success, invited = pcall(function() return mq.TLO.Me.Invited() end)
    if success and invited then
        local inviter = mq.TLO.Me.Inviter() or "unknown"
        Write.Info(string.format("%s: Auto-accepting group invite from %s", myName, inviter))
        -- Use proper TLO to click the GroupWindow follow button
        local groupWindow = mq.TLO.Window("GroupWindow")
        if groupWindow and groupWindow.Child("GW_FollowButton") then
            groupWindow.Child("GW_FollowButton").LeftMouseDown()
            mq.delay(10)
            groupWindow.Child("GW_FollowButton").LeftMouseUp()
            Write.Debug(string.format("%s: Group invite accepted", myName))
            return true
        else
            Write.Warn(string.format("%s: GroupWindow or FollowButton not found", myName))
        end
    end
    return false
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

        -- Auto-accept group invites (master should also accept)
        checkAndAcceptGroupInvite()

        -- Request data every 10 seconds
        if now - lastRequest >= 10 then
            Write.Debug(string.format("%s: Broadcasting data request", myName))
            myActor:send({type = "request_data", from = myName})
            lastRequest = now
        end

        -- Report peer count every 15 seconds
        if now - lastReport >= 15 then
            local count = 0
            for _ in pairs(peerData) do
                count = count + 1
            end
            Write.Debug(string.format("%s (Master): Currently tracking %d peers", myName, count))
            lastReport = now
        end

        mq.delay(100)  -- Check more frequently for invites
    end
else
    Write.Debug("%s: Running as PEER", myName)

    -- Wait for requests and auto-accept invites
    while isRunning do
        checkAndAcceptGroupInvite()
        mq.delay(500)  -- Check twice per second for responsiveness
    end
end

-- Cleanup
if myActor then
    myActor:unregister()
end
Write.Debug("%s: Actor stopped", myName)