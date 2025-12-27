local RPCDataLogger = {}

local function isPluginContext()
	return pcall(function() return plugin ~= nil end)
end

local Selection = nil
if isPluginContext() then
	Selection = game:GetService("Selection")
end

local enabled = true
local lastScriptName = ""
local lastPlaceName = ""
local lastActivity = ""
local lastTestingState = false
local logCooldown = false

function RPCDataLogger.getSelectedScript()
	if not Selection then return nil end

	local success, result = pcall(function()
		return Selection:Get()
	end)

	if not success then return nil end

	for _, obj in ipairs(result) do
		if obj:IsA("LuaSourceContainer") then
			return obj
		end
	end

	return nil
end

function RPCDataLogger.getScriptLineCount(scriptObj)
	if not scriptObj then return 0 end

	local source = scriptObj.Source or ""
	if source == "" then return 1 end

	local lines = 1
	for i = 1, #source do
		if string.sub(source, i, i) == "\n" then
			lines = lines + 1
		end
	end

	return lines
end

function RPCDataLogger.getScriptType(scriptObj)
	if not scriptObj then return "Unknown" end

	if scriptObj:IsA("LocalScript") then
		return "Client"
	end

	if scriptObj:IsA("Script") then
		local parent = scriptObj.Parent
		while parent do
			if parent:IsA("StarterPlayerScripts") or parent:IsA("StarterCharacterScripts") or 
				parent:IsA("StarterGui") or parent:IsA("PlayerScripts") then
				return "Client"
			end
			parent = parent.Parent
		end
		return "Server"
	end

	if scriptObj:IsA("ModuleScript") then
		local parent = scriptObj.Parent
		while parent do
			if parent:IsA("ServerScriptService") or parent:IsA("ServerStorage") then
				return "Server Module"
			elseif parent:IsA("StarterPlayerScripts") or parent:IsA("StarterCharacterScripts") or 
				parent:IsA("StarterGui") or parent:IsA("PlayerScripts") then
				return "Client Module"
			end
			parent = parent.Parent
		end
		return "Module"
	end

	return "Unknown"
end

function RPCDataLogger.getActivityStatus()
	if RPCDataLogger.getSelectedScript() then
		return "Editing"
	end
	return "Developing"
end

function RPCDataLogger.isTesting()
	local success, result = pcall(function()
		return game:GetService("RunService"):IsRunning()
	end)
	return success and result
end

function RPCDataLogger.collectData()
	if not enabled then return nil end

	local data = {
		activity = RPCDataLogger.getActivityStatus(),
		testing = RPCDataLogger.isTesting()
	}

	data.place = {
		name = game.Name,
		placeId = game.PlaceId
	}

	local selectedScript = RPCDataLogger.getSelectedScript()

	if selectedScript then
		data.script = {
			name = selectedScript.Name,
			className = selectedScript.ClassName,
			lines = RPCDataLogger.getScriptLineCount(selectedScript),
			type = RPCDataLogger.getScriptType(selectedScript)
		}
	else
		data.script = {name = "None", lines = 0, type = "None"}
	end

	return data
end

function RPCDataLogger.logData(data)
	if not data or not enabled or logCooldown then return end

	logCooldown = true
	task.spawn(function()
		task.wait(0.2)
		logCooldown = false
	end)

	local scriptChanged = data.script.name ~= lastScriptName
	local activityChanged = data.activity ~= lastActivity
	local placeChanged = data.place.name ~= lastPlaceName
	local testingChanged = data.testing ~= lastTestingState

	if not (scriptChanged or activityChanged or placeChanged or testingChanged) then
		return
	end

	local testingText = data.testing and "True" or "False"

	if data.activity == "Editing" and data.script.name ~= "None" then
		local displayText
		local scriptType = "unknown"

		if data.script.type == "Server" then
			displayText = string.format("Server - %s", data.script.name)
			scriptType = "server"
		elseif data.script.type == "Client" then
			displayText = string.format("Client - %s", data.script.name)
			scriptType = "client"
		elseif data.script.type == "Server Module" then
			displayText = string.format("Server Module - %s", data.script.name)
			scriptType = "server_module"
		elseif data.script.type == "Client Module" then
			displayText = string.format("Client Module - %s", data.script.name)
			scriptType = "client_module"
		elseif data.script.type == "Module" then
			displayText = string.format("Module - %s", data.script.name)
			scriptType = "module"
		else
			displayText = data.script.name
			scriptType = "unknown"
		end

		RPCDataLogger.printWithPrefix(string.format(
			"Editing %s (%d lines) | Workspace: %s | Testing: %s | Type: %s",
			displayText,
			data.script.lines,
			data.place.name,
			testingText,
			scriptType
			))
	else
		RPCDataLogger.printWithPrefix(string.format(
			"%s | Workspace: %s | Testing: %s | Type: %s",
			data.activity,
			data.place.name,
			testingText,
			"developing"
			))
	end

	lastScriptName = data.script.name
	lastActivity = data.activity
	lastPlaceName = data.place.name
	lastTestingState = data.testing
end

function RPCDataLogger.printWithPrefix(message)
	if not enabled then return end
	print("[FroststrapStudioRPC] " .. tostring(message))
end

function RPCDataLogger.setupEventListeners()
	if not Selection then return end

	Selection.SelectionChanged:Connect(function()
		if not enabled then return end

		task.wait(0.05)

		local data = RPCDataLogger.collectData()
		RPCDataLogger.logData(data)
	end)
end

function RPCDataLogger.initialize()
	if isPluginContext() then
		RPCDataLogger.setupEventListeners()

		local initialData = RPCDataLogger.collectData()
		RPCDataLogger.logData(initialData)

		task.spawn(function()
			while enabled do
				task.wait(1)

				if enabled then
					local data = RPCDataLogger.collectData()
					RPCDataLogger.logData(data)
				end
			end
		end)
	end
end

function RPCDataLogger.setEnabled(state)
	enabled = state
	if isPluginContext() then
		RPCDataLogger.printWithPrefix(state and "ENABLED" or "DISABLED")
	end
end

function RPCDataLogger.isEnabled()
	return enabled
end

function RPCDataLogger.cleanup()
	enabled = false
	if isPluginContext() then
		RPCDataLogger.printWithPrefix("Unloading...")
	end
end

return RPCDataLogger