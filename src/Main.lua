local RPCDataLogger = require(script.Parent.RPCDataLogger)

if plugin then
	local toolbar = plugin:CreateToolbar("Froststrap RPC")
	local button = toolbar:CreateButton("RPC Logger", "Toggle RPC logging", "")
	local isEnabled = true

	button:SetActive(true)

	button.Click:Connect(function()
		isEnabled = not isEnabled
		RPCDataLogger.setEnabled(isEnabled)
		button:SetActive(isEnabled)
	end)

	plugin.Unloading:Connect(function()
		RPCDataLogger.cleanup()
	end)
end

RPCDataLogger.initialize()