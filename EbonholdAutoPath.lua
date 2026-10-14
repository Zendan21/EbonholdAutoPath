-- Ebonhold Auto Path v0.2.0
-- Project Ebonhold / WoW 3.3.5a
--
-- Clicking a later Skill Tree node automatically stages every prerequisite
-- node first, in parent -> child order, then performs the player's original
-- click on the requested node.
--
-- This addon does NOT press Apply and does not send its own server payload.

local ADDON_NAME = ...
local PREFIX = "|cff7dd3fc[Ebonhold Auto Path]|r "

local defaults = {
    enabled = true,
    verbose = false,
}

local nodesById = {}
local parentsOf = {}
local maxRankOf = {}
local hookedButtons = {}
local busy = false
local graphEdges = 0
local hookedCount = 0
local lastClickedNodeId = nil
local treeOnShowHooked = false

local function Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
    end
end

local function Debug(msg)
    if EbonholdAutoPathDB and EbonholdAutoPathDB.verbose then
        Print("|cffaaaaaa" .. tostring(msg) .. "|r")
    end
end

local function ApplyDefaults()
    if type(EbonholdAutoPathDB) ~= "table" then
        EbonholdAutoPathDB = {}
    end
    for key, value in pairs(defaults) do
        if EbonholdAutoPathDB[key] == nil then
            EbonholdAutoPathDB[key] = value
        end
    end
end

local function GetTree()
    return TalentDatabase and TalentDatabase[0]
end

local function GetNodeButton(nodeId)
    return _G["skillTreeNode" .. tostring(nodeId)]
end

local function BuildGraph()
    local tree = GetTree()
    if not (tree and type(tree.nodes) == "table" and type(tree.links) == "table") then
        return false
    end

    wipe(nodesById)
    wipe(parentsOf)
    wipe(maxRankOf)
    graphEdges = 0

    for _, node in ipairs(tree.nodes) do
        local id = node and tonumber(node.id)
        if id then
            nodesById[id] = node
            local maxRank = 0
            if type(node.spells) == "table" then
                maxRank = #node.spells
            end
            if maxRank <= 0 and type(node.soulPointsCosts) == "table" then
                maxRank = #node.soulPointsCosts
            end
            if maxRank <= 0 then maxRank = 1 end
            maxRankOf[id] = maxRank
        end
    end

    -- Ebonhold's graph format is: tree.links = { { parentNodeId, childNodeId }, ... }
    for _, link in ipairs(tree.links) do
        if type(link) == "table" then
            local parentId = tonumber(link[1])
            local childId = tonumber(link[2])
            if parentId and childId and nodesById[parentId] and nodesById[childId] then
                if not parentsOf[childId] then parentsOf[childId] = {} end
                parentsOf[childId][parentId] = true
                graphEdges = graphEdges + 1
            end
        end
    end

    Debug("Graph rebuilt: " .. tostring(graphEdges) .. " links, " .. tostring(#tree.nodes) .. " nodes.")
    return true
end

local function ReadLeadingNumber(text)
    if type(text) ~= "string" then return nil end
    local value = text:match("^%s*(%d+)%s*/") or text:match("^%s*(%d+)%s*$")
    return value and tonumber(value) or nil
end

local function GetNodeRank(nodeId)
    local node = nodesById[nodeId]
    local btn = GetNodeButton(nodeId)
    if not (node and btn) then return 0 end

    -- A genuinely locked/unselected node has no purchased rank.
    if btn.state == "locked" then return 0 end

    -- Infinite nodes display their current rank in the stack badge.
    if node.infinite then
        local badge = btn.stackBadge
        if badge and badge.IsShown and badge:IsShown() and badge.count and badge.count.GetText then
            return tonumber(badge.count:GetText()) or 0
        end
        return 0
    end

    -- Prefer the visible rank text because it reflects staged, not only committed, ranks.
    if btn.rankText and btn.rankText.GetText then
        local rank = ReadLeadingNumber(btn.rankText:GetText())
        if rank ~= nil then return rank end
    end

    -- Compatibility fallbacks for Ebonhold UI revisions / other addons.
    local candidates = {
        btn.currentRank,
        btn.rank,
        btn.learnedRank,
        btn.points,
        btn.currentPoints,
    }
    for _, value in ipairs(candidates) do
        local rank = tonumber(value)
        if rank then return rank end
    end

    -- Ebonhold marks a completed non-infinite node active; at that point it is max rank.
    if btn.state == "active" then
        return maxRankOf[nodeId] or 1
    end

    return 0
end

local function IsModifierBypass()
    return IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown()
end

local function CallNativeClick(nodeId, mouseButton, down)
    local btn = GetNodeButton(nodeId)
    if not btn then return false end

    local original = btn.EAPOriginalOnClick
    if type(original) ~= "function" then return false end

    local ok, err = pcall(original, btn, mouseButton or "LeftButton", down)
    if not ok then
        Debug("Native click failed for node " .. tostring(nodeId) .. ": " .. tostring(err))
        return false
    end
    return true
end

local function EnsureNodeMaxed(nodeId)
    local node = nodesById[nodeId]
    local btn = GetNodeButton(nodeId)
    if not (node and btn) then return false end

    if node.isMultipleChoice or btn.isMultipleChoice then
        Print("A prerequisite is a multiple-choice node. Pick that choice manually, then click your target again.")
        return false
    end

    local wanted = maxRankOf[nodeId] or 1
    local current = GetNodeRank(nodeId)
    if current >= wanted then return true end

    local attempts = 0
    local limit = wanted + 2

    while current < wanted and attempts < limit do
        attempts = attempts + 1
        local before = current

        if not CallNativeClick(nodeId, "LeftButton") then
            return false
        end

        current = GetNodeRank(nodeId)
        if current <= before then
            -- The native handler remains the authority. This normally means insufficient
            -- Soul Ash or that Ebonhold rejected the selection for another reason.
            Debug("Node " .. tostring(nodeId) .. " stopped at rank " .. tostring(current) .. "/" .. tostring(wanted) .. ".")
            return false
        end
    end

    return current >= wanted
end

local function BuildPrerequisiteOrder(targetId)
    local order = {}
    local visiting = {}
    local done = {}

    local function Visit(nodeId)
        if done[nodeId] then return true end
        if visiting[nodeId] then
            Debug("Cycle detected around node " .. tostring(nodeId) .. ".")
            return false
        end

        visiting[nodeId] = true
        local parents = parentsOf[nodeId]
        if parents then
            for parentId in pairs(parents) do
                if not Visit(parentId) then return false end
            end
        end
        visiting[nodeId] = nil
        done[nodeId] = true

        if nodeId ~= targetId then
            order[#order + 1] = nodeId
        end
        return true
    end

    if not Visit(targetId) then return nil end
    return order
end

local function HandleNodeClick(nodeId, btn, original, mouseButton, down)
    lastClickedNodeId = nodeId

    -- Some 3.3.5 UI code invokes an OnClick without explicitly passing the button.
    local effectiveButton = mouseButton or "LeftButton"

    if busy
        or not EbonholdAutoPathDB
        or not EbonholdAutoPathDB.enabled
        or effectiveButton ~= "LeftButton"
        or IsModifierBypass() then
        return original(btn, mouseButton, down)
    end

    if not parentsOf[nodeId] or not next(parentsOf[nodeId]) then
        return original(btn, mouseButton, down)
    end

    local order = BuildPrerequisiteOrder(nodeId)
    if not order then
        return original(btn, mouseButton, down)
    end

    busy = true
    local advanced = 0
    local completed = true

    for _, parentId in ipairs(order) do
        local before = GetNodeRank(parentId)
        if not EnsureNodeMaxed(parentId) then
            completed = false
            break
        end
        if GetNodeRank(parentId) > before then
            advanced = advanced + 1
        end
    end

    busy = false

    if advanced > 0 then
        Debug("Filled " .. tostring(advanced) .. " prerequisite node(s) before node " .. tostring(nodeId) .. ".")
    end
    if not completed then
        Debug("Prerequisite path could not be completed; passing the target click to Ebonhold normally.")
    end

    -- Always let Ebonhold process the player's intended target click last.
    return original(btn, mouseButton, down)
end

local function HookNode(nodeId)
    local btn = GetNodeButton(nodeId)
    if not btn then return false end

    if hookedButtons[btn] and btn:GetScript("OnClick") == btn.EAPWrapper then
        return false
    end

    local original = btn:GetScript("OnClick")
    if type(original) ~= "function" then return false end

    -- If this exact frame was previously ours but another addon replaced its handler,
    -- wrap the current handler rather than keeping a stale Ebonhold function.
    local wrapper
    wrapper = function(self, mouseButton, down)
        return HandleNodeClick(nodeId, self, original, mouseButton, down)
    end

    btn.EAPOriginalOnClick = original
    btn.EAPWrapper = wrapper
    btn:SetScript("OnClick", wrapper)
    hookedButtons[btn] = true
    return true
end

local function InstallHooks()
    if not BuildGraph() then return false end

    local added = 0
    local total = 0
    for nodeId in pairs(nodesById) do
        if GetNodeButton(nodeId) then
            total = total + 1
            if HookNode(nodeId) then added = added + 1 end
        end
    end

    hookedCount = total

    if graphEdges <= 0 then
        Debug("Tree is present, but no links were found yet.")
        return false
    end

    if added > 0 then
        Debug("Hooked " .. tostring(added) .. " new Skill Tree node(s).")
    end

    if _G.skillTreeFrame and not treeOnShowHooked then
        _G.skillTreeFrame:HookScript("OnShow", function()
            InstallHooks()
        end)
        treeOnShowHooked = true
    end

    return total > 0
end

local function ParentList(nodeId)
    local list = {}
    local parents = parentsOf[nodeId]
    if parents then
        for parentId in pairs(parents) do
            list[#list + 1] = parentId
        end
    end
    table.sort(list)
    return list
end

local function DebugNode(nodeId)
    nodeId = tonumber(nodeId) or lastClickedNodeId
    if not nodeId then
        Print("Click a Skill Tree node first, then use |cffffffff/eap debug|r.")
        return
    end

    local node = nodesById[nodeId]
    if not node then
        Print("Node " .. tostring(nodeId) .. " is not in the current TalentDatabase.")
        return
    end

    local parents = ParentList(nodeId)
    local text = {}
    for _, parentId in ipairs(parents) do
        text[#text + 1] = tostring(parentId) .. " (" .. tostring(GetNodeRank(parentId)) .. "/" .. tostring(maxRankOf[parentId] or 1) .. ")"
    end

    Print("Node " .. tostring(nodeId)
        .. " rank " .. tostring(GetNodeRank(nodeId)) .. "/" .. tostring(maxRankOf[nodeId] or 1)
        .. "; direct parent(s): " .. (#text > 0 and table.concat(text, ", ") or "none"))
end

SLASH_EBONHOLDAUTOPATH1 = "/eap"
SlashCmdList["EBONHOLDAUTOPATH"] = function(msg)
    ApplyDefaults()
    msg = tostring(msg or "")
    local cmd, arg = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "on" then
        EbonholdAutoPathDB.enabled = true
        Print("Enabled.")
    elseif cmd == "off" then
        EbonholdAutoPathDB.enabled = false
        Print("Disabled.")
    elseif cmd == "toggle" then
        EbonholdAutoPathDB.enabled = not EbonholdAutoPathDB.enabled
        Print(EbonholdAutoPathDB.enabled and "Enabled." or "Disabled.")
    elseif cmd == "verbose" then
        EbonholdAutoPathDB.verbose = not EbonholdAutoPathDB.verbose
        Print("Verbose logging " .. (EbonholdAutoPathDB.verbose and "enabled." or "disabled."))
    elseif cmd == "rebuild" then
        InstallHooks()
        Print("Graph: " .. tostring(graphEdges) .. " links; visible node buttons: " .. tostring(hookedCount) .. ".")
    elseif cmd == "debug" then
        DebugNode(arg ~= "" and arg or nil)
    elseif cmd == "status" then
        Print("Status: " .. (EbonholdAutoPathDB.enabled and "ON" or "OFF")
            .. "; graph links: " .. tostring(graphEdges)
            .. "; visible node buttons: " .. tostring(hookedCount) .. ".")
    else
        Print("Clicking a later node fills every prerequisite branch first, then clicks your target.")
        Print("Commands: |cffffffff/eap on|r, |cffffffff/eap off|r, |cffffffff/eap status|r, |cffffffff/eap rebuild|r, |cffffffff/eap debug [nodeId]|r, |cffffffff/eap verbose|r")
        Print("Hold Shift, Ctrl, or Alt while clicking to bypass Auto Path for that click.")
    end
end

-- WoW 3.3.5 does not provide C_Timer by default. Polling with an OnUpdate frame
-- makes initialization reliable even when ProjectEbonhold creates/rebuilds its
-- custom Skill Tree UI after PLAYER_LOGIN.
local driver = CreateFrame("Frame")
local elapsedSinceScan = 0

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" and name == ADDON_NAME then
        ApplyDefaults()
    end

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        ApplyDefaults()
        InstallHooks()
    end
end)

driver:SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceScan = elapsedSinceScan + elapsed
    if elapsedSinceScan < 1.0 then return end
    elapsedSinceScan = 0

    if _G.skillTreeFrame and _G.skillTreeFrame.IsShown and _G.skillTreeFrame:IsShown() then
        InstallHooks()
    elseif graphEdges == 0 then
        -- Keep trying quietly until Ebonhold has populated TalentDatabase.
        InstallHooks()
    end
end)
