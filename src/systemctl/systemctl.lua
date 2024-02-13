local _trace, _warn = util.global_log_factory("plugin/systemctl", "trace", "warn")

assert(os.execute('systemctl --version 2>&1 >/dev/null'), "systemctl not found")
assert(proc.EPROC, "systemctl plugin requires posix proc extra api (eli.proc.extra)")

local _systemctl = {}

function _systemctl.exec(...)
    local _cmd = string.join_strings(" ", ...)
    _trace("Executing systemctl " .. _cmd)
    local _proc = proc.spawn("systemctl", { ... }, {stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
    if not _proc then
        error("Failed to execute systemctl command: " .. _cmd)
    end
    _trace("systemctl exit code: " .. _proc.exitcode)
    local _stderr = _proc.stderrStream:read("a")
    local _stdout = _proc.stdoutStream:read("a")
    return _proc.exitcode, _stdout, _stderr
end

function _systemctl.install_service(sourceFile, serviceName, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.kind) ~= "string" then
       options.kind = "service"
    end
    local _ok, _error = fs.safe_copy_file(sourceFile, "/etc/systemd/system/" .. serviceName .. "." .. options.kind)
    assert(_ok, "Failed to install " .. serviceName .. "." ..options.kind .. " - " .. (_error or ""))

    if type(options.daemonReload) ~= "boolean" or options.daemonReload == true then
        local _exitcode, _stdout, _stderr = _systemctl.exec("daemon-reload")
        if _exitcode ~= 0 then
            _warn({ msg = "Failed to reload systemd daemon!", stdout = _stdout, stderr = _stderr })
        end
    end
    assert(_systemctl.exec("enable", serviceName .. "." .. options.kind) == 0, "Failed to enable service " .. serviceName .. "!")
end

function _systemctl.start_service(serviceName)
    _trace("Starting service: " .. serviceName)
    local _exitcode = _systemctl.exec("start", serviceName)
    assert(_exitcode == 0, "Failed to start service")
    _trace("Service " .. serviceName .. "started...")
end

function _systemctl.stop_service(serviceName)
    _trace("Stoping service: " .. serviceName)
    local _exitcode = _systemctl.exec("stop", serviceName)
    assert(_exitcode == 0, "Failed to stop service")
    _trace("Service " .. serviceName .. "stopped...")
end

function _systemctl.remove_service(serviceName, options)
    if type(options) ~= "table" then 
        options = {}
    end
    if type(options.kind) ~= "string" then
       options.kind = "service"
    end
    local _serviceUnitFile = "/etc/systemd/system/" .. serviceName .. "." .. options.kind
    if not fs.exists(_serviceUnitFile) then return end -- service not found so skip

    _trace("Removing service: " .. serviceName)
    local _exitcode = _systemctl.exec("stop", serviceName)
    assert(_exitcode == 0 or _exitcode == 5, "Failed to stop service")
    _trace("Service " .. serviceName .. "stopped...")

	_trace("Disabling service...")
	assert(_systemctl.exec("disable", serviceName .. "." .. options.kind) == 0, "Failed to disable service " .. serviceName .. "!")
	_trace("Service disabled.")

	_trace("Removing service...")
    local _ok, _error = fs.safe_remove(_serviceUnitFile)
    if not _ok then
        error("Failed to remove " .. serviceName .. "." .. options.kind ..  " - " .. (_error or ""))
    end

    if type(options.daemonReload) ~= "boolean" or options.daemonReload == true then
        local _exitcode, _stdout, _stderr = _systemctl.exec("daemon-reload")
        if _exitcode ~= 0 then
            _warn({ msg = "Failed to reload systemd daemon!", stdout = _stdout, stderr = _stderr })
        end
    end
    _trace("Service " .. serviceName .. "removed...")
end

function _systemctl.get_service_status(serviceName)
    _trace("Getting service " .. serviceName .. "status...")
    local _exitcode, _stdout = _systemctl.exec("show", "-p", "SubState", serviceName)
    assert(_exitcode == 0, "Failed to get service status")
    local _status = _stdout:match("SubState=%s*(%S*)")
    local _exitcode, _stdout = _systemctl.exec("show", "--timestamp=utc", "-p", "ExecMainStartTimestamp", serviceName)
    if _exitcode ~= 0 then -- fallback
        _exitcode, _stdout = _systemctl.exec("show", "-p", "ExecMainStartTimestamp", serviceName)
        assert(_exitcode == 0, "Failed to get service start timestamp")
        local _started = type(_stdout) == "string" and _stdout:match("^ExecMainStartTimestamp=%s*(.-)%s*$")
        -- adjust to UTC
        local _proc = proc.spawn("date", { "-u",  "-d", tostring(_started), '+ExecMainStartTimestamp=%a %Y-%m-%d %H:%M:%S UTC' }, {stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
        if not _proc then
            error("Failed to execute date command")
        end
        _trace("date exit code: " .. _proc.exitcode)
        _stdout = _proc.stdoutStream:read("a")
        _exitcode = _proc.exitcode
    end
    assert(_exitcode == 0, "Failed to get service start timestamp")
    local _started = type(_stdout) == "string" and _stdout:match("^ExecMainStartTimestamp=%s*(.-)%s*$")
    _trace("Got service " .. serviceName .. " status - " .. (_status or ""))
    return _status, _started
end

return util.generate_safe_functions(_systemctl)
