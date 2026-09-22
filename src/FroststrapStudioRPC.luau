local Selection          = game:GetService("Selection")
local RunService         = game:GetService("RunService")
local HttpService        = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players           = game:GetService("Players")
local StudioService      = game:GetService("StudioService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local FroststrapStudioRPC = {}
local Plugin = if plugin then plugin else nil

FroststrapStudioRPC.Config = {
	enabled        = true,
	httpTimeout    = 2,
	updateInterval = 10,
	port           = 4875,
	icon           = "rbxassetid://111400040119373",
}

local ScriptTypes = {
	SERVER        = "Server Script",
	CLIENT        = "Local Script",
	SERVER_MODULE = "Server Module",
	CLIENT_MODULE = "Client Module",
	MODULE        = "Module",
	DEVELOPING    = "Developing",
}

local State = {
	connected        = false,
	isCooldown       = false,
	lastPayloadKey   = "",
	lastScriptRef    = nil,
	lastScriptLen    = -1,
	lastScriptLines  = 0,
	initialized      = false,
	monitorToken     = 0,
	toolbar          = nil,
	toggleButton     = nil,
	connections      = {},
	workspace = {
		name     = "Unsaved Studio Project",
		isPublic = false,
		placeId  = -1,
	},
}

local function disconnectAll()
	for _, c in pairs(State.connections) do
		if c then c:Disconnect() end
	end
	table.clear(State.connections)
end

local function getScriptLineCount(scriptObj)
	if not scriptObj or not scriptObj:IsA("LuaSourceContainer") then
		return 0
	end

	local source
	local ok, s = pcall(function() return ScriptEditorService:GetEditorSource(scriptObj) end)
	if ok and type(s) == "string" then
		source = s
	else
		local ok2, s2 = pcall(function() return scriptObj.Source end)
		if ok2 and type(s2) == "string" then
			source = s2
		end
	end
	if not source then return 0 end

	if scriptObj == State.lastScriptRef and #source == State.lastScriptLen then
		return State.lastScriptLines
	end

	local _, newlines = source:gsub("\n", "")
	local lines = newlines + 1
	State.lastScriptRef   = scriptObj
	State.lastScriptLen   = #source
	State.lastScriptLines = lines
	return lines
end

local function getScriptType(scriptObj)
	if not scriptObj then return ScriptTypes.DEVELOPING end

	if scriptObj:IsA("LocalScript")
		or (scriptObj:IsA("Script") and scriptObj.RunContext == Enum.RunContext.Client) then
		return ScriptTypes.CLIENT
	end

	if scriptObj:IsA("ModuleScript") then
		local ancestor = scriptObj.Parent
		while ancestor do
			if ancestor:IsA("ServerScriptService") or ancestor:IsA("ServerStorage") then
				return ScriptTypes.SERVER_MODULE
			elseif ancestor:IsA("StarterPlayer")
				or ancestor:IsA("StarterGui")
				or ancestor:IsA("StarterPack") then
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
	State.workspace.placeId = game.PlaceId

	if game.PlaceId > 0 then
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfoAsync(game.PlaceId)
		end)
		if ok and type(info) == "table" then
			State.workspace.name     = info.Name or "Published Place"
			State.workspace.isPublic = true
			return
		end
	end

	State.workspace.name = (game.Name ~= "Place" and game.Name ~= "")
		and game.Name
		or "Unsaved Studio Project"
	State.workspace.isPublic = false
end

local function sendViaHTTP(payload)
	local encoded = HttpService:JSONEncode(payload)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url     = string.format("http://localhost:%d/rpc",
				FroststrapStudioRPC.Config.port),
			Method  = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body    = encoded,
			Timeout = FroststrapStudioRPC.Config.httpTimeout,
		})
	end)
	if ok and response ~= nil and response.Success == true then
		return true, response
	end
	return false, response
end

local function clearPresence()
	sendViaHTTP({
		command = "SetRichPresence",
		data    = { sharing = false },
	})
end

local function refreshButtonVisuals()
	local button = State.toggleButton
	if not button then return end
	local enabled = FroststrapStudioRPC.Config.enabled
	local status
	if not enabled then
		status = "disabled"
	elseif State.connected then
		status = "connected"
	else
		status = "waiting for app"
	end
	pcall(function()
		button:SetActive(enabled)
		button:SetTooltip(string.format("Froststrap RPC: %s", status))
	end)
end

function FroststrapStudioRPC.SendMessage(data)
	if not FroststrapStudioRPC.Config.enabled then
		return false
	end

	if State.isCooldown then
		return false
	end

	local key = HttpService:JSONEncode(data)
	if key == State.lastPayloadKey and State.connected then
		return true
	end

	State.isCooldown = true
	task.delay(2, function() State.isCooldown = false end)

	local ok = sendViaHTTP({
		command = "SetRichPresence",
		data    = data,
	})

	if ok then
		State.lastPayloadKey = key
	end

	if ok ~= State.connected then
		State.connected = ok
		refreshButtonVisuals()
	end
	return ok
end

function FroststrapStudioRPC.UpdatePresence()
	if not FroststrapStudioRPC.Config.enabled then return end

	local activeScript = StudioService.ActiveScript
	local scriptObj = (activeScript and activeScript:IsA("LuaSourceContainer"))
		and activeScript or nil

	if not scriptObj then
		local selected = Selection:Get()
		if #selected == 1 and selected[1]:IsA("LuaSourceContainer") then
			scriptObj = selected[1]
		end
	end

	local scriptType = getScriptType(scriptObj)
	local stateText
	if scriptObj then
		stateText = string.format("Editing %s (%d lines)",
			scriptObj.Name, getScriptLineCount(scriptObj))
	else
		stateText = "Idling in Studio"
	end

	FroststrapStudioRPC.SendMessage({
		details    = State.workspace.name,
		state      = stateText,
		testing    = RunService:IsRunning(),
		scriptType = scriptType,
		placeId    = game.PlaceId,
		isPublic   = State.workspace.isPublic,
		devCount   = math.max(1, #Players:GetPlayers()),
	})
end

function FroststrapStudioRPC.SetEnabled(enabled, persist)
	enabled = enabled ~= false
	FroststrapStudioRPC.Config.enabled = enabled

	if persist and Plugin then
		pcall(function()
			Plugin:SetSetting("FroststrapRPCEnabled", enabled)
		end)
	end

	if enabled then
		sendViaHTTP({
			command = "RPCToggle",
			data    = {
				enabled   = true,
				workspace = State.workspace.name,
				isPublic  = State.workspace.isPublic,
			},
		})
	else
		sendViaHTTP({
			command = "RPCToggle",
			data    = {
				enabled   = false,
				workspace = State.workspace.name,
				isPublic  = State.workspace.isPublic,
			},
		})
		clearPresence()
		State.lastPayloadKey = ""
		State.connected      = false
	end

	State.monitorToken += 1
	local myToken = State.monitorToken

	if enabled then
		refreshWorkspaceCache()
		task.spawn(function()
			FroststrapStudioRPC.UpdatePresence()
		end)
		task.spawn(function()
			while FroststrapStudioRPC.Config.enabled
				and State.monitorToken == myToken do
				task.wait(FroststrapStudioRPC.Config.updateInterval)
				if not FroststrapStudioRPC.Config.enabled
					or State.monitorToken ~= myToken then
					break
				end
				FroststrapStudioRPC.UpdatePresence()
			end
		end)
	end

	refreshButtonVisuals()
end

function FroststrapStudioRPC.Shutdown()
	FroststrapStudioRPC.Config.enabled = false
	State.monitorToken += 1
	sendViaHTTP({
		command = "RPCToggle",
		data    = {
			enabled   = false,
			workspace = State.workspace.name,
			isPublic  = State.workspace.isPublic,
		},
	})
	clearPresence()
	State.lastPayloadKey = ""
	State.connected      = false
	disconnectAll()
end

function FroststrapStudioRPC.Initialize()
	if State.initialized or not Plugin then return end
	State.initialized = true

	local saved
	pcall(function()
		saved = Plugin:GetSetting("FroststrapRPCEnabled")
	end)
	if type(saved) == "boolean" then
		FroststrapStudioRPC.Config.enabled = saved
	end

	local toolbar = Plugin:CreateToolbar("Froststrap")
	State.toolbar = toolbar

	local toggleButton = toolbar:CreateButton(
		"Froststrap",
		"Toggle Froststrap RPC",
		FroststrapStudioRPC.Config.icon
	)
	toggleButton.ClickableWhenViewportHidden = true
	State.toggleButton = toggleButton

	State.connections.Toggle = toggleButton.Click:Connect(function()
		FroststrapStudioRPC.SetEnabled(
			not FroststrapStudioRPC.Config.enabled,
			true
		)
	end)

	State.connections.Selection = Selection.SelectionChanged:Connect(function()
		task.defer(FroststrapStudioRPC.UpdatePresence)
	end)

	State.connections.ActiveScript =
		StudioService:GetPropertyChangedSignal("ActiveScript"):Connect(function()
			task.defer(FroststrapStudioRPC.UpdatePresence)
		end)

	State.connections.Unload = Plugin.Unloading:Connect(function()
		FroststrapStudioRPC.Shutdown()
	end)

	refreshWorkspaceCache()
	FroststrapStudioRPC.SetEnabled(FroststrapStudioRPC.Config.enabled, false)
end

if Plugin then
	FroststrapStudioRPC.Initialize()
end

return FroststrapStudioRPC