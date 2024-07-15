local _trace, _warn = util.global_log_factory("plugin/systemctl", "trace", "warn")

assert(os.execute('systemctl --version 2>&1 >/dev/null'), "systemctl not found")
assert(proc.EPROC, "systemctl plugin requires posix proc extra api (eli.proc.extra)")

local function get_systemd_version()
    --- check systemd version
    local p <close> = io.popen("systemctl --version")
    if not p then
        _trace("failed to get systemd version")
        return 0
    end
    local version = p:read("*a")
    --- e.g. systemd 249 (249.11-0ubuntu3.12)
    local ver = tonumber(version:match("systemd (%d+)"))
    return type(ver) == "number" and ver or 0
end

local supportsContainerFlag = get_systemd_version() >= 249

---@class SystemctlExecOptions
---@field container string?

---@class SystemctlInstallServiceOptions: SystemctlExecOptions
---@field kind string?
---@field daemonReload boolean?

---@class SystemctlRemoveServiceOptions: SystemctlExecOptions
---@field kind string?
---@field daemonReload boolean?

---@class Systemctl
---@field exec fun(options: SystemctlExecOptions?, ...: string): number, string, string
---@field install_service fun(sourceFile: string, serviceName: string, options: SystemctlInstallServiceOptions?)
---@field start_service fun(serviceName: string, options: SystemctlExecOptions?)
---@field stop_service fun(serviceName: string, options: SystemctlExecOptions?)
---@field remove_service fun(serviceName: string, options: SystemctlRemoveServiceOptions?)
---@field get_service_status fun(serviceName: string, options: SystemctlExecOptions?): string, string   
---@field with_options fun(options: SystemctlExecOptions): Systemctl

---@type Systemctl
---@diagnostic disable-next-line: missing-fields
local systemctl = {}

---executes systemctl command
---@param options SystemctlExecOptions?
---@param ... string
---@return number
---@return string
---@return string
function systemctl.exec(options, ...)
    if type(options) ~= "table" then
        options = {}
    end
    local bin = "systemctl"
    local args = { ... }
    local container = options.container
    if type(container) == "string" and container ~= "root" then
        if supportsContainerFlag then
            table.insert(args, 1, "--user")
            table.insert(args, 2, "-M")
            table.insert(args, 3, container .. "@")
        elseif os.execute("sudo --version 2>&1 >/dev/null") == 0 then -- sudo is available
            table.insert(args, 1, "-u")
            table.insert(args, 2, container)
            table.insert(args, 3, "systemctl")
            table.insert(args, 4, "--user")
            bin = "sudo"
        else
            error("systemctl.user is not supported on this system - needs systemd 248+ or sudo") 
        end
    end

    local _cmd = string.join_strings(" ", table.unpack(args))
    _trace("Executing systemctl " .. _cmd)
    local _proc = proc.spawn(bin, args, {stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
    if not _proc then
        error("Failed to execute systemctl command: " .. _cmd)
    end
    _trace("systemctl exit code: " .. _proc.exitcode)
    local _stderr = _proc.stderrStream:read("a")
    local _stdout = _proc.stdoutStream:read("a")
    return _proc.exitcode, _stdout, _stderr
end

---@param user string
---@return string
local function get_user_home(user)
    local _proc = proc.spawn("getent", { "passwd", user }, {stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
    if not _proc then
        error("Failed to execute getent command")
    end
    local _stdout = _proc.stdoutStream:read("a")
    local _stderr = _proc.stderrStream:read("a")
    if _proc.exitcode ~= 0 then
        error("failed to get home directory for user " .. user .. " - " .. _stderr)
    end
    local _home = _stdout:match("^.*:.*:.*:.*:.*:(.*):.*$")
    if not _home then
        _home = "/home/" .. user
    end
    return _home
end

---installs a service
---@param sourceFile string
---@param serviceName string
---@param options SystemctlInstallServiceOptions?
function systemctl.install_service(sourceFile, serviceName, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.kind) ~= "string" then
       options.kind = "service"
    end
    local container = options.container
    if type(container) == "string" and container ~= "root" then
        -- get home directory from passwd file
        local _home = get_user_home(container)
        local _ok, _uid = fs.safe_getuid(container)
        ami_assert(_ok, "Failed to get " .. container .. "uid - " .. (_uid or ""))

        local unitStorePath = _home .. "/.config/systemd/user/"
        local _ok, _error = fs.safe_mkdirp(unitStorePath .. "default.target.wants") -- create everything up to default.target.wants
        assert(_ok, "failed to create user unit store directory - " .. (_error or ""))
        
        local _ok, _error = fs.safe_copy_file(sourceFile, unitStorePath .. serviceName .. "." .. options.kind)
        assert(_ok, "failed to install " .. serviceName .. "." ..options.kind .. " - " .. (_error or ""))

        local _ok, _error = fs.chown(unitStorePath, _uid, _uid, { recurse = true })
        ami_assert(_ok, "Failed to chown reports - " .. (_error or ""))
    else
        local _ok, _error = fs.safe_copy_file(sourceFile, "/etc/systemd/system/" .. serviceName .. "." .. options.kind)
        assert(_ok, "failed to install " .. serviceName .. "." ..options.kind .. " - " .. (_error or ""))
    end

    if type(options.daemonReload) ~= "boolean" or options.daemonReload == true then
        local _exitcode, _stdout, _stderr = systemctl.exec(options, "daemon-reload")
        if _exitcode ~= 0 then
            _warn({ msg = "Failed to reload systemd daemon!", stdout = _stdout, stderr = _stderr })
        end
    end
    assert(systemctl.exec(options, "enable", serviceName .. "." .. options.kind) == 0, "Failed to enable service " .. serviceName .. "!")
end

---starts a service
---@param serviceName string
---@param options SystemctlExecOptions?
function systemctl.start_service(serviceName, options)
    _trace("Starting service: " .. serviceName)
    local _exitcode = systemctl.exec(options, "start", serviceName)
    assert(_exitcode == 0, "Failed to start service")
    _trace("Service " .. serviceName .. "started...")
end

---stops a service
---@param serviceName string
---@param options SystemctlExecOptions?
function systemctl.stop_service(serviceName, options)
    _trace("Stoping service: " .. serviceName)
    local _exitcode = systemctl.exec(options, "stop", serviceName)
    assert(_exitcode == 0, "Failed to stop service")
    _trace("Service " .. serviceName .. "stopped...")
end

---removes a service
---@param serviceName string
---@param options SystemctlRemoveServiceOptions?
function systemctl.remove_service(serviceName, options)
    if type(options) ~= "table" then 
        options = {}
    end
    if type(options.kind) ~= "string" then
       options.kind = "service"
    end

    local _serviceUnitFile = "/etc/systemd/system/" .. serviceName .. "." .. options.kind
    local container = options.container
    if type(container) == "string" and container ~= "root" then
        local _home = get_user_home(container)

        local unitStorePath = _home .. "/.config/systemd/user/"
        _serviceUnitFile = unitStorePath .. serviceName .. "." .. options.kind
    end
    if not fs.exists(_serviceUnitFile) then return end -- service not found so skip

    _trace("Removing service: " .. serviceName)
    local _exitcode = systemctl.exec(options, "stop", serviceName)
    assert(_exitcode == 0 or _exitcode == 5, "Failed to stop service")
    _trace("Service " .. serviceName .. "stopped...")

	_trace("Disabling service...")
	assert(systemctl.exec(options, "disable", serviceName .. "." .. options.kind) == 0, "Failed to disable service " .. serviceName .. "!")
	_trace("Service disabled.")

	_trace("Removing service...")
    local _ok, _error = fs.safe_remove(_serviceUnitFile)
    if not _ok then
        error("Failed to remove " .. serviceName .. "." .. options.kind ..  " - " .. (_error or ""))
    end

    if type(options.daemonReload) ~= "boolean" or options.daemonReload == true then
        local _exitcode, _stdout, _stderr = systemctl.exec(options, "daemon-reload")
        if _exitcode ~= 0 then
            _warn({ msg = "Failed to reload systemd daemon!", stdout = _stdout, stderr = _stderr })
        end
    end
    _trace("Service " .. serviceName .. "removed...")
end

---gets service status
---@param serviceName string
---@param options SystemctlExecOptions?
---@return string
---@return string
function systemctl.get_service_status(serviceName, options)
    _trace("Getting service " .. serviceName .. "status...")
    local _exitcode, _stdout = systemctl.exec(options, "show", "-p", "SubState", serviceName)
    assert(_exitcode == 0, "Failed to get service status")
    local _status = _stdout:match("SubState=%s*(%S*)")
    local _exitcode, _stdout = systemctl.exec(options, "show", "--timestamp=utc", "-p", "ExecMainStartTimestamp", serviceName)
    if _exitcode ~= 0 then -- fallback
        _exitcode, _stdout = systemctl.exec(options, "show", "-p", "ExecMainStartTimestamp", serviceName)
        assert(_exitcode == 0, "Failed to get service start timestamp")
        local _started = type(_stdout) == "string" and _stdout:match("^ExecMainStartTimestamp=%s*(.-)%s*$")
        -- adjust to UTC
        local _proc = proc.spawn(options, "date", { "-u",  "-d", tostring(_started), '+ExecMainStartTimestamp=%a %Y-%m-%d %H:%M:%S UTC' }, {stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
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

---creates a systemctl object with options preset
---@param options SystemctlExecOptions
---@return table
function systemctl.with_options(cachedOptions)
    local function patch_options(options)
        return util.merge_tables(cachedOptions, options, true)
    end

    ---@type Systemctl
    ---@diagnostic disable-next-line: missing-fields
    local systemctlWithOptions = {}
    function systemctlWithOptions.exec(options, ...)
        return systemctl.exec(patch_options(options), ...)
    end

    function systemctlWithOptions.install_service(sourceFile, serviceName, options)
        return systemctl.install_service(sourceFile, serviceName, patch_options(options))
    end

    function systemctlWithOptions.start_service(serviceName, options)
        return systemctl.start_service(serviceName, patch_options(options))
    end

    function systemctlWithOptions.stop_service(serviceName, options)
        return systemctl.stop_service(serviceName, patch_options(options))
    end

    function systemctlWithOptions.remove_service(serviceName, options)
        return systemctl.remove_service(serviceName, patch_options(options))
    end

    function systemctlWithOptions.get_service_status(serviceName, options)
        return systemctl.get_service_status(serviceName, patch_options(options))
    end

    return util.generate_safe_functions(systemctlWithOptions)
end

return util.generate_safe_functions(systemctl)
