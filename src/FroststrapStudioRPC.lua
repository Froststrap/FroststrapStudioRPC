-- FroststrapStudioRPC SDK v1.2.0

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local StudioService = game:GetService("StudioService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local FroststrapStudioRPC = {}
local Plugin = if plugin then plugin else nil

FroststrapStudioRPC.Config = {
	enabled = true,
	httpTimeout = 1,
	updateInterval = 10,
	port = 4875
}

local State = {
	lastPayload = {},
	isCooldown = false,
	isInitialized = false,
	monitoringThread = nil,
	connections = {},
}

local ScriptTypes = {
	SERVER = "Server Script",
	CLIENT = "Local Script",
	SERVER_MODULE = "Server Module",
	CLIENT_MODULE = "Client Module",
	MODULE = "Module",
	DEVELOPING = "Developing"
}

local function clearConnections()
	for name, connection in pairs(State.connections) do
		if connection then
			connection:Disconnect()
		end
	end
	table.clear(State.connections)
end

local function getScriptLineCount(scriptObj)
	if not scriptObj or not scriptObj:IsA("LuaSourceContainer") then return 0 end
	local success, source = pcall(function()
		return ScriptEditorService:GetEditorSource(scriptObj)
	end)
	if not success or not source or source == "" then
		success, source = pcall(function() return scriptObj.Source end)
	end
	if not success or not source then return 0 end
	local _, count = source:gsub("\n", "")
	return count + 1
end

local function getScriptType(scriptObj)
	if not scriptObj then return ScriptTypes.DEVELOPING end
	if scriptObj:IsA("Script") and scriptObj.RunContext == Enum.RunContext.Client then
		return ScriptTypes.CLIENT
	end
	if scriptObj:IsA("LocalScript") then return ScriptTypes.CLIENT end

	local isServerContext = false
	local isClientContext = false
	local ancestor = scriptObj.Parent
	while ancestor do
		if ancestor:IsA("ServerScriptService") or ancestor:IsA("ServerStorage") then
			isServerContext = true
			break
		elseif ancestor:IsA("StarterPlayer") or ancestor:IsA("StarterGui") or ancestor:IsA("StarterPack") then
			isClientContext = true
			break
		end
		ancestor = ancestor.Parent
	end

	if scriptObj:IsA("ModuleScript") then
		if isServerContext then return ScriptTypes.SERVER_MODULE end
		if isClientContext then return ScriptTypes.CLIENT_MODULE end
		return ScriptTypes.MODULE
	end
	return isServerContext and ScriptTypes.SERVER or ScriptTypes.CLIENT
end

local function getWorkspaceData()
	local name = "Unsaved Studio Project"
	local isPublic = false

	if game.PlaceId > 0 then
		local success, info = pcall(function()
			return MarketplaceService:GetProductInfoAsync(game.PlaceId)
		end)
		if success and info then
			name = info.Name or name
			isPublic = true 
		end
	else
		name = (game.Name ~= "Place" and game.Name ~= "") and game.Name or name
	end

	local devCount = #Players:GetPlayers()
	if devCount == 0 then devCount = 1 end

	return name, isPublic, devCount
end

local function collectActivityData()
	if not FroststrapStudioRPC.Config.enabled then return nil end

	local activeScript = StudioService.ActiveScript
	local scriptObj = nil

	if activeScript and activeScript:IsA("LuaSourceContainer") then
		scriptObj = activeScript
	else
		local selected = Selection:Get()
		if #selected == 1 and selected[1]:IsA("LuaSourceContainer") then
			scriptObj = selected[1]
		end
	end

	local testing = RunService:IsRunning()
	local workspaceName, isPublic, devCount = getWorkspaceData()
	local stateText = "Not in a Script"
	local scriptType = ScriptTypes.DEVELOPING

	if scriptObj then
		scriptType = getScriptType(scriptObj)
		local lines = getScriptLineCount(scriptObj)
		stateText = string.format("Editing %s (%d lines)", scriptObj.Name, lines)
	end

	return {
		details = workspaceName,
		state = stateText,
		testing = testing,
		scriptType = scriptType,
		placeId = game.PlaceId,
		isPublic = isPublic,
		devCount = devCount
	}
end   

local function sendViaHTTP(payload)
	task.spawn(function()
		local url = "http://localhost:4875/rpc"
		pcall(function()
			HttpService:RequestAsync({
				Url = url,
				Method = "POST",
				Headers = {["Content-Type"] = "application/json"},
				Body = HttpService:JSONEncode(payload),
				Timeout = FroststrapStudioRPC.Config.httpTimeout
			})
		end)
	end)
end

function FroststrapStudioRPC.SendMessage(data)
	if State.isCooldown then return end
	local isRedundant = true
	for k, v in pairs(data) do
		if State.lastPayload[k] ~= v then
			isRedundant = false
			break
		end
	end
	if isRedundant then return end
	State.lastPayload = data
	State.isCooldown = true
	task.delay(1.5, function() State.isCooldown = false end)
	sendViaHTTP({
		command = "SetRichPresence",
		data = data
	})
end

function FroststrapStudioRPC.UpdatePresence()
	if not FroststrapStudioRPC.Config.enabled then return end
	local data = collectActivityData()
	if data then
		FroststrapStudioRPC.SendMessage(data)
	end
end

function FroststrapStudioRPC.SetEnabled(enabled)
	FroststrapStudioRPC.Config.enabled = enabled
	local workspaceName, isPublic, devCount = getWorkspaceData()
	sendViaHTTP({
		command = "RPCToggle",
		data = { enabled = enabled, workspace = workspaceName, isPublic = isPublic }
	})
	if enabled then
		FroststrapStudioRPC.UpdatePresence()
		if not State.monitoringThread then
			State.monitoringThread = task.spawn(function()
				while FroststrapStudioRPC.Config.enabled do
					task.wait(FroststrapStudioRPC.Config.updateInterval)
					FroststrapStudioRPC.UpdatePresence()
				end
				State.monitoringThread = nil
			end)
		end
	else
		State.monitoringThread = nil
	end
end

function FroststrapStudioRPC.Initialize()
	if State.isInitialized or not Plugin then return end

	local toggleAction = Plugin:CreatePluginAction(
		"toggle_rpc_command",
		"Toggle Froststrap RPC",
		"Toggle Discord Rich Presence logging",
		"rbxassetid://111400040119373",
		true
	)

	State.connections.Toggle = toggleAction.Triggered:Connect(function()
		FroststrapStudioRPC.SetEnabled(not FroststrapStudioRPC.Config.enabled)
	end)

	State.connections.Selection = Selection.SelectionChanged:Connect(function()
		FroststrapStudioRPC.UpdatePresence()
	end)

	State.connections.TabSwitch = StudioService:GetPropertyChangedSignal("ActiveScript"):Connect(function()
		FroststrapStudioRPC.UpdatePresence()
	end)

	State.connections.DevJoin = Players.PlayerAdded:Connect(function()
		FroststrapStudioRPC.UpdatePresence()
	end)

	State.connections.DevLeave = Players.PlayerRemoving:Connect(function()
		FroststrapStudioRPC.UpdatePresence()
	end)

	State.connections.Unload = Plugin.Unloading:Connect(function()
		FroststrapStudioRPC.SetEnabled(false)
		clearConnections()
	end)

	FroststrapStudioRPC.SetEnabled(FroststrapStudioRPC.Config.enabled)
	State.isInitialized = true
end

if Plugin then
	FroststrapStudioRPC.Initialize()
end

return FroststrapStudioRPC