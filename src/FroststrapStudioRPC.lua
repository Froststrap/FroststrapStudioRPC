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
	httpTimeout = 2,
	updateInterval = 10,
	port = 4875
}

local State = {
	lastPayload = {},
	isCooldown = false,
	isInitialized = false,
	monitoringThread = nil,
	connections = {},
	cachedWorkspace = { name = "Unsaved Studio Project", isPublic = false }
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
	for _, connection in pairs(State.connections) do
		if connection then connection:Disconnect() end
	end
	table.clear(State.connections)
end

local function getScriptLineCount(scriptObj)
	if not scriptObj or not scriptObj:IsA("LuaSourceContainer") then return 0 end
	local success, source = pcall(function() return ScriptEditorService:GetEditorSource(scriptObj) end)
	if not success or not source then
		success, source = pcall(function() return scriptObj.Source end)
	end
	if not success or not source then return 0 end
	local _, count = source:gsub("\n", "")
	return count + 1
end

local function getScriptType(scriptObj)
	if not scriptObj then return ScriptTypes.DEVELOPING end

	if scriptObj:IsA("LocalScript") or (scriptObj:IsA("Script") and scriptObj.RunContext == Enum.RunContext.Client) then
		return ScriptTypes.CLIENT
	end

	if scriptObj:IsA("ModuleScript") then
		local ancestor = scriptObj.Parent
		while ancestor do
			if ancestor:IsA("ServerScriptService") or ancestor:IsA("ServerStorage") then
				return ScriptTypes.SERVER_MODULE
			elseif ancestor:IsA("StarterPlayer") or ancestor:IsA("StarterGui") or ancestor:IsA("StarterPack") then
				return ScriptTypes.CLIENT_MODULE
			end
			ancestor = ancestor.Parent
		end
		return ScriptTypes.MODULE
	end

	if scriptObj:IsA("Script") then
		return ScriptTypes.SERVER
	end

	return ScriptTypes.DEVELOPING
end

local function refreshWorkspaceCache()
	if game.PlaceId > 0 then
		local success, info = pcall(function() return MarketplaceService:GetProductInfoAsync(game.PlaceId) end)
		if success and info then
			State.cachedWorkspace.name = info.Name or "Published Place"
			State.cachedWorkspace.isPublic = true
			return
		end
	end
	State.cachedWorkspace.name = (game.Name ~= "Place" and game.Name ~= "") and game.Name or "Unsaved Studio Project"
	State.cachedWorkspace.isPublic = false
end

local function sendViaHTTP(payload)
	if not HttpService.HttpEnabled then return end
	task.spawn(function()
		local url = string.format("http://localhost:%d/rpc", FroststrapStudioRPC.Config.port)
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
			isRedundant = false; break
		end
	end
	if isRedundant then return end

	State.lastPayload = data
	State.isCooldown = true
	task.delay(2, function() State.isCooldown = false end)

	sendViaHTTP({
		command = "SetRichPresence",
		data = data
	})
end

function FroststrapStudioRPC.UpdatePresence()
	if not FroststrapStudioRPC.Config.enabled then return end

	local activeScript = StudioService.ActiveScript
	local scriptObj = (activeScript and activeScript:IsA("LuaSourceContainer")) and activeScript or nil

	if not scriptObj then
		local selected = Selection:Get()
		if #selected == 1 and selected[1]:IsA("LuaSourceContainer") then
			scriptObj = selected[1]
		end
	end

	local scriptType = getScriptType(scriptObj)
	local stateText = scriptObj and string.format("Editing %s (%d lines)", scriptObj.Name, getScriptLineCount(scriptObj)) or "Idling in Studio"

	FroststrapStudioRPC.SendMessage({
		details = State.cachedWorkspace.name,
		state = stateText,
		testing = RunService:IsRunning(),
		scriptType = scriptType,
		placeId = game.PlaceId,
		isPublic = State.cachedWorkspace.isPublic,
		devCount = math.max(1, #Players:GetPlayers())
	})
end

function FroststrapStudioRPC.SetEnabled(enabled)
	FroststrapStudioRPC.Config.enabled = enabled

	sendViaHTTP({
		command = "RPCToggle",
		data = { 
			enabled = enabled, 
			workspace = State.cachedWorkspace.name, 
			isPublic = State.cachedWorkspace.isPublic 
		}
	})

	if enabled then
		refreshWorkspaceCache()
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

	local httpSuccess, httpEnabled = pcall(function() return HttpService.HttpEnabled end)
	if httpSuccess and not httpEnabled then
		warn("Froststrap RPC: HTTP Requests are disabled. Please enable them in Experience Settings -> Security, this is necessery for Froststrap Studio RPC.")
	end

	local toggleAction = Plugin:CreatePluginAction(
		"toggle_rpc_command", "Toggle Froststrap RPC", "Toggle Discord Rich Presence logging", "rbxassetid://111400040119373", true
	)

	State.connections.Toggle = toggleAction.Triggered:Connect(function()
		FroststrapStudioRPC.SetEnabled(not FroststrapStudioRPC.Config.enabled)
	end)

	State.connections.UpdateTrigger = Selection.SelectionChanged:Connect(function()
		task.defer(FroststrapStudioRPC.UpdatePresence)
	end)

	State.connections.TabSwitch = StudioService:GetPropertyChangedSignal("ActiveScript"):Connect(function()
		task.defer(FroststrapStudioRPC.UpdatePresence)
	end)

	State.connections.Unload = Plugin.Unloading:Connect(function()
		FroststrapStudioRPC.SetEnabled(false)
		clearConnections()
	end)

	refreshWorkspaceCache()
	FroststrapStudioRPC.SetEnabled(FroststrapStudioRPC.Config.enabled)
	State.isInitialized = true
end

if Plugin then FroststrapStudioRPC.Initialize() end
return FroststrapStudioRPC