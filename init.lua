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

local function main()
    config = Configuration.load()
    Commands.init(config)
    
    if handleCommandLineArgs() then
        Commands.cleanup()
        return
    end
    
    -- Initialize Actor system if configured
    if config.useActors then
        Write.Debug("Initializing Actor system...")
        local success, actorSuccess = pcall(function() return Common.initActorSystem(config) end)
        if success and actorSuccess then
            Write.Debug("Actor system initialized successfully")
        else
            if not success then
                Write.Error("Actor system initialization error: %s", tostring(actorSuccess))
            else
                Write.Warn("Actor system initialization failed, falling back to DanNet")
            end
        end
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