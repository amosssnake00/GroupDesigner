local mq = require('mq')
local Write = require('knightlinc.Write')

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

function Common.printf(fmt, ...)
    Write.Info(fmt, ...)
end

function Common.delay(ms)
    mq.delay(ms)
end

-- Utility function to check if a string value is safe (not null, not empty)
function Common.isSafeString(value)
    return value and type(value) == "string" and value ~= "" and value ~= "NULL"
end

-- Async query system
local pendingQueries = {}
local queryResults = {}

-- Queue a query for async processing
local function queueQuery(peerName, queryString, queryId)
    pendingQueries[queryId] = {
        peer = peerName,
        query = queryString,
        timestamp = os.clock()
    }
    --Common.printf("DEBUG: Queued query %s for %s: %s", queryId, peerName, queryString)
end

-- Get result of a queued query
local function getQueryResult(queryId)
    return queryResults[queryId]
end

-- Process pending queries (call from main thread, not ImGui)
function Common.processPendingQueries(delay, shouldExitFunc)
    delay = delay or 100  -- Default delay value
    
    for queryId, queryData in pairs(pendingQueries) do
        -- Check if we should exit before processing each query
        if shouldExitFunc and shouldExitFunc() then
            Write.Debug("Exiting query processing due to shutdown")
            -- Clear all pending queries
            pendingQueries = {}
            return
        end
        
        -- Send the query with timeout slightly longer than max wait
        mq.cmdf('/dquery %s -q %s -t %d', queryData.peer, queryData.query, delay * 30)
        
        -- Use a shorter check interval and check for exit condition
        local maxWait = delay * 35
        local elapsed = 0
        local checkInterval = 100
        
        while elapsed < maxWait do
            -- Check for exit condition
            if shouldExitFunc and shouldExitFunc() then
                Write.Debug("Exiting query wait due to shutdown")
                pendingQueries = {}
                return
            end
            
            -- Check if query received
            local received = mq.TLO.DanNet(queryData.peer).QReceived(queryData.query)()
            if received and received > 0 then
                break
            end
            
            mq.delay(checkInterval)
            elapsed = elapsed + checkInterval
        end
        
        -- Get the result
        local result = mq.TLO.DanNet(queryData.peer).Q(queryData.query)()

        if Common.isSafeString(result) then
            queryResults[queryId] = result
            Write.Debug("Query result for %s: %s = %s", queryData.peer, queryId, result)
        else
            queryResults[queryId] = nil
            Write.Debug("No result for query %s from %s", queryId, queryData.peer)
        end
        
        -- Remove from pending
        pendingQueries[queryId] = nil
    end
end

-- Get initial peer list immediately (names only)
function Common.getDannetPeerNames()
    local peerNames = {}
    
    -- Safety check for mq and TLO availability
    if not mq or not mq.TLO or not mq.TLO.DanNet then
        return peerNames
    end
    
    local dannetPeers = nil
    local success, result = pcall(function() return mq.TLO.DanNet.Peers() end)
    if success then
        dannetPeers = result
    end
    
    if Common.isSafeString(dannetPeers) then
        for peer in string.gmatch(dannetPeers, "([^|]+)") do
            if Common.isSafeString(peer) then
                table.insert(peerNames, peer)
            end
        end
    end
    
    return peerNames
end

-- Initialize peers with basic data, then populate details
function Common.initializePeers()
    local peers = {}
    local peerNames = Common.getDannetPeerNames()
    
    -- Create initial peer entries with just names
    for _, peerName in ipairs(peerNames) do
        table.insert(peers, {
            name = peerName,
            class = "---",
            level = "---",
            ac = "---",
            maxhp = "---",
            maxmana = "---",
            maxendurance = "---",
            zone = "---",
            loading = true
        })
    end
    
    return peers
end


-- Queue peer data queries (call from ImGui)
function Common.queuePeerDataQueries(peers)
    --Common.printf("DEBUG: queuePeerDataQueries called with %d peers", #peers)
    for i, peer in ipairs(peers) do
        if peer.loading then
            Write.Debug("Queueing queries for %s", peer.name)
            queueQuery(peer.name, 'Me.Class.ShortName', peer.name .. "_class")
            queueQuery(peer.name, 'Me.Level', peer.name .. "_level")
            queueQuery(peer.name, 'Window["InventoryWindow"].Child["IW_ACNumber"].Text', peer.name .. "_ac")
            queueQuery(peer.name, 'Me.MaxHPs', peer.name .. "_maxhp")
            queueQuery(peer.name, 'Me.MaxMana', peer.name .. "_maxmana")
            queueQuery(peer.name, 'Me.MaxEndurance', peer.name .. "_maxendurance")
            queueQuery(peer.name, 'Zone.ShortName', peer.name .. "_zone")
        end
    end
end

-- Update peer data with query results (call from ImGui)
function Common.updatePeerDataFromResults(peers)
    for i, peer in ipairs(peers) do
        if peer.loading then
            -- Get results from async queries, keep "---" if no data
            local newClass = getQueryResult(peer.name .. "_class")
            local newLevel = getQueryResult(peer.name .. "_level")
            local newAC = getQueryResult(peer.name .. "_ac")
            local newMaxHP = getQueryResult(peer.name .. "_maxhp")
            local newMaxMana = getQueryResult(peer.name .. "_maxmana")
            local newMaxEnd = getQueryResult(peer.name .. "_maxendurance")
            local newZone = getQueryResult(peer.name .. "_zone")

            -- Update fields with results or keep "---"
            peer.class = newClass or "---"
            peer.level = newLevel or "---"
            peer.ac = newAC or "---"
            peer.maxhp = newMaxHP or "---"
            peer.maxmana = newMaxMana or "---"
            peer.maxendurance = newMaxEnd or "---"
            peer.zone = newZone or "---"

            -- Stop loading if we got class data (main indicator)
            if peer.class ~= "---" then
                peer.loading = false
                Write.Debug("Peer %s data loaded: Class=%s Level=%s AC=%s HP=%s Mana=%s End=%s",
                    peer.name, peer.class, peer.level, peer.ac, peer.maxhp, peer.maxmana, peer.maxendurance)
            end
        end
    end
end

function Common.getDannetPeers()
    local actorManager = getActorManager()
    if actorManager and actorManager.isEnabled() then
        -- Use Actor system data if available
        Write.Debug("Common.getDannetPeers: Using Actor system for peer data")
        return actorManager.getPeerData()
    else
        -- Fallback to DanNet
        Write.Debug("Common.getDannetPeers: Using DanNet fallback for peer data (actors enabled: %s)",
            actorManager and actorManager.isEnabled() or "false")
        return Common.initializePeers()
    end
end

-- Initialize Actor system if configured
function Common.initActorSystem(config)
    if not config or not config.useActors then
        Write.Debug("Common.initActorSystem: config.useActors is false or nil")
        return false
    end
    
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

-- Send command to specific character (handles local vs remote automatically)
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
    Write.Debug("Analyzing current group state for leader: %s", leaderName)
    
    local localName = Common.getLocalCharacterName()
    local currentMembers = {}
    
    -- Query current group members
    for i = 0, 5 do
        local memberName = nil

        if localName and string.lower(leaderName) == string.lower(localName) then
            -- Direct query for local character
            local success, result = pcall(function() return mq.TLO.Group.Member(i)() end)
            if success and Common.isSafeString(result) then
                memberName = result
            end
        else
            -- Remote query via DanNet
            mq.cmdf('/dquery %s -q Group.Member[%d] -t %d', leaderName, i, delay * 25)
            mq.delay(delay * 30, function() 
                local received = mq.TLO.DanNet(leaderName).QReceived(string.format('Group.Member[%d]', i))()
                return received and received > 0
            end)
            memberName = mq.TLO.DanNet(leaderName).Q(string.format('Group.Member[%d]', i))()
        end
        
        if Common.isSafeString(memberName) then
            currentMembers[string.lower(memberName)] = true
            Write.Debug("Current group member: %s", memberName)
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
    Write.Debug("Verifying group via leader %s", leaderName)
    
    local localName = Common.getLocalCharacterName()
    local actualMembers = {}
    
    -- Query each group member slot (0-5)
    for i = 0, 5 do
        local memberName = nil
        
        if localName and string.lower(leaderName) == string.lower(localName) then
            -- Direct query for local character
            local success, result = pcall(function() return mq.TLO.Group.Member(i)() end)
            if success and Common.isSafeString(result) then
                memberName = result
            end
        else
            -- Remote query via DanNet
            mq.cmdf('/dquery %s -q Group.Member[%d] -t %d', leaderName, i, delay * 25)
            mq.delay(delay * 30, function()
                local received = mq.TLO.DanNet(leaderName).QReceived(string.format('Group.Member[%d]', i))()
                return received and received > 0
            end)
            memberName = mq.TLO.DanNet(leaderName).Q(string.format('Group.Member[%d]', i))()
        end

        if Common.isSafeString(memberName) then
            actualMembers[string.lower(memberName)] = true  -- Store in lowercase for comparison
            Write.Debug("Group slot %d: %s", i, memberName)
        else
            Write.Debug("Group slot %d: empty", i)
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
                end
            end
            
            Write.Debug("Waiting for %d invitations to be accepted...", #changes.toInvite)
            mq.delay(delay * 20)  -- 2000ms default
        end
    end
    
    -- Step 5: Verify group with retry logic
    local success = false
    local finalMissingMembers = {}
    
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
    end
    
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