local _trace, _debug = util.global_log_factory("plugin/systemctl", "trace", "debug")

assert(os.execute('systemctl --version 2>&1 >/dev/null'), "systemctl not found")
assert(proc.EPROC, "systemctl plugin requires posix proc extra api (eli.proc.extra)")

local _exec_systemctl = function(...)
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

local function _install_service(sourceFile, serviceName)
    local _ok, _error = fs.safe_copy_file(sourceFile, "/etc/systemd/system/" .. serviceName .. ".service")
    assert(_ok, "Failed to install " .. serviceName .. ".service - " .. (_error or ""))
    _exec_systemctl("daemon-reload")
    _exec_systemctl("enable", serviceName .. ".service")
end

local function _start_service(serviceName)
    _trace("Starting service: " .. serviceName)
    local _exitcode = _exec_systemctl("start", serviceName)
    assert(_exitcode == 0, "Failed to start service")
    _trace("Service " .. serviceName .. "started...")
end

local function _stop_service(serviceName)
    _trace("Stoping service: " .. serviceName)
    local _exitcode = _exec_systemctl("stop", serviceName)
    assert(_exitcode == 0, "Failed to stop service")
    _trace("Service " .. serviceName .. "stopped...")
end

local function _remove_service(serviceName)
    _trace("Removing service: " .. serviceName)
    local _exitcode = _exec_systemctl("stop", serviceName)
    assert(_exitcode == 0 or _exitcode == 5, "Failed to stop service")
    _trace("Service " .. serviceName .. "stopped...")
    local _ok, _error = fs.safe_remove("/etc/systemd/system/" .. serviceName .. ".service")
    if not _ok then
        error("Failed to remove " .. serviceName .. ".service - " .. (_error or ""))
    end
    _exec_systemctl("daemon-reload")
    _trace("Service " .. serviceName .. "removed...")
end

local function _get_service_status(serviceName)
    _trace("Getting service " .. serviceName .. "status...")
    local _exitcode, _stdout = _exec_systemctl("show", "-p", "SubState", "--value", serviceName)
    assert(_exitcode == 0, "Failed to get service status")
    local _status = _stdout:match("%s*(%S*)")
    local _exitcode, _stdout = _exec_systemctl("show", "-p", "ExecMainStartTimestamp", "--value", serviceName)
    assert(_exitcode == 0, "Failed to get service start timestamp")
    local _started = type(_stdout) == "string" and _stdout:gsub("^%s*(.-)%s*$", "%1")
    _trace("Got service " .. serviceName .. " status - " .. (_status or ""))
    return _status, _started
end

return util.generate_safe_functions({
    install_service = _install_service,
    start_service = _start_service,
    stop_service = _stop_service,
    remove_service = _remove_service,
    get_service_status = _get_service_status
})