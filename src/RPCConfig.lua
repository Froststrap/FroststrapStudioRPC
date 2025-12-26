local RPCConfig = {
	enabled = true,
	showSeparator = true,
	idleTimeout = 30,
	idleCheckInterval = 15
}

function RPCConfig.validate()
	if RPCConfig.idleTimeout < 10 then
		RPCConfig.idleTimeout = 10
	end
end

return RPCConfig