local mq = require('mq')
require('ImGui')
local Configuration = require('interface.configuration')
local Common = require('utils.common')
local Write = require('utils.Write')

local UI = {}
local config = nil

-- UI Control variables using MQ ImGui pattern
local isOpen, shouldDraw = true, true

-- Thread-safe communication flags
local formGroupsRequested = false
local formGroupsInProgress = false
local formGroupsResults = nil

-- Save dialog state
local showSaveGroupDialog = false
local showSaveGroupSetDialog = false
local showLoadGroupSetDialog = false
local showDeleteConfirmDialog = false
local showOverwriteConfirmDialog = false
local saveGroupIndex = -1
local groupNameBuffer = ""
local groupSetNameBuffer = ""
local deleteTarget = ""
local deleteType = ""
local overwriteTarget = ""
local overwriteType = ""
local overwriteData = nil


local availablePeers = {}
local groupBlocks = {}
local lastPeerRefresh = 0
local autoRefreshInterval = 3  -- seconds

-- Refresh available peers from Actor system
local function refreshAvailablePeers()
    -- Refresh actors data
    if Common.isActorSystemActive() then
        Common.updateActorSystem()
        Write.Debug("Refreshed actor system data")
    end

    local allPeers = Common.getPeers()
    availablePeers = {}

    -- Filter out peers that are already assigned to groups
    for _, peer in ipairs(allPeers) do
        local isAssigned = false

        -- Check if peer is already in a group block (case-insensitive)
        for _, group in ipairs(groupBlocks) do
            for _, member in ipairs(group.members) do
                if string.lower(member.name) == string.lower(peer.name) then
                    isAssigned = true
                    break
                end
            end
            if isAssigned then break end
        end

        -- Only add to available if not assigned
        if not isAssigned then
            table.insert(availablePeers, peer)
        end
    end

    Write.Debug("Actors: Found %d total peers, %d available", #allPeers, #availablePeers)
end

-- Load a group set (multiple groups)
local function loadGroupSet(setName)
    if not config or not config.groupSets or not config.groupSets[setName] then
        Write.Warn("Group set '%s' not found", setName)
        return
    end

    -- Clear current groups and reset to available peers
    for _, group in ipairs(groupBlocks) do
        for _, member in ipairs(group.members) do
            -- Find full peer data and add back to available
            local allPeers = Common.getPeers()
            for _, peer in ipairs(allPeers) do
                if string.lower(peer.name) == string.lower(member.name) then
                    table.insert(availablePeers, peer)
                    break
                end
            end
        end
    end

    -- Load the group set
    local groupNames = config.groupSets[setName]
    groupBlocks = {}

    for i, groupName in ipairs(groupNames) do
        if config.groups[groupName] then
            local savedGroup = config.groups[groupName]
            local newGroup = {
                name = groupName,  -- Use the actual group name from config
                members = {}
            }

            -- Load members into the group
            for _, savedMember in ipairs(savedGroup.members) do
                -- Remove from available peers and add to group (case-insensitive)
                local found = false
                for j = #availablePeers, 1, -1 do
                    if string.lower(availablePeers[j].name) == string.lower(savedMember.name) then
                        table.insert(newGroup.members, {
                            name = availablePeers[j].name,  -- Use actual peer name
                            class = availablePeers[j].class,
                            level = availablePeers[j].level,
                            ac = availablePeers[j].ac,
                            maxhp = availablePeers[j].maxhp,
                            maxmana = availablePeers[j].maxmana,
                            maxendurance = availablePeers[j].maxendurance,
                            zone = availablePeers[j].zone,
                            roles = savedMember.roles or {}
                        })
                        table.remove(availablePeers, j)
                        found = true
                        break
                    end
                end

                if not found then
                    Write.Warn("Warning: Saved member '%s' not found in available peers", savedMember.name)
                end
            end

            table.insert(groupBlocks, newGroup)
        end
    end

    Write.Info("Loaded group set: %s (%d groups)", setName, #groupBlocks)
end

-- Load a single group
local function loadSingleGroup(groupName)
    if not config or not config.groups or not config.groups[groupName] then
        Write.Warn("Group '%s' not found", groupName)
        return
    end

    local savedGroup = config.groups[groupName]
    local newGroup = {
        name = groupName,
        members = {}
    }

    -- Load members into the group
    for _, savedMember in ipairs(savedGroup.members) do
        -- Remove from available peers and add to group
        for j = #availablePeers, 1, -1 do
            if availablePeers[j].name == savedMember.name then
                table.insert(newGroup.members, {
                    name = savedMember.name,
                    class = availablePeers[j].class,
                    level = availablePeers[j].level,
                    ac = availablePeers[j].ac,
                    maxhp = availablePeers[j].maxhp,
                    maxmana = availablePeers[j].maxmana,
                    maxendurance = availablePeers[j].maxendurance,
                    zone = availablePeers[j].zone,
                    roles = savedMember.roles or {}
                })
                table.remove(availablePeers, j)
                break
            end
        end
    end

    table.insert(groupBlocks, newGroup)
    Write.Info("Loaded group: %s (%d members)", groupName, #newGroup.members)
end

-- Form all current groups (moved to be called from main thread)
local function formCurrentGroups()
    local groupsToForm = {}

    -- Collect all groups with more than 1 member
    for i, group in ipairs(groupBlocks) do
        if #group.members > 1 then
            table.insert(groupsToForm, {
                name = group.name or ("TempGroup_" .. i),  -- Use actual name if available
                members = group.members
            })
        end
    end

    if #groupsToForm == 0 then
        Write.Warn("No groups with multiple members to form")
        return
    end

    Write.Info("Forming %d groups using smart formation...", #groupsToForm)

    -- Form each group and count successes
    local successCount = 0
    for _, groupData in ipairs(groupsToForm) do
        local success, message = Common.formGroup(groupData, config.keepRaid, config.delay, config.maxRetries)
        if success then
            Write.Info("[SUCCESS] %s: %s", groupData.name, message)
            successCount = successCount + 1
        else
            Write.Error("[FAILED] %s: %s", groupData.name, message)
        end
    end

    Write.Info("Group formation complete!")

    -- Update results and clear progress flag
    formGroupsResults = {
        success = successCount == #groupsToForm,
        message = string.format("%d/%d groups formed", successCount, #groupsToForm)
    }
    formGroupsInProgress = false
end

-- Draw save group dialog
local function drawSaveGroupDialog()
    if not showSaveGroupDialog then return end

    ImGui.SetNextWindowSize(400, 300)
    showSaveGroupDialog, shouldDraw = ImGui.Begin("Save Group", showSaveGroupDialog, ImGuiWindowFlags.NoResize)

    if shouldDraw then
        ImGui.Text("Group Name:")
        groupNameBuffer = ImGui.InputText("##GroupName", groupNameBuffer, 256)

        if ImGui.Button("Save") and groupNameBuffer ~= "" then
            local group = groupBlocks[saveGroupIndex]
            if group then
                local members = {}
                for _, member in ipairs(group.members) do
                    table.insert(members, {
                        name = member.name,
                        roles = member.roles or {}
                    })
                end
                -- Check if this would be an overwrite
                local existingName = Configuration.findExistingGroupName(config, groupNameBuffer)
                if existingName then
                    -- Show overwrite confirmation
                    showSaveGroupDialog = false
                    showOverwriteConfirmDialog = true
                    overwriteTarget = existingName
                    overwriteType = "group"
                    overwriteData = {
                        groupName = groupNameBuffer,
                        members = members
                    }
                else
                    -- Direct save - no overwrite needed
                    local finalGroupName, wasOverwrite = Configuration.saveGroup(config, groupNameBuffer, members)
                    Write.Info("Saved group '%s' with %d members", finalGroupName, #members)
                    showSaveGroupDialog = false
                end
            end
        end

        ImGui.SameLine()
        if ImGui.Button("Cancel") then
            showSaveGroupDialog = false
        end

        ImGui.Separator()
        ImGui.Text("Existing Groups:")

        if config and config.groups then
            for name, _ in pairs(config.groups) do
                ImGui.Text(name)
                ImGui.SameLine()
                if ImGui.SmallButton("Delete##" .. name) then
                    -- Close parent dialog and show confirmation
                    showSaveGroupDialog = false
                    showDeleteConfirmDialog = true
                    deleteTarget = name
                    deleteType = "group"
                end
            end
        end
    end
    ImGui.End()
end

-- Draw save group set dialog
local function drawSaveGroupSetDialog()
    if not showSaveGroupSetDialog then return end

    ImGui.SetNextWindowSize(400, 350)
    showSaveGroupSetDialog, shouldDraw = ImGui.Begin("Save Group Set", showSaveGroupSetDialog, ImGuiWindowFlags.NoResize)

    if shouldDraw then
        ImGui.Text("Group Set Name:")
        groupSetNameBuffer = ImGui.InputText("##SetName", groupSetNameBuffer, 256)

        if ImGui.Button("Save") and groupSetNameBuffer ~= "" then
            -- Check if this would be an overwrite
            local existingName = Configuration.findExistingGroupSetName(config, groupSetNameBuffer)
            if existingName then
                -- Show overwrite confirmation
                showSaveGroupSetDialog = false
                showOverwriteConfirmDialog = true
                overwriteTarget = existingName
                overwriteType = "groupset"
                overwriteData = {
                    setName = groupSetNameBuffer,
                    groupBlocks = groupBlocks
                }
            else
                -- Direct save - no overwrite needed
                local finalSetName, wasOverwrite = Configuration.saveGroupSet(config, groupSetNameBuffer, groupBlocks)
                Write.Info("Saved group set '%s' with automatic subgroup naming", finalSetName)
                showSaveGroupSetDialog = false
            end
        end

        ImGui.SameLine()
        if ImGui.Button("Cancel") then
            showSaveGroupSetDialog = false
        end

        ImGui.Separator()
        ImGui.Text("Existing Group Sets:")

        if config and config.groupSets then
            for name, _ in pairs(config.groupSets) do
                ImGui.Text(name)
                ImGui.SameLine()
                if ImGui.SmallButton("Delete##" .. name) then
                    -- Close parent dialog and show confirmation
                    showSaveGroupSetDialog = false
                    showDeleteConfirmDialog = true
                    deleteTarget = name
                    deleteType = "groupset"
                end
            end
        end
    end
    ImGui.End()
end

-- Draw load group set dialog
local function drawLoadGroupSetDialog()
    if not showLoadGroupSetDialog then return end

    ImGui.SetNextWindowSize(400, 300)
    showLoadGroupSetDialog, shouldDraw = ImGui.Begin("Load Group Set", showLoadGroupSetDialog, ImGuiWindowFlags.NoResize)

    if shouldDraw then
        ImGui.Text("Select a Group Set to Load:")
        ImGui.Separator()

        if config and config.groupSets then
            for setName, _ in pairs(config.groupSets) do
                if ImGui.Button(setName .. "##load") then
                    -- Load the group set
                    loadGroupSet(setName)
                    showLoadGroupSetDialog = false
                end
            end
        else
            ImGui.Text("No saved group sets found.")
        end

        ImGui.Separator()
        if ImGui.Button("Cancel") then
            showLoadGroupSetDialog = false
        end

        ImGui.Separator()
        ImGui.Text("Individual Groups:")

        if config and config.groups then
            for groupName, _ in pairs(config.groups) do
                if ImGui.Button(groupName .. "##loadgroup") then
                    -- Load individual group
                    loadSingleGroup(groupName)
                    showLoadGroupSetDialog = false
                end
            end
        else
            ImGui.Text("No saved groups found.")
        end
    end
    ImGui.End()
end

-- Draw delete confirmation dialog
local function drawDeleteConfirmDialog()
    if not showDeleteConfirmDialog then return end

    ImGui.SetNextWindowSize(300, 120)
    showDeleteConfirmDialog, shouldDraw = ImGui.Begin("Confirm Delete", showDeleteConfirmDialog, ImGuiWindowFlags.NoResize)

    if shouldDraw then
        ImGui.Text("Delete " .. (deleteType or "item") .. " '" .. (deleteTarget or "unknown") .. "'?")

        if ImGui.Button("Yes") then
            if deleteType == "group" then
                Configuration.deleteGroup(config, deleteTarget)
                Write.Info("Deleted group: %s", deleteTarget)
            elseif deleteType == "groupset" then
                Configuration.deleteGroupSet(config, deleteTarget)
                Write.Info("Deleted group set: %s", deleteTarget)
            end
            showDeleteConfirmDialog = false
            showSaveGroupDialog = false
            showSaveGroupSetDialog = false
        end

        ImGui.SameLine()
        if ImGui.Button("No") then
            showDeleteConfirmDialog = false
        end
    end
    ImGui.End()
end

-- Draw overwrite confirmation dialog
local function drawOverwriteConfirmDialog()
    if not showOverwriteConfirmDialog then return end

    ImGui.SetNextWindowSize(400, 150)
    showOverwriteConfirmDialog, shouldDraw = ImGui.Begin("Confirm Overwrite", showOverwriteConfirmDialog, ImGuiWindowFlags.NoResize)

    if shouldDraw then
        ImGui.Text("A " .. (overwriteType or "item") .. " with a similar name already exists:")
        ImGui.Text("'" .. (overwriteTarget or "unknown") .. "'")
        ImGui.Text("")
        ImGui.Text("Do you want to overwrite it?")

        if ImGui.Button("Yes, Overwrite") then
            if overwriteType == "groupset" and overwriteData then
                local finalSetName, wasOverwrite = Configuration.saveGroupSet(config, overwriteData.setName, overwriteData.groupBlocks)
                Write.Info("Overwritten group set '%s' with automatic subgroup naming", finalSetName)
            elseif overwriteType == "group" and overwriteData then
                local finalGroupName, wasOverwrite = Configuration.saveGroup(config, overwriteData.groupName, overwriteData.members)
                Write.Info("Overwritten group '%s'", finalGroupName)
            end
            showOverwriteConfirmDialog = false
        end

        ImGui.SameLine()
        if ImGui.Button("Cancel") then
            showOverwriteConfirmDialog = false
            -- Reopen the appropriate save dialog
            if overwriteType == "groupset" then
                showSaveGroupSetDialog = true
            elseif overwriteType == "group" then
                showSaveGroupDialog = true
            end
        end
    end
    ImGui.End()
end

-- Initialize group blocks based on peer count
local function initializeGroupBlocks(forceRefresh)
    -- Calculate ideal group count based on total peers (available + assigned)
    local totalPeers = #availablePeers
    for _, group in ipairs(groupBlocks) do
        totalPeers = totalPeers + #group.members
    end
    
    local idealGroupCount = math.max(1, math.ceil(totalPeers / 6))
    
    -- Only update if we need more groups or if forced
    if forceRefresh or #groupBlocks < idealGroupCount then
        -- Add missing groups
        for i = #groupBlocks + 1, idealGroupCount do
            table.insert(groupBlocks, {
                name = "Group " .. i,
                members = {}
            })
        end
        
        if #groupBlocks > 0 then
            Write.Debug("Updated group blocks to %d (total peers: %d)", #groupBlocks, totalPeers)
        end
    end
end

function UI.init(cfg)
    -- Store config reference
    config = cfg
    
    -- Initialize data
    initializeGroupBlocks()
    refreshAvailablePeers()
    
    -- Register the ImGui callback using proper MQ pattern
    mq.imgui.init('groupdesigner', UI.updateImGui)
    Write.Debug("GroupDesigner UI initialized with Actor data - %d peers available", #availablePeers)
end


local wasOpen = true  -- Track previous state

function UI.updateImGui()
    -- Save config when window is closed (X button or Close UI button)
    if wasOpen and not isOpen then
        if config then
            Configuration.save(config)
            Write.Debug("Configuration saved on window close")
        end
        wasOpen = false
    elseif not wasOpen and isOpen then
        wasOpen = true
    end
    
    -- Don't draw the UI if the UI was closed by pressing the X button
    if not isOpen then return end
    
    -- Auto-refresh peers from actor system
    if Common.isActorSystemActive() then
        local now = os.time()
        if now - lastPeerRefresh >= autoRefreshInterval then
            refreshAvailablePeers()
            lastPeerRefresh = now
            -- Update group blocks when peers are loaded
            initializeGroupBlocks()
        end
    end
    
    -- Update group blocks if we have peers now but no groups yet
    if #availablePeers > 0 and #groupBlocks == 0 then
        initializeGroupBlocks()
    end
    
    -- Make the window larger for the proper layout
    ImGui.SetNextWindowSize(1000, 700, ImGuiCond.FirstUseEver)
    
    -- isOpen will be set false if the X button is pressed on the window
    -- shouldDraw will generally always be true unless the window is collapsed
    isOpen, shouldDraw = ImGui.Begin('GroupDesigner', isOpen)
    
    -- Only draw the window contents if shouldDraw is true
    if shouldDraw then
        -- TOP LINE: Close button and Options
        if ImGui.Button("Close UI") then
            -- Save configuration immediately when closing
            if config then
                Configuration.save(config)
                Write.Debug("Configuration saved on Close UI button press")
            end
            isOpen = false
        end
        ImGui.SameLine()
        ImGui.Text("Options:")
        ImGui.SameLine()
        config.keepRaid = ImGui.Checkbox("Keep Raid", config.keepRaid or false)
        ImGui.SameLine()
        ImGui.Text("Delay (ms):")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(100)  -- Set width to 100px for the input field
        config.delay = ImGui.InputInt("##Delay", config.delay or 1000)
        if config.delay < 100 then config.delay = 100 end  -- Minimum delay
        
        -- Form Groups button - green if groups have members, gray if disabled
        ImGui.SameLine()
        local hasGroupsWithMembers = false
        for _, group in ipairs(groupBlocks) do
            if #group.members > 1 then
                hasGroupsWithMembers = true
            end
        end
        
        if hasGroupsWithMembers then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.7, 0.2, 1.0)  -- Green
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.8, 0.3, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.6, 0.1, 1.0)
        else
            ImGui.PushStyleColor(ImGuiCol.Button, 0.4, 0.4, 0.4, 1.0)  -- Gray
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.4, 0.4, 0.4, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.4, 0.4, 0.4, 1.0)
        end
        
        local clicked = ImGui.Button("Form Groups")
        ImGui.PopStyleColor(3)
        
        if clicked and hasGroupsWithMembers and not formGroupsInProgress then
            -- Set flag for main thread to process
            formGroupsRequested = true
            formGroupsInProgress = true
            formGroupsResults = nil
            Write.Info("Group formation requested - processing in main thread...")
        end
        
        -- Show status if group formation is in progress
        if formGroupsInProgress then
            ImGui.SameLine()
            ImGui.TextColored(0.8, 0.8, 0.2, 1.0, "(Processing...)")
        elseif formGroupsResults then
            ImGui.SameLine()
            if formGroupsResults.success then
                ImGui.TextColored(0.2, 0.8, 0.2, 1.0, "Completed")
            else
                ImGui.TextColored(0.8, 0.2, 0.2, 1.0, "" .. (formGroupsResults.message or "Failed"))
            end
        end
        
        ImGui.Separator()
        
        -- MAIN LAYOUT: Left side (peers) and Right side (groups)
        if ImGui.BeginTable("MainLayout", 2, ImGuiTableFlags.Resizable) then
            -- Setup columns: Left side wider for peer table, right side for groups
            ImGui.TableSetupColumn("Available Peers", ImGuiTableColumnFlags.WidthFixed, 500)
            ImGui.TableSetupColumn("Group Blocks", ImGuiTableColumnFlags.WidthStretch)
            
            ImGui.TableNextRow()
            
            -- LEFT SIDE: Available Peers
            ImGui.TableSetColumnIndex(0)
            ImGui.Text("Available Peers (" .. #availablePeers .. "):")
            
            if ImGui.Button("Refresh Peers") then
                refreshAvailablePeers()
                Write.Debug("Refreshed - %d peers available", #availablePeers)
            end
            
            -- Calculate dynamic table height (total window height - top controls - bottom margin)
            local windowHeight = ImGui.GetWindowHeight()
            local topControlsHeight = 80  -- Approximate height of top controls
            local bottomMargin = 40
            local dynamicTableHeight = windowHeight - topControlsHeight - bottomMargin
            
            -- Peers table with drag and drop
            if ImGui.BeginTable("PeerTable", 7, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.ScrollY, 0, dynamicTableHeight) then
                -- Set up columns
                ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableSetupColumn("Class", ImGuiTableColumnFlags.WidthFixed, 50) 
                ImGui.TableSetupColumn("Lvl", ImGuiTableColumnFlags.WidthFixed, 40)
                ImGui.TableSetupColumn("AC", ImGuiTableColumnFlags.WidthFixed, 45)
                ImGui.TableSetupColumn("Max HP", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableSetupColumn("Max Mana", ImGuiTableColumnFlags.WidthFixed, 70)
                ImGui.TableSetupColumn("Max End", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableHeadersRow()
                
                -- Draw available peer rows
                for i, peer in ipairs(availablePeers) do
                    ImGui.TableNextRow()
                    
                    ImGui.TableSetColumnIndex(0)
                    local clicked = ImGui.Selectable(peer.name, false, ImGuiSelectableFlags.SpanAllColumns)
                    
                    -- Drag source pattern (working)
                    if clicked then
                        Write.Debug("CLICK: Clicked on %s", peer.name)
                    else
                        if ImGui.BeginDragDropSource() then
                            Write.Debug("DRAG: Starting drag for %s", peer.name)
                            ImGui.SetDragDropPayload("PEER_DRAG", i)
                            ImGui.Text("Moving " .. peer.name)
                            ImGui.EndDragDropSource()
                        end
                    end
                    
                    ImGui.TableSetColumnIndex(1)
                    ImGui.Text(peer.class)
                    
                    ImGui.TableSetColumnIndex(2)
                    ImGui.Text(tostring(peer.level))
                    
                    ImGui.TableSetColumnIndex(3)
                    ImGui.Text(tostring(peer.ac or "---"))
                    
                    ImGui.TableSetColumnIndex(4)
                    ImGui.Text(tostring(peer.maxhp))
                    
                    ImGui.TableSetColumnIndex(5)
                    ImGui.Text(tostring(peer.maxmana))
                    
                    ImGui.TableSetColumnIndex(6)
                    ImGui.Text(tostring(peer.maxendurance))
                end
                
                ImGui.EndTable()
            end
            
            -- RIGHT SIDE: Group Blocks
            ImGui.TableSetColumnIndex(1)
            ImGui.Text("Group Blocks:")
            
            -- Button to add new group
            if ImGui.Button("Add Group Block") then
                table.insert(groupBlocks, {name = "Group " .. (#groupBlocks + 1), members = {}})
                Write.Debug("Added group block")
            end
            ImGui.SameLine()
            if ImGui.Button("Save Groups") then
                -- Close any other dialogs first
                showSaveGroupDialog = false
                showLoadGroupSetDialog = false
                showDeleteConfirmDialog = false
                showSaveGroupSetDialog = true
                groupSetNameBuffer = "Group Set " .. os.date("%H:%M:%S")
            end
            ImGui.SameLine()
            if ImGui.Button("Load Groups") then
                -- Close any other dialogs first
                showSaveGroupDialog = false
                showSaveGroupSetDialog = false
                showDeleteConfirmDialog = false
                showLoadGroupSetDialog = true
            end
            
            -- Group blocks in a scrollable area (use same dynamic height)
            if ImGui.BeginChild("GroupArea", 0, dynamicTableHeight - 50, true) then
                -- Calculate how many groups fit per row based on window width and card width
                local windowWidth = ImGui.GetWindowWidth()
                local cardWidth = 280
                local spacing = 10
                local groupsPerRow = math.max(1, math.floor(windowWidth / (cardWidth + spacing)))
                for i, group in ipairs(groupBlocks) do
                    -- Start new row every groupsPerRow groups
                    if (i - 1) % groupsPerRow ~= 0 then
                        ImGui.SameLine()
                    end
                    
                    ImGui.BeginGroup()
                    
                    -- Group header with save button
                    ImGui.Text(group.name .. " (" .. #group.members .. "/6)")
                    ImGui.SameLine()
                    if ImGui.SmallButton("Save##" .. i) then
                        -- Close any other dialogs first
                        showSaveGroupSetDialog = false
                        showDeleteConfirmDialog = false
                        showSaveGroupDialog = true
                        saveGroupIndex = i
                        groupNameBuffer = group.name
                    end
                    
                    -- Group box with content (wider for better visibility)
                    if ImGui.BeginChild("Group" .. i, 280, 135, true) then
                        -- Show group members
                        for j, member in ipairs(group.members) do
                            -- Build role abbreviations for compact display
                            local roleAbbrevs = {}
                            local roleTooltip = ""
                            if member.roles then
                                local roleAbbrevMap = {
                                    ["Leader"] = "L",
                                    ["Main Tank"] = "MT",
                                    ["Main Assist"] = "MA",
                                    ["Puller"] = "P",
                                    ["Mark NPC"] = "MK",
                                    ["Master Looter"] = "ML"
                                }
                                local fullRoles = {}
                                for role, hasRole in pairs(member.roles) do
                                    if hasRole then
                                        table.insert(roleAbbrevs, roleAbbrevMap[role] or "?")
                                        table.insert(fullRoles, role)
                                    end
                                end
                                if #fullRoles > 0 then
                                    roleTooltip = "Roles: " .. table.concat(fullRoles, ", ")
                                end
                            elseif member.role and member.role ~= "" then
                                -- Backward compatibility
                                roleTooltip = "Role: " .. member.role
                            end
                            
                            local memberText = member.name .. " (" .. member.class .. " " .. member.level .. ")"
                            if #roleAbbrevs > 0 then
                                memberText = "[" .. table.concat(roleAbbrevs, "/") .. "] " .. memberText
                            end
                            
                            -- Color-code based on primary role
                            local hasMainTank = member.roles and member.roles["Main Tank"]
                            local hasMainAssist = member.roles and member.roles["Main Assist"]
                            local hasLeader = member.roles and member.roles["Leader"]
                            
                            if hasMainTank then
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.6, 1.0, 1.0)  -- Blue for tank
                            elseif hasMainAssist then
                                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.6, 0.2, 1.0)  -- Orange for assist
                            elseif hasLeader then
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.2, 1.0)  -- Yellow for leader
                            end
                            
                            if ImGui.Selectable(memberText) then
                                Write.Debug("Clicked member: %s", member.name)
                            end
                            
                            if hasMainTank or hasMainAssist or hasLeader then
                                ImGui.PopStyleColor()
                            end
                            
                            -- Show tooltip with full role names and character stats
                            if ImGui.IsItemHovered() then
                                local tooltipText = ""
                                
                                -- Add roles if any
                                if roleTooltip ~= "" then
                                    tooltipText = roleTooltip .. "\n\n"
                                end
                                
                                -- Add character stats
                                tooltipText = tooltipText .. "Character Stats:\n"
                                tooltipText = tooltipText .. string.format("Class: %s\n", member.class or "---")
                                tooltipText = tooltipText .. string.format("Level: %s\n", member.level or "---")
                                tooltipText = tooltipText .. string.format("AC: %s\n", member.ac or "---")
                                tooltipText = tooltipText .. string.format("HP: %s\n", member.maxhp or "---")
                                tooltipText = tooltipText .. string.format("Mana: %s\n", member.maxmana or "---")
                                tooltipText = tooltipText .. string.format("End: %s", member.maxendurance or "---")
                                
                                ImGui.SetTooltip(tooltipText)
                            end
                            
                            -- Right click context menu for roles and removal
                            if ImGui.BeginPopupContextItem("member_" .. i .. "_" .. j) then
                                if ImGui.MenuItem("Remove from group") then
                                    -- Find the full peer data from Actor system and add back to available
                                    local allPeers = Common.getPeers()
                                    for _, peer in ipairs(allPeers) do
                                        if peer.name == member.name then
                                            table.insert(availablePeers, peer)
                                            break
                                        end
                                    end
                                    table.remove(group.members, j)
                                    Write.Debug("Removed %s from %s", member.name, group.name)
                                end
                                
                                ImGui.Separator()
                                ImGui.Text("Roles (additive):")
                                
                                -- Initialize roles table if it doesn't exist
                                if not member.roles then
                                    member.roles = {}
                                end
                                
                                -- Role checkboxes (one per group)
                                local roleList = {"Leader", "Main Tank", "Main Assist", "Puller", "Mark NPC", "Master Looter"}
                                for _, role in ipairs(roleList) do
                                    local hasRole = member.roles[role] or false
                                    local newValue = ImGui.Checkbox(role, hasRole)
                                    if newValue ~= hasRole then
                                        if newValue then
                                            -- Remove this role from all other members in the group first
                                            for k, otherMember in ipairs(group.members) do
                                                if k ~= j and otherMember.roles and otherMember.roles[role] then
                                                    otherMember.roles[role] = false
                                                    Write.Debug("Removed %s role from %s (transferred to %s)", role, otherMember.name, member.name)
                                                end
                                            end
                                            -- Now assign to current member
                                            member.roles[role] = true
                                            Write.Debug("Added %s role to %s", role, member.name)
                                        else
                                            -- Just remove from current member
                                            member.roles[role] = false
                                            Write.Debug("Removed %s role from %s", role, member.name)
                                        end
                                    end
                                end
                                
                                ImGui.EndPopup()
                            end
                        end
                        
                        if #group.members == 0 then
                            ImGui.Text("Drop peers here...")
                        end
                    end
                    ImGui.EndChild()
                    
                    -- Drop target AFTER the child window
                    if ImGui.BeginDragDropTarget() then
                        local payload = ImGui.AcceptDragDropPayload("PEER_DRAG")
                        
                        if payload ~= nil then
                            Write.Debug("DROP: Received payload in %s", group.name)
                            
                            local peerIndex = payload.Data
                            if peerIndex and type(peerIndex) == "number" and availablePeers[peerIndex] and #group.members < 6 then
                                local peer = availablePeers[peerIndex]
                                Write.Debug("SUCCESS: Moving %s to %s", peer.name, group.name)
                                
                                table.insert(group.members, {
                                    name = peer.name,
                                    class = peer.class,
                                    level = peer.level,
                                    ac = peer.ac,
                                    maxhp = peer.maxhp,
                                    maxmana = peer.maxmana,
                                    maxendurance = peer.maxendurance,
                                    zone = peer.zone,
                                    roles = {}  -- Initialize with empty roles table
                                })
                                table.remove(availablePeers, peerIndex)
                            end
                        end
                        ImGui.EndDragDropTarget()
                    end
                    
                    ImGui.EndGroup()
                end
            end
            ImGui.EndChild()
            
            ImGui.EndTable()  -- End MainLayout table
        end
    end
    
    -- Draw save dialogs (only one at a time to prevent focus issues)
    if showSaveGroupDialog then
        drawSaveGroupDialog()
    elseif showSaveGroupSetDialog then
        drawSaveGroupSetDialog()
    elseif showLoadGroupSetDialog then
        drawLoadGroupSetDialog()
    elseif showDeleteConfirmDialog then
        drawDeleteConfirmDialog()
    elseif showOverwriteConfirmDialog then
        drawOverwriteConfirmDialog()
    end
    
    -- Always call ImGui.End if begin was called
    ImGui.End()
end






function UI.shouldExit()
    return not isOpen
end

function UI.cleanup()
    -- Save configuration on exit
    if config then
        Configuration.save(config)
        Write.Debug("Configuration saved on exit")
    end
end

-- Public function to refresh peer data
function UI.refreshPeers()
    refreshAvailablePeers()
end


-- Check if group formation is requested (call from main thread)
function UI.checkFormGroupsRequest()
    if formGroupsRequested then
        formGroupsRequested = false
        formCurrentGroups()
        return true
    end
    return false
end

-- Get group formation results
function UI.getFormGroupsResults()
    return formGroupsResults
end

-- Clear group formation results (for UI cleanup)
function UI.clearFormGroupsResults()
    formGroupsResults = nil
end



return UI