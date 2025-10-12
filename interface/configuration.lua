local mq = require('mq')

local Configuration = {}

local defaultConfig = {
    keepRaid = false,
    delay = 100,
    maxRetries = 3,
    groups = {},
    groupSets = {},
    window = {
        width = 800,
        height = 600,
        posX = 100,
        posY = 100
    }
}

local configFile = mq.configDir .. '/GroupDesigner.lua'

-- Case-insensitive helper functions
function Configuration.findExistingName(config, searchName, configTable)
    if not searchName or searchName == "" then return nil end
    local lowerSearchName = string.lower(searchName)
    
    for existingName, _ in pairs(configTable) do
        if string.lower(existingName) == lowerSearchName then
            return existingName  -- Return the existing case
        end
    end
    return nil
end

function Configuration.findExistingGroupName(config, searchName)
    return Configuration.findExistingName(config, searchName, config.groups)
end

function Configuration.findExistingGroupSetName(config, searchName)
    return Configuration.findExistingName(config, searchName, config.groupSets)
end

function Configuration.load()
    local config = defaultConfig
    
    if mq.TLO.Ini.File(configFile).Exists() then
        local success, loadedConfig = pcall(dofile, configFile)
        if success and loadedConfig then
            for k, v in pairs(loadedConfig) do
                config[k] = v
            end
        end
    end
    
    return config
end

function Configuration.save(config)
    local file = io.open(configFile, 'w')
    if file then
        file:write('return {\n')
        file:write(string.format('    keepRaid = %s,\n', tostring(config.keepRaid)))
        file:write(string.format('    delay = %d,\n', config.delay))
        file:write(string.format('    maxRetries = %d,\n', config.maxRetries))
        
        file:write('    groups = {\n')
        for name, group in pairs(config.groups) do
            file:write(string.format('        ["%s"] = {\n', name))
            file:write('            members = {\n')
            for i, member in ipairs(group.members) do
                file:write(string.format('                {name = "%s"', member.name))
                
                -- Handle new roles system
                if member.roles and type(member.roles) == "table" then
                    file:write(', roles = {')
                    local roleEntries = {}
                    for role, hasRole in pairs(member.roles) do
                        if hasRole then
                            table.insert(roleEntries, string.format('["%s"] = true', role))
                        end
                    end
                    file:write(table.concat(roleEntries, ', '))
                    file:write('}')
                elseif member.role and member.role ~= "" then
                    -- Backward compatibility with old role system
                    file:write(string.format(', role = "%s"', member.role))
                end
                
                file:write('},\n')
            end
            file:write('            }\n')
            file:write('        },\n')
        end
        file:write('    },\n')
        
        file:write('    groupSets = {\n')
        for name, groupSet in pairs(config.groupSets) do
            file:write(string.format('        ["%s"] = {\n', name))
            for i, groupName in ipairs(groupSet) do
                file:write(string.format('            "%s",\n', groupName))
            end
            file:write('        },\n')
        end
        file:write('    },\n')
        
        file:write('    window = {\n')
        file:write(string.format('        width = %d,\n', config.window.width))
        file:write(string.format('        height = %d,\n', config.window.height))
        file:write(string.format('        posX = %d,\n', config.window.posX))
        file:write(string.format('        posY = %d,\n', config.window.posY))
        file:write('    }\n')
        
        file:write('}\n')
        file:close()
    end
end

function Configuration.saveGroup(config, groupName, members)
    -- Check for existing name with different case
    local existingName = Configuration.findExistingGroupName(config, groupName)
    local finalGroupName = groupName  -- Default to new name with user's case
    
    if existingName then
        -- Case-insensitive match found - use existing case but mark for overwrite
        finalGroupName = existingName
    end
    
    config.groups[finalGroupName] = {
        members = members
    }
    Configuration.save(config)
    
    return finalGroupName, existingName ~= nil  -- Return final name and whether it was an overwrite
end

function Configuration.saveGroupSet(config, setName, groupBlocks)
    -- Check for existing name with different case
    local existingName = Configuration.findExistingGroupSetName(config, setName)
    local finalSetName = setName  -- Default to new name with user's case
    
    if existingName then
        -- Case-insensitive match found - use existing case but mark for overwrite
        finalSetName = existingName
    end
    
    -- Generate automatic subgroup names: setname_1, setname_2, etc.
    local groupNames = {}
    for i, block in ipairs(groupBlocks) do
        if #block.members > 0 then
            local subgroupName = finalSetName .. "_" .. i
            
            -- Save the individual subgroup
            config.groups[subgroupName] = {
                members = block.members
            }
            table.insert(groupNames, subgroupName)
        end
    end
    
    -- Save the group set with list of subgroup names
    config.groupSets[finalSetName] = groupNames
    Configuration.save(config)
    
    return finalSetName, existingName ~= nil  -- Return final name and whether it was an overwrite
end

function Configuration.deleteGroup(config, groupName)
    config.groups[groupName] = nil
    Configuration.save(config)
end

function Configuration.deleteGroupSet(config, setName)
    config.groupSets[setName] = nil
    Configuration.save(config)
end

return Configuration