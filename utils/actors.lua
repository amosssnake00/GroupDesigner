-- MVP Actor System for GroupDesigner
local mq = require('mq')
local actors = require('actors')
local Write = require('utils.Write')
local Common = require('utils.common')

local ActorManager = {}

-- State
local masterActor = nil
local isEnabled = false
local initFailed = false
local peerData = {}
local masterScriptPID = nil

-- Message handler for master's inbox
local function messageHandler(message)
    if not message or not message.content then return end

    local content = message.content
    local sender = message.sender

    Write.Debug(string.format("ActorManager: Received message type=%s", content.type or "nil"))

    -- Handle peer data responses
    if content.type == "peer_data" and content.name then
        Write.Debug(string.format("ActorManager: Received peer data from %s", content.name))
        peerData[content.name] = {
            name = content.name,
            class = content.class or "---",
            level = content.level or "---",
            maxhp = content.maxhp or "---",
            maxmana = content.maxmana or "---",
            maxendurance = content.maxendurance or "---",
            zone = content.zone or "---",
            loading = false,
            fromActor = true
        }
    -- Handle group data responses
    elseif content.type == "group_data" and content.character and content.members then
        Write.Debug(string.format("ActorManager: Received group data from %s with %d members", content.character, #content.members))
        -- Store temporarily with a special key for queryGroupMembers to find
        peerData["group_" .. content.character] = content.members
    end
end

-- Initialize system
function ActorManager.init(config)
    Write.Debug("ActorManager: Initializing MVP system...")
    
    -- Register master's inbox actor
    masterActor = actors.register(messageHandler)
    if not masterActor then
        Write.Error("ActorManager: Failed to register master inbox")
        initFailed = true
        return false
    end
    
    isEnabled = true
    initFailed = false
    Write.Debug("ActorManager: Master inbox registered")
    
    -- Deploy actor script to all characters including self
    ActorManager.deployActors()
    
    return true
end

function ActorManager.deployActors()
    if not isEnabled then return end
    
    -- Stop any existing actor scripts on all peers
    local dannetPeers = nil
    local success, result = pcall(function() return mq.TLO.DanNet.Peers() end)
    if success and Common.isSafeString(result) then
        dannetPeers = result
    end
    
    local localName = mq.TLO.Me.Name()
    local peerList = {}
    
    -- Collect all peers
    if dannetPeers then
        for peer in string.gmatch(dannetPeers, "([^|]+)") do
            if Common.isSafeString(peer) then
                table.insert(peerList, peer)
                -- Stop any existing actor script
                mq.cmdf('/squelch /dex %s /lua stop GroupDesigner/groupdesigner_actors', peer)
            end
        end
    end
    
    Write.Debug("ActorManager: Stopping existing actors on %d peers", #peerList)
    mq.delay(2000)
    
    -- Start the SAME actor script on ALL peers (not master)
    local deployed = 0
    for _, peer in ipairs(peerList) do
        if not (localName and string.lower(peer) == string.lower(localName)) then
            mq.cmdf('/squelch /dex %s /lua run GroupDesigner/groupdesigner_actors', peer)
            deployed = deployed + 1
        end
    end
    
    -- Also start the master instance locally
    Write.Debug("ActorManager: Starting master actor script locally")
    mq.cmd('/squelch /lua run GroupDesigner/groupdesigner_actors master')
    
    Write.Debug("ActorManager: Started actors - 1 master (local) and %d peers", deployed)
    
    -- The master script will handle broadcasting after initialization
    isEnabled = true
    
    -- Don't block - let UI start immediately
    Write.Debug("ActorManager: Actor scripts deployed, data will be available shortly...")
end

function ActorManager.getPeerData()
    if not isEnabled then
        -- Fallback to basic DanNet peer list
        local peers = {}
        local dannetPeers = nil
        local success, result = pcall(function() return mq.TLO.DanNet.Peers() end)
        if success and Common.isSafeString(result) then
            for peer in string.gmatch(result, "([^|]+)") do
                if Common.isSafeString(peer) then
                    table.insert(peers, {
                        name = peer,
                        class = "---",
                        level = "---", 
                        maxhp = "---",
                        maxmana = "---",
                        maxendurance = "---",
                        zone = "---",
                        loading = true
                    })
                end
            end
        end
        return peers
    end
    
    -- Read peer data from file written by master actor
    local dataFile = mq.configDir .. "/GroupDesigner_peers.lua"
    local loadedData = {}
    local f = io.open(dataFile, "r")
    if f then
        f:close()
        local chunk, err = loadfile(dataFile)
        if chunk then
            local success, data = pcall(chunk)
            if success and data then
                loadedData = data
            end
        end
    end
    
    -- Convert to array and add loading flag
    local peers = {}
    for _, data in pairs(loadedData) do
        data.loading = false
        data.fromActor = true
        table.insert(peers, data)
    end
    
    local count = #peers
    if count > 0 then
        Write.Debug("ActorManager.getPeerData: Returning %d peers from actor data file", count)
    end
    return peers
end

function ActorManager.isEnabled()
    return isEnabled
end

function ActorManager.hasFailed()
    return initFailed
end

function ActorManager.update()
    -- Nothing needed for MVP
end

function ActorManager.requestPeerData()
    -- The master actor script handles broadcasting, not this manager
    Write.Debug("ActorManager: Data requests are handled by the master actor script")
    return false
end

-- Query group members from a specific character via actors
function ActorManager.queryGroupMembers(characterName, timeout)
    if not isEnabled or not masterActor then
        Write.Error("ActorManager: Cannot query group - actor system not active")
        return nil
    end

    timeout = timeout or 2000  -- Default 2 second timeout

    -- Send query to the actor script using proper mailbox addressing
    Write.Debug(string.format("ActorManager: Sending query_group for %s", characterName))
    -- Send to the actor script mailbox on all characters
    masterActor:send(
        {script = "GroupDesigner/groupdesigner_actors"},
        {type = "query_group", target = characterName}
    )

    -- Wait for response in the message handler (peerData table will be updated)
    local elapsed = 0
    local checkInterval = 100
    local responseKey = "group_" .. characterName

    -- Give message handler time to process (messages are processed during mq.delay)
    mq.delay(checkInterval)
    elapsed = elapsed + checkInterval

    while elapsed < timeout do
        -- Check if we received a response (stored in peerData temporarily)
        if peerData[responseKey] then
            local members = peerData[responseKey]
            peerData[responseKey] = nil  -- Clean up
            Write.Debug(string.format("ActorManager: Got %d group members from %s", #members, characterName))
            return members
        end

        mq.delay(checkInterval)
        elapsed = elapsed + checkInterval
    end

    Write.Warn(string.format("ActorManager: Timeout waiting for group data from %s", characterName))
    return nil
end

function ActorManager.shutdownAllActors()
    -- Stop the local master script
    mq.cmd('/squelch /lua stop GroupDesigner/groupdesigner_actors')

    -- Stop all peer actor scripts
    local dannetPeers = nil
    local success, result = pcall(function() return mq.TLO.DanNet.Peers() end)
    if success and Common.isSafeString(result) then
        for peer in string.gmatch(result, "([^|]+)") do
            if Common.isSafeString(peer) then
                mq.cmdf('/squelch /dex %s /lua stop GroupDesigner/groupdesigner_actors', peer)
            end
        end
    end

    -- Clean up the peer data file
    local dataFile = mq.configDir .. "/GroupDesigner_peers.lua"
    os.remove(dataFile)

    -- Clean up any group query files
    local pattern = mq.configDir .. "/GroupDesigner_group_*.lua"
    -- Note: Lua doesn't have native glob, so we'll just try to remove common ones
    -- The files will be cleaned on next run anyway

    if masterActor then
        masterActor:unregister()
        masterActor = nil
    end

    isEnabled = false
    initFailed = false
    peerData = {}
    Write.Debug("ActorManager: All actors shut down")
end

return ActorManager