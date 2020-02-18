local _trace, _debug = require"eli.util".global_log_factory("plugin/systemctl", "trace", "debug")
local _eprocLoaded, _eProc = pcall(require, "eli.proc.extra")
local _eliUtil = require "eli.util"
local _eliFs = require"eli.fs"

assert(os.execute('systemctl --version 2>&1 >/dev/null'), "systemctl not found")
assert(_eprocLoaded, "systemctl plugin requires posix proc extra api (eli.proc.extra)")

local _exec_systemctl = function(...)
    local _cmd = exString.join_strings(" ", ...)
    local _rd, _proc_wr = eliFs.pipe()
    local _rderr, _proc_werr = eliFs.pipe()

    log_trace("Executing systemctl " .. _cmd)
    local _proc, _err = eliProc.spawn {"systemctl", args = { ... }, stdout = _proc_wr, stderr = _proc_werr}
    _proc_wr:close()
    _proc_werr:close()

    if not _proc then
        _rd:close()
        _rderr:close()
        error("Failed to execute systemctl command: " .. _cmd)
    end
    local _exitcode = _proc:wait() 
    log_trace("systemctl exit code: " .. _exitcode)
    local _stderr = _rderr:read("a")
    local _stdout = _rd:read("a")
    assert(_exitcode == 0, "Failed to execute systemctl command: " .. _cmd)
    return _exitcode, _stdout, _stderr
end

local function _install_service(sourceFile, serviceName)
    local _ok, _error = _eliFs.safe_copy_file(sourceFile, "/etc/systemd/system/" .. serviceName .. ".service")
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
    _stop_service(serviceName)
    _trace("Service " .. serviceName .. "stopped...")
    local _ok, _error = _eliFs.safe_remove("/etc/systemd/system/" .. serviceName .. ".service")
    assert(_ok, "Failed to remove " .. serviceName .. ".service - " .. (_error or ""))
    _exec_systemctl("daemon-reload")
    _trace("Service " .. serviceName .. "removed...")
end

local function _get_service_status(serviceName)
    _trace("Getting service " .. serviceName .. "status...")
    local _exitcode, _stdout = _exec_systemctl("show", "-p", "SubState", "--value", serviceName)
    assert(_exitcode == 0, "Failed to get service status")
    local _status = _stdout:match("%s*(%S*)")
    _trace("Got service " .. serviceName .. " status - " .. (_status or ""))
    return _status
end

return generate_safe_functions({
    install_service = _install_service,
    start_service = _start_service,
    stop_service = _stop_service,
    get_service_status = _get_service_status
})