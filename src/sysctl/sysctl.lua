local _configFile = "/etc/sysctl.d/99-ami-sysctl.conf"

local sysctl = {}
local _trace, _debug, _error = util.global_log_factory("plugin/sysctl", "trace", "debug", "error")

function sysctl.set(variable, value)
	local _errMsg = "Failed to set " .. tostring(variable) .. " to " .. tostring(value) .. "!"
	local _configFileContent = ""
	if fs.exists(_configFileContent) then 
		_configFileContent = fs.read_file(_configFile)
	end
	local _value = _configFileContent:match(variable .. " = (%S*)")
	if _configFileContent[#_configFileContent] ~= '\n' then 
		_configFileContent = _configFileContent .. '\n'
	end
	if value == nil then 
		_configFileContent = _configFileContent:gsub(variable .. " = (%S*)%s-\n", "")
	elseif _value then 
		_trace("Variable found rewriting...")
		_configFileContent = _configFileContent:gsub(variable .. " = (%S*)", variable .. " = " .. value)
	else 
		_trace("Variable not found. Adding new record.")
		_configFileContent = _configFileContent .. variable .. " = " .. value .. "\n"
	end
	local _tmpFile = os.tmpname()
	fs.write_file(_tmpFile, _configFileContent)
	fs.move(_tmpFile, _configFile)
	assert(os.execute("sysctl -p " .. _configFile), _errMsg)
	_debug("Sysctl variable " .. variable .. " set to " .. tostring(value));
end

function sysctl.get(variable)
	local _errMsg = "Failed to get value of " .. tostring(variable) .. "!"
	local _processInfo = proc.exec("sysctl " .. variable, {stdout = "pipe", stderr = "pipe"})
	if (_processInfo.exitcode ~= 0) then 
		_error(_errMsg .. "\nStderr: " .. tostring(_processInfo.stderrStream:read("a")))
	end
	local _output = _processInfo.stdoutStream:read("a")
	local _result = tostring(_output):match(variable .. " = (%S*)")
	return _result and _result:match'^%s*(.*%S)'
end

function sysctl.unset(variable)
	local _errMsg = "Failed to unset " .. tostring(variable) .. "!"
	sysctl.set(variable)
	assert(os.execute("sysctl -p"), _errMsg)
end

return util.generate_safe_functions(sysctl)