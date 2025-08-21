-- MVP Actor System for GroupDesigner
local mq = require('mq')
local actors = require('actors')
local Write = require('utils.Write')

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
    
    -- Handle peer data responses
    if content.type == "peer_data" and content.name then
        Write.Debug("Master: Received peer data from %s", content.name)
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
    end
end

-- Initialize system
function ActorManager.init(config)
    if not config.useActors then
        return false
    end
    
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
    if success and result and result ~= "" and result ~= "NULL" then
        dannetPeers = result
    end
    
    local localName = mq.TLO.Me.Name()
    local peerList = {}
    
    -- Collect all peers
    if dannetPeers then
        for peer in string.gmatch(dannetPeers, "([^|]+)") do
            if peer and peer ~= "" then
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
        if success and result and result ~= "" and result ~= "NULL" then
            for peer in string.gmatch(result, "([^|]+)") do
                if peer and peer ~= "" then
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

function ActorManager.shutdownAllActors()
    -- Stop the local master script
    mq.cmd('/squelch /lua stop GroupDesigner/groupdesigner_actors')
    
    -- Stop all peer actor scripts
    local dannetPeers = nil
    local success, result = pcall(function() return mq.TLO.DanNet.Peers() end)
    if success and result and result ~= "" and result ~= "NULL" then
        for peer in string.gmatch(result, "([^|]+)") do
            if peer and peer ~= "" then
                mq.cmdf('/squelch /dex %s /lua stop GroupDesigner/groupdesigner_actors', peer)
            end
        end
    end
    
    -- Clean up the peer data file
    local dataFile = mq.configDir .. "/GroupDesigner_peers.lua"
    os.remove(dataFile)
    
    if masterActor then
        masterActor:unregister()
        masterActor = nil
    end
    
    isEnabled = false
    initFailed = false
    peerData = {}
    Write.Info("ActorManager: All actors shut down")
end

return ActorManager