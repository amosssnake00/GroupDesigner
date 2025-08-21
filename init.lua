local mq = require('mq')
require 'ImGui'
local Write = require('utils.Write')

-- Configure Write.lua
Write.prefix = 'GroupDesigner'
Write.loglevel = 'info'  -- Default to info level

local Configuration = require('interface.configuration')
local Commands = require('interface.commands')
local UI = require('interface.ui')
local Common = require('utils.common')

local config = nil
local isRunning = false

-- Get command line arguments at script level
local args = {...}

local function handleCommandLineArgs()
    if #args > 0 then
        local command = string.lower(args[1])
        
        if command == "form" and #args >= 2 then
            local name = args[2]
            Commands.formGroupOrSet(name)
            return true
            
        elseif command == "info" then
            Commands.showInfo()
            return true
        end
    end
    
    Commands.showHelp()
    return false
end

local function waitForActorPeers(maxWaitSeconds)
    maxWaitSeconds = maxWaitSeconds or 10
    Write.Info("Waiting for actor system to discover peers (max %d seconds)...", maxWaitSeconds)
    
    local startTime = os.time()
    local lastPeerCount = 0
    
    while os.time() - startTime < maxWaitSeconds do
        local peers = Common.getDannetPeers()
        local peerCount = #peers
        
        if peerCount > lastPeerCount then
            Write.Info("Found %d peers so far...", peerCount)
            lastPeerCount = peerCount
        end
        
        -- If we have a reasonable number of peers, continue
        -- We expect at least some peers for group formation
        if peerCount > 0 then
            -- Wait a bit more to ensure all peers are discovered
            mq.delay(2000)
            return true
        end
        
        mq.delay(500)
    end
    
    Write.Warn("Timeout waiting for peers after %d seconds", maxWaitSeconds)
    return false
end

local function main()
    config = Configuration.load()
    Commands.init(config)
    
    -- Check if we need to handle command line args
    local hasCommandLineArgs = #args > 0 and (string.lower(args[1]) == "form" or string.lower(args[1]) == "info")
    
    -- Initialize Actor system if configured (needed for both UI and command line)
    if config.useActors then
        Write.Debug("Initializing Actor system...")
        local success, actorSuccess = pcall(function() return Common.initActorSystem(config) end)
        if success and actorSuccess then
            Write.Debug("Actor system initialized successfully")
            
            -- If we have command line args, wait for peers to be discovered
            if hasCommandLineArgs and string.lower(args[1]) == "form" then
                waitForActorPeers(10)
            end
        else
            if not success then
                Write.Error("Actor system initialization error: %s", tostring(actorSuccess))
            else
                Write.Warn("Actor system initialization failed, falling back to DanNet")
            end
        end
    end
    
    -- Now handle command line args after actors are ready
    if handleCommandLineArgs() then
        -- Cleanup actors if they were started
        if Common.isActorSystemActive() then
            Write.Debug("Shutting down Actor system after command execution...")
            Common.shutdownActorSystem()
        end
        Commands.cleanup()
        return
    end
    
    UI.init(config)
    Commands.setRunning(true)
    isRunning = true
    
    Write.Info("GroupDesigner started. Use /groupdesigner for commands.")
    if config.useActors then
        Write.Debug("Actor system: %s", Common.isActorSystemActive() and "Active" or "Inactive")
    end
    
    -- Use MQ ImGui pattern - no manual draw loop needed
    while isRunning do
        -- Check exit condition first
        if UI.shouldExit() then
            Write.Info("UI closed by user, exiting main loop")
            break
        end
        
        -- Process pending queries in main thread (not ImGui thread)
        if not Common.isActorSystemActive() then
            Common.processPendingQueries(config.delay, UI.shouldExit)
        end
        
        -- Update Actor system if active
        Common.updateActorSystem()
        
        -- Check for group formation requests from UI (thread-safe)
        UI.checkFormGroupsRequest()
        
        -- Use shorter delay intervals to be more responsive to exit
        local checkInterval = 100  -- Check every 100ms
        local totalDelay = config.delay * 10  -- Total delay time
        local elapsed = 0
        
        while elapsed < totalDelay and isRunning do
            if UI.shouldExit() then
                Write.Debug("Exit detected during delay")
                break
            end
            mq.delay(checkInterval)
            elapsed = elapsed + checkInterval
        end
    end
    
    Write.Debug("Exited main loop, starting cleanup")
    
    -- Shutdown Actor system
    if Common.isActorSystemActive() then
        Write.Debug("Shutting down Actor system...")
        Common.shutdownActorSystem()
    end
    
    UI.cleanup()
    Commands.cleanup()
    Write.Info("GroupDesigner stopped.")
end

main()