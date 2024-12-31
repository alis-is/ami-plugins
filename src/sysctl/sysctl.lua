local config_file = "/etc/sysctl.d/99-ami-sysctl.conf"

local sysctl = {}
local log_trace, log_debug, log_error = util.global_log_factory("plugin/sysctl", "trace", "debug", "error")

function sysctl.set(variable, value)
	local err_msg = "Failed to set " .. tostring(variable) .. " to " .. tostring(value) .. "!"
	local config_file_content = ""
	if fs.exists(config_file_content) then 
		config_file_content = fs.read_file(config_file)
	end
	local value = config_file_content:match(variable .. " = (%S*)")
	if config_file_content[#config_file_content] ~= '\n' then 
		config_file_content = config_file_content .. '\n'
	end
	if value == nil then 
		config_file_content = config_file_content:gsub(variable .. " = (%S*)%s-\n", "")
	elseif value then 
		log_trace("Variable found rewriting...")
		config_file_content = config_file_content:gsub(variable .. " = (%S*)", variable .. " = " .. value)
	else 
		log_trace("Variable not found. Adding new record.")
		config_file_content = config_file_content .. variable .. " = " .. value .. "\n"
	end
	local tmp_file_path = os.tmpname()
	fs.write_file(tmp_file_path, config_file_content)
	fs.move(tmp_file_path, config_file)
	assert(os.execute("sysctl -p " .. config_file), err_msg)
	log_debug("Sysctl variable " .. variable .. " set to " .. tostring(value));
end

function sysctl.get(variable)
	local err_msg = "Failed to get value of " .. tostring(variable) .. "!"
	local process_info = proc.exec("sysctl " .. variable, {stdout = "pipe", stderr = "pipe"})
	if (process_info.exit_code ~= 0) then 
		log_error(err_msg .. "\nstderr: " .. tostring(process_info.stderr_stream:read("a")))
	end
	local output = process_info.stdout_stream:read("a")
	local result = tostring(output):match(variable .. " = (%S*)")
	return result and result:match'^%s*(.*%S)'
end

function sysctl.unset(variable)
	local err_msg = "Failed to unset " .. tostring(variable) .. "!"
	sysctl.set(variable)
	assert(os.execute("sysctl -p"), err_msg)
end

return util.generate_safe_functions(sysctl)