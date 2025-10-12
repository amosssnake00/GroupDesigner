local mq = require('mq')
local Common = require('utils.common')
local Write = require('utils.Write')

local Commands = {}
local config = nil
local isRunning = false

function Commands.init(groupDesignerConfig)
    config = groupDesignerConfig
    mq.bind('/groupdesigner', Commands.handleCommand)
end

function Commands.setRunning(running)
    isRunning = running
end

function Commands.handleCommand(...)
    local args = {...}
    
    local subCommand = string.lower(tostring(args[1] or ""))
    local name = tostring(args[2] or "")
    
    if subCommand == "form" or subCommand == "load" then
        if name == "" or name == "nil" then
            Common.printf("Usage: /groupdesigner form <group_name_or_set_name>")
            Common.printf("       /groupdesigner load <group_name_or_set_name>")
            return
        end
        
        Commands.formGroupOrSet(name)
        
    elseif subCommand == "info" then
        Commands.showInfo()
        
    elseif subCommand == "actors" then
        -- Debug command to manually request actor data
        local actorManager = require('utils.actors')
        if actorManager.requestPeerData and actorManager.requestPeerData() then
            Common.printf("Manually triggered actor data request broadcast")
        else
            Common.printf("Actor system not active")
        end
        
    else
        Commands.showHelp()
    end
end

function Commands.formGroupOrSet(name)
    local Configuration = require('interface.configuration')
    
    -- First check for groups (case-insensitive)
    local groupName = Configuration.findExistingGroupName(config, name)
    if groupName then
        Common.printf("Forming group: %s", groupName)
        local success, message = Common.formGroup(config.groups[groupName], config.keepRaid, config.delay, config.maxRetries)
        if success then
            Common.printf("Group '%s' formed successfully", groupName)
        else
            Common.printf("Failed to form group '%s': %s", groupName, message)
        end
        return
    end
    
    -- Check for group sets (case-insensitive)
    local setName = Configuration.findExistingGroupSetName(config, name)
    if setName then
        Common.printf("Forming group set: %s", setName)
        local results = Common.formGroupSet(config, setName)
        
        local successCount = 0
        for _, result in ipairs(results) do
            if result.success then
                successCount = successCount + 1
                Common.printf("Group '%s': %s", result.group, result.message)
            else
                Common.printf("Group '%s': FAILED - %s", result.group, result.message)
            end
        end
        
        Common.printf("Group set '%s' formation complete: %d/%d groups successful", 
                     setName, successCount, #results)
        return
    end
    
    -- Nothing found
    Common.printf("Group or group set '%s' not found", name)
    Commands.showAvailable()
end

function Commands.showInfo()
    Common.printf("=== GroupDesigner Configuration ===")
    Common.printf("Keep Raid: %s", config.keepRaid and "Yes" or "No")
    Common.printf("Delay: %d ms", config.delay)
    Common.printf("Max Retries: %d", config.maxRetries)
    Common.printf("Actor System: %s", Common.isActorSystemActive() and "Active" or "Inactive")
    Common.printf("")
    
    if next(config.groups) then
        Common.printf("Individual Groups:")
        for name, group in pairs(config.groups) do
            Common.printf("  %s (%d members)", name, #group.members)
            for i, member in ipairs(group.members) do
                local role = member.role and member.role ~= "" and (" [" .. member.role .. "]") or ""
                Common.printf("    %d. %s%s", i, member.name, role)
            end
        end
        Common.printf("")
    else
        Common.printf("No individual groups configured")
        Common.printf("")
    end
    
    if next(config.groupSets) then
        Common.printf("Group Sets:")
        for name, groupSet in pairs(config.groupSets) do
            Common.printf("  %s (%d groups)", name, #groupSet)
            for i, groupName in ipairs(groupSet) do
                local memberCount = config.groups[groupName] and #config.groups[groupName].members or 0
                Common.printf("    %d. %s (%d members)", i, groupName, memberCount)
            end
        end
    else
        Common.printf("No group sets configured")
    end
end

function Commands.showAvailable()
    Common.printf("Available groups:")
    for name, _ in pairs(config.groups) do
        Common.printf("  - %s", name)
    end
    
    Common.printf("Available group sets:")
    for name, _ in pairs(config.groupSets) do
        Common.printf("  - %s", name)
    end
end

function Commands.showHelp()
    Write.Help("=== GroupDesigner Commands ===")
    Write.Help("/groupdesigner form <name>  - Form a group or group set")
    Write.Help("/groupdesigner load <name>  - Form a group or group set (alias for form)")
    Write.Help("/groupdesigner info         - Show configuration and available groups/sets")
    Write.Help("")
    Write.Help("Command Line Usage (when starting script):")
    Write.Help("/lua run GroupDesigner form <name>  - Form group/set and exit")
    Write.Help("/lua run GroupDesigner load <name>  - Form group/set and exit")
    Write.Help("/lua run GroupDesigner info         - Show info and exit")
    Write.Help("/lua run GroupDesigner              - Start GUI interface")
    Write.Help("")
    Write.Help("NOTE: /groupdesigner commands only work when the script is running!")
    Write.Help("Use the command line versions above when the script is not running.")
end

function Commands.cleanup()
    mq.unbind('/groupdesigner')
end

return Commands