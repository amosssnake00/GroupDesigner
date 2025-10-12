local mq = require('mq')
local Write = require('utils.Write')

-- Configure Write.lua if not already done
if not Write.prefix then
    Write.prefix = 'GroupDesigner'
    Write.loglevel = 'info'
end

local Common = {}

-- Actor system integration (lazy loading to avoid circular dependency)
local ActorManager = nil
local function getActorManager()
    if not ActorManager then
        Write.Debug("getActorManager: Loading utils.actors...")
        local success, result = pcall(function() return require('utils.actors') end)
        if success then
            ActorManager = result
            Write.Debug("getActorManager: Successfully loaded ActorManager")
        else
            Write.Error("getActorManager: Failed to load utils.actors: %s", tostring(result))
        end
    end
    return ActorManager
end

Common.ROLES = {
    NONE = "",
    MAIN_TANK = "Main Tank",
    MAIN_ASSIST = "Main Assist", 
    PULLER = "Puller",
    MARK_NPC = "Mark NPC",
    MASTER_LOOTER = "Master Looter"
}

Common.ROLE_CODES = {
    [Common.ROLES.MAIN_TANK] = 1,
    [Common.ROLES.MAIN_ASSIST] = 2,
    [Common.ROLES.PULLER] = 3,
    [Common.ROLES.MARK_NPC] = 4,
    [Common.ROLES.MASTER_LOOTER] = 5
}

function Common.delay(ms)
    mq.delay(ms)
end

-- Utility function to check if a string value is safe (not null, not empty)
function Common.isSafeString(value)
    return value and type(value) == "string" and value ~= "" and value ~= "NULL"
end

-- Get peer data from Actor system only
function Common.getPeers()
    local actorManager = getActorManager()
    if actorManager and actorManager.isEnabled() then
        -- Use Actor system data
        Write.Debug("Common.getPeers: Using Actor system for peer data")
        return actorManager.getPeerData()
    else
        -- No actors = no peers
        Write.Warn("Common.getPeers: Actor system not active, no peers available")
        return {}
    end
end

-- Initialize Actor system (always required)
function Common.initActorSystem(config)
    Write.Debug("Common.initActorSystem: Attempting to get ActorManager...")
    local actorManager = getActorManager()
    if actorManager then
        Write.Debug("Common.initActorSystem: ActorManager loaded, calling init...")
        local result = actorManager.init(config)
        Write.Debug("Common.initActorSystem: ActorManager.init returned: %s", tostring(result))
        return result
    else
        Write.Error("Common.initActorSystem: Failed to load ActorManager")
        return false
    end
end

-- Update Actor system (call from main loop)
function Common.updateActorSystem()
    local actorManager = getActorManager()
    if actorManager and actorManager.isEnabled() then
        actorManager.update()
    end
end

-- Shutdown Actor system
function Common.shutdownActorSystem()
    local actorManager = getActorManager()
    if actorManager and actorManager.isEnabled() then
        actorManager.shutdownAllActors()
    end
end

-- Check if Actor system is active
function Common.isActorSystemActive()
    local actorManager = getActorManager()
    return actorManager and actorManager.isEnabled() or false
end

-- Check if Actor system failed to initialize
function Common.hasActorSystemFailed()
    local actorManager = getActorManager()
    return actorManager and actorManager.hasFailed and actorManager.hasFailed() or false
end

-- Get the local character name
function Common.getLocalCharacterName()
    local success, result = pcall(function() return mq.TLO.Me.Name() end)
    if success and Common.isSafeString(result) then
        return result
    end
    return nil
end

-- Send command to specific character (via DanNet for remote, direct for local)
function Common.sendCommandToCharacter(characterName, command)
    local localName = Common.getLocalCharacterName()
    if localName and string.lower(characterName) == string.lower(localName) then
        -- Direct command for local character
        mq.cmd(command)
    else
        -- Remote command via DanNet
        mq.cmdf('/squelch /dex %s %s', characterName, command)
    end
end

-- Analyze current group membership and determine what needs to change
function Common.analyzeGroupChanges(leaderName, expectedMembers, delay)
    delay = delay or 100
    Write.Debug(string.format("Analyzing current group state for leader: %s", leaderName))

    local localName = Common.getLocalCharacterName()
    local currentMembers = {}

    -- Query current group members
    local members = {}
    if localName and string.lower(leaderName) == string.lower(localName) then
        -- Direct query for local character
        for i = 0, 5 do
            local success, result = pcall(function() return mq.TLO.Group.Member(i)() end)
            if success and Common.isSafeString(result) then
                table.insert(members, result)
            end
        end
        Write.Debug(string.format("Local group query found %d members", #members))
    else
        -- Query via Actor system for remote leader
        Write.Debug(string.format("Querying remote leader %s via Actors", leaderName))
        local actorManager = getActorManager()
        if actorManager and actorManager.isEnabled() then
            members = actorManager.queryGroupMembers(leaderName, delay * 30) or {}
            Write.Debug(string.format("Actor query found %d members from %s", #members, leaderName))
        else
            Write.Error("Actor system not available for querying %s", leaderName)
            members = {}
        end
    end

    -- Build currentMembers table
    if members then
        for _, memberName in ipairs(members) do
            if Common.isSafeString(memberName) then
                currentMembers[string.lower(memberName)] = true
                Write.Debug("Current group member: %s", memberName)
            end
        end
    end
    
    -- Determine who needs to be added and who needs to be removed
    local toInvite = {}      -- Members who should be in group but aren't
    local toRemove = {}      -- Members who are in group but shouldn't be
    local alreadyCorrect = {} -- Members who are already in the right place
    
    -- Check expected members
    for _, expectedMember in ipairs(expectedMembers) do
        if currentMembers[string.lower(expectedMember.name)] then
            table.insert(alreadyCorrect, expectedMember.name)
        else
            table.insert(toInvite, expectedMember.name)
        end
    end
    
    -- Check current members to see who should be removed
    for currentMember in pairs(currentMembers) do
        local shouldStay = false
        for _, expectedMember in ipairs(expectedMembers) do
            if string.lower(currentMember) == string.lower(expectedMember.name) then
                shouldStay = true
                break
            end
        end
        if not shouldStay then
            table.insert(toRemove, currentMember)
        end
    end
    
    Write.Debug("Group analysis complete:")
    Write.Debug("  Already correct: %d members (%s)", #alreadyCorrect, table.concat(alreadyCorrect, ", "))
    Write.Debug("  Need to invite: %d members (%s)", #toInvite, table.concat(toInvite, ", "))
    Write.Debug("  Need to remove: %d members (%s)", #toRemove, table.concat(toRemove, ", "))
    
    return {
        alreadyCorrect = alreadyCorrect,
        toInvite = toInvite,
        toRemove = toRemove,
        totalChanges = #toInvite + #toRemove
    }
end

-- Verify group formation via leader's perspective
function Common.verifyGroupViaLeader(leaderName, expectedMembers, delay)
    delay = delay or 100  -- Default delay value
    Write.Debug(string.format("Verifying group via leader %s", leaderName))

    local localName = Common.getLocalCharacterName()
    local actualMembers = {}

    -- Query group members
    local members = {}
    if localName and string.lower(leaderName) == string.lower(localName) then
        -- Direct query for local character
        for i = 0, 5 do
            local success, result = pcall(function() return mq.TLO.Group.Member(i)() end)
            if success and Common.isSafeString(result) then
                table.insert(members, result)
            end
        end
    else
        -- Query via Actor system for remote leader
        Write.Debug(string.format("Querying remote leader %s via Actors", leaderName))
        local actorManager = getActorManager()
        if actorManager and actorManager.isEnabled() then
            members = actorManager.queryGroupMembers(leaderName, delay * 30) or {}
            Write.Debug(string.format("Actor query found %d members from %s", #members, leaderName))
        else
            Write.Error("Actor system not available for querying %s", leaderName)
            members = {}
        end
    end

    -- Build actualMembers table
    for i, memberName in ipairs(members) do
        if Common.isSafeString(memberName) then
            actualMembers[string.lower(memberName)] = true  -- Store in lowercase for comparison
            Write.Debug(string.format("Group slot %d: %s", i-1, memberName))
        end
    end
    
    -- Check if all expected members are present
    local missingMembers = {}
    
    for _, expectedMember in ipairs(expectedMembers) do
        if not actualMembers[string.lower(expectedMember.name)] then  -- Compare in lowercase
            table.insert(missingMembers, expectedMember.name)
        end
    end
    
    if #missingMembers == 0 then
        Write.Debug("Group verification successful - all %d members present", #expectedMembers)
        return true, {}
    else
        Write.Debug("Group verification failed - missing: %s", table.concat(missingMembers, ", "))
        return false, missingMembers
    end
end


function Common.formGroup(groupData, keepRaid, delay, maxRetries)
    if not groupData or not groupData.members or #groupData.members == 0 then
        return false, "No members in group"
    end
    
    maxRetries = maxRetries or 3  -- Default to 3 retry attempts
    
    -- Find leader (prefer roles, fallback to first member)
    local leader = nil
    for _, member in ipairs(groupData.members) do
        if member.roles and (member.roles["Leader"] or member.roles["Main Tank"]) then
            leader = member
            break
        elseif member.role == Common.ROLES.MAIN_TANK then
            leader = member
            break
        end
    end
    if not leader then
        leader = groupData.members[1]
    end
    
    Write.Debug("Forming group with leader: %s (max retries: %d)", leader.name, maxRetries)
    
    -- Step 1: Analyze current group state
    local changes = Common.analyzeGroupChanges(leader.name, groupData.members, delay)
    local earlySuccess = false
    
    if changes.totalChanges == 0 then
        Write.Debug("Group is already correctly formed! No changes needed.")
    else
        Write.Debug("Smart formation: %d changes needed (%d to remove, %d to invite)", 
                     changes.totalChanges, #changes.toRemove, #changes.toInvite)
        
        -- Step 2: Remove unwanted members (disband only those who need to go)
        if #changes.toRemove > 0 then
            if not keepRaid then
                for _, memberName in ipairs(changes.toRemove) do
                    Common.sendCommandToCharacter(memberName, '/docommand /raiddisband')
                end
            end
            
            for _, memberName in ipairs(changes.toRemove) do
                Common.sendCommandToCharacter(memberName, '/docommand /disband')
            end
            
            Write.Debug("Waiting for %d members to disband...", #changes.toRemove)
            mq.delay(delay * 10)  -- 1000ms default
        end
        
        -- Step 3: Disband members who need to be invited (they might be in other groups)
        if #changes.toInvite > 0 then
            if not keepRaid then
                for _, memberName in ipairs(changes.toInvite) do
                    Common.sendCommandToCharacter(memberName, '/docommand /raiddisband')
                end
            end
            
            for _, memberName in ipairs(changes.toInvite) do
                Common.sendCommandToCharacter(memberName, '/docommand /disband')
            end
            
            Write.Debug("Waiting for %d new members to disband from other groups...", #changes.toInvite)
            mq.delay(delay * 10)  -- 1000ms default
        end
        
        -- Step 4: Send invite commands only to those who need to join
        if #changes.toInvite > 0 then
            for _, memberName in ipairs(changes.toInvite) do
                if memberName ~= leader.name then
                    Common.sendCommandToCharacter(leader.name, string.format('/docommand /inv %s', memberName))
                    Write.Debug("Sent invite to %s", memberName)
                end
            end

            Write.Debug("Waiting for %d invitations to be accepted...", #changes.toInvite)
            -- Use callback-based waiting with increased timeout
            local maxWait = delay * 50  -- 5000ms default (increased from 2000ms)
            local elapsed = 0
            local checkInterval = 500
            

            while elapsed < maxWait do
                -- Check if all members have joined
                local verifySuccess, _ = Common.verifyGroupViaLeader(leader.name, groupData.members, delay)
                if verifySuccess then
                    Write.Debug(string.format("All members joined successfully after %dms", elapsed))
                    earlySuccess = true
                    break
                end
                mq.delay(checkInterval)
                elapsed = elapsed + checkInterval
            end

            if elapsed >= maxWait then
                Write.Warn(string.format("Timeout waiting for all members to join after %dms", maxWait))
            end
        end
    end

    -- Step 5: Verify group with retry logic (skip if already verified)
    local success = false
    local finalMissingMembers = {}

    -- Quick check first - if we already verified in callback, confirm it
    if earlySuccess then
        local verifySuccess, missingMembers = Common.verifyGroupViaLeader(leader.name, groupData.members, delay)
        if verifySuccess then
            success = true
            Write.Debug("Group formation successful (confirmed from callback)")
        else
            -- Callback said success but verification failed, need retry
            Write.Warn("Callback reported success but verification failed, retrying...")
            finalMissingMembers = missingMembers
        end
    end

    -- Only do retry loop if not already successful
    if not success then
        for attempt = 1, maxRetries do
        local verifySuccess, missingMembers = Common.verifyGroupViaLeader(leader.name, groupData.members, delay)
        
        if verifySuccess then
            success = true
            Write.Debug("Group formation successful on attempt %d/%d", attempt, maxRetries)
            break
        else
            finalMissingMembers = missingMembers
            Write.Debug("Attempt %d/%d failed - missing: %s", attempt, maxRetries, table.concat(missingMembers, ", "))
            
            if attempt < maxRetries then
                -- Retry: disband missing members and re-invite
                Write.Debug("Retrying - disbanding and re-inviting missing members")
                
                for _, missingMemberName in ipairs(missingMembers) do
                    Common.sendCommandToCharacter(missingMemberName, '/docommand /disband')
                end
                mq.delay(delay * 10)  -- 1000ms default
                
                for _, missingMemberName in ipairs(missingMembers) do
                    Common.sendCommandToCharacter(leader.name, string.format('/docommand /inv %s', missingMemberName))
                end
                mq.delay(delay * 20)  -- 2000ms default
            else
                Write.Debug("All retry attempts exhausted - continuing with partial group")
            end
        end
        end  -- End for attempt loop
    end  -- End if not success

    -- Step 6: Set roles (only for members who successfully joined)
    if success or #finalMissingMembers < #groupData.members then
        Write.Debug("Setting roles for group members")
        for _, member in ipairs(groupData.members) do
            -- Skip role assignment for missing members
            local memberMissing = false
            for _, missingName in ipairs(finalMissingMembers) do
                if string.lower(member.name) == string.lower(missingName) then
                    memberMissing = true
                    break
                end
            end
            
            if not memberMissing then
                if member.roles then
                    for role, hasRole in pairs(member.roles) do
                        if hasRole and Common.ROLE_CODES[role] then
                            local roleCode = Common.ROLE_CODES[role]
                            Common.sendCommandToCharacter(leader.name, string.format('/docommand /grouproles set %s %d', member.name, roleCode))
                            mq.delay(delay * 5)  -- 500ms default
                        end
                    end
                elseif member.role and member.role ~= "" and Common.ROLE_CODES[member.role] then
                    local roleCode = Common.ROLE_CODES[member.role]
                    Common.sendCommandToCharacter(leader.name, string.format('/docommand /grouproles set %s %d', member.name, roleCode))
                    mq.delay(delay * 5)  -- 500ms default
                end
            end
        end
    end
    
    if success then
        return true, "Group formed successfully"
    elseif #finalMissingMembers < #groupData.members then
        return true, string.format("Group formed with %d/%d members (missing: %s)", 
                                  #groupData.members - #finalMissingMembers, #groupData.members, 
                                  table.concat(finalMissingMembers, ", "))
    else
        return false, "Group formation failed - missing: " .. table.concat(finalMissingMembers, ", ")
    end
end

function Common.formGroupSet(config, setName)
    local groupSet = config.groupSets[setName]
    if not groupSet then
        return false, "Group set not found: " .. setName
    end
    
    Write.Info("Forming group set: %s with %d groups", setName, #groupSet)
    
    -- Collect all group data and members
    local allGroups = {}
    local allMembers = {}
    
    for _, groupName in ipairs(groupSet) do
        local groupData = config.groups[groupName]
        if groupData and groupData.members then
            -- Find leader for this group
            local leader = nil
            for _, member in ipairs(groupData.members) do
                if member.roles and (member.roles["Leader"] or member.roles["Main Tank"]) then
                    leader = member
                    break
                elseif member.role == Common.ROLES.MAIN_TANK then
                    leader = member
                    break
                end
            end
            if not leader then
                leader = groupData.members[1]
            end
            
            table.insert(allGroups, {
                name = groupName,
                data = groupData,
                leader = leader
            })
            
            -- Add all members to the master list
            for _, member in ipairs(groupData.members) do
                table.insert(allMembers, member)
            end
        end
    end
    
    if #allGroups == 0 then
        return {{group = "N/A", success = false, message = "No valid groups found in set"}}
    end
    
    Write.Debug("Processing %d groups with %d total members", #allGroups, #allMembers)
    Write.Debug("Using smart group formation - analyzing current state for all groups...")
    
    -- STEP 1: Analyze what changes are needed for all groups
    local allChanges = {}
    local totalChangesNeeded = 0
    
    for _, group in ipairs(allGroups) do
        local changes = Common.analyzeGroupChanges(group.leader.name, group.data.members, config.delay)
        allChanges[group.name] = changes
        totalChangesNeeded = totalChangesNeeded + changes.totalChanges
    end
    
    Write.Debug("Smart formation analysis: %d total changes needed across all groups", totalChangesNeeded)
    
    if totalChangesNeeded == 0 then
        Write.Info("All groups are already correctly formed! No changes needed.")
    else
        -- STEP 2: Collect all members who need to be disbanded
        local toDisbandFromRaid = {}
        local toDisband = {}
        
        for groupName, changes in pairs(allChanges) do
            for _, memberName in ipairs(changes.toRemove) do
                if not config.keepRaid then
                    table.insert(toDisbandFromRaid, memberName)
                end
                table.insert(toDisband, memberName)
            end
            for _, memberName in ipairs(changes.toInvite) do
                if not config.keepRaid then
                    table.insert(toDisbandFromRaid, memberName)
                end
                table.insert(toDisband, memberName)
            end
        end
        
        -- STEP 3: Send disband commands only to those who need changes
        if #toDisbandFromRaid > 0 then
            Write.Debug("Sending raiddisband to %d members who need changes...", #toDisbandFromRaid)
            for _, memberName in ipairs(toDisbandFromRaid) do
                Common.sendCommandToCharacter(memberName, '/docommand /raiddisband')
            end
        end
        
        if #toDisband > 0 then
            Write.Debug("Sending disband to %d members who need changes...", #toDisband)
            for _, memberName in ipairs(toDisband) do
                Common.sendCommandToCharacter(memberName, '/docommand /disband')
            end
            
            Write.Debug("Waiting for selective disbands to complete...")
            mq.delay(config.delay * 20)  -- 2000ms default
        end
        
        -- STEP 4: Send invite commands only where needed
        local totalInvites = 0
        for groupName, changes in pairs(allChanges) do
            if #changes.toInvite > 0 then
                local group = nil
                for _, g in ipairs(allGroups) do
                    if g.name == groupName then
                        group = g
                        break
                    end
                end
                
                if group then
                    for _, memberName in ipairs(changes.toInvite) do
                        if memberName ~= group.leader.name then
                            Common.sendCommandToCharacter(group.leader.name, string.format('/docommand /inv %s', memberName))
                            totalInvites = totalInvites + 1
                        end
                    end
                end
            end
        end
        
        if totalInvites > 0 then
            Write.Debug("Sent %d selective invitations...", totalInvites)
            mq.delay(config.delay * 30)  -- 3000ms default
        end
    end
    
    -- STEP 5: Verify all groups with retry logic
    local results = {}
    for _, group in ipairs(allGroups) do
        Write.Debug("Verifying group %s", group.name)
        
        local success = false
        local finalMissingMembers = {}
        
        -- Try up to 3 times to get all members
        for attempt = 1, 3 do
            local verifySuccess, missingMembers = Common.verifyGroupViaLeader(group.leader.name, group.data.members, config.delay)
            
            if verifySuccess then
                success = true
                break
            else
                finalMissingMembers = missingMembers
                Write.Debug("Attempt %d/%d failed for %s - missing: %s", attempt, 3, group.name, table.concat(missingMembers, ", "))
                
                if attempt < 3 then
                    -- Retry: disband missing members and re-invite
                    Write.Debug("Retrying group %s - disbanding and re-inviting missing members", group.name)
                    
                    for _, missingMemberName in ipairs(missingMembers) do
                        Common.sendCommandToCharacter(missingMemberName, '/docommand /disband')
                    end
                    mq.delay(config.delay * 10)  -- 1000ms default
                    
                    for _, missingMemberName in ipairs(missingMembers) do
                        Common.sendCommandToCharacter(group.leader.name, string.format('/docommand /inv %s', missingMemberName))
                    end
                    mq.delay(config.delay * 20)  -- 2000ms default
                end
            end
        end
        
        -- Set roles for this group if successful
        if success then
            Write.Debug("Setting roles for %s", group.name)
            for _, member in ipairs(group.data.members) do
                if member.roles then
                    for role, hasRole in pairs(member.roles) do
                        if hasRole and Common.ROLE_CODES[role] then
                            local roleCode = Common.ROLE_CODES[role]
                            Common.sendCommandToCharacter(group.leader.name, string.format('/docommand /grouproles set %s %d', member.name, roleCode))
                            mq.delay(config.delay * 2)  -- 200ms default
                        end
                    end
                elseif member.role and member.role ~= "" and Common.ROLE_CODES[member.role] then
                    local roleCode = Common.ROLE_CODES[member.role]
                    Common.sendCommandToCharacter(group.leader.name, string.format('/docommand /grouproles set %s %d', member.name, roleCode))
                    mq.delay(config.delay * 2)  -- 200ms default
                end
            end
        end
        
        table.insert(results, {
            group = group.name, 
            success = success, 
            message = success and "Group formed successfully" or ("Group verification failed - missing: " .. table.concat(finalMissingMembers, ", "))
        })
    end
    
    return results
end

return Common