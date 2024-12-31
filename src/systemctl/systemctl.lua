local log_trace, log_warn = util.global_log_factory("plugin/systemctl", "trace", "warn")

assert(os.execute('systemctl --version 2>&1 >/dev/null'), "systemctl not found")
assert(proc.EPROC, "systemctl plugin requires posix proc extra api (eli.proc.extra)")

local function get_systemd_version()
    --- check systemd version
    local p <close> = io.popen("systemctl --version")
    if not p then
        log_trace("failed to get systemd version")
        return 0
    end
    local version = p:read("*a")
    --- e.g. systemd 249 (249.11-0ubuntu3.12)
    local ver = tonumber(version:match("systemd (%d+)"))
    return type(ver) == "number" and ver or 0
end

local supports_container_flag = get_systemd_version() >= 249

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
---@field install_service fun(source_file: string, service_name: string, options: SystemctlInstallServiceOptions?)
---@field start_service fun(service_name: string, options: SystemctlExecOptions?)
---@field stop_service fun(service_name: string, options: SystemctlExecOptions?)
---@field remove_service fun(service_name: string, options: SystemctlRemoveServiceOptions?)
---@field get_service_status fun(service_name: string, options: SystemctlExecOptions?): string, string
---@field is_service_installed fun(service_name: string, options: SystemctlRemoveServiceOptions?): boolean
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
        if supports_container_flag then
            table.insert(args, 1, "--user")
            table.insert(args, 2, "-M")
            table.insert(args, 3, container .. "@")
        elseif os.execute("which sudo 2>&1 >/dev/null") == 0 then -- sudo is available
            table.insert(args, 1, "-u")
            table.insert(args, 2, container)
            table.insert(args, 3, "systemctl")
            table.insert(args, 4, "--user")
            bin = "sudo"
        else
            error("systemctl.user is not supported on this system - needs systemd 248+ or sudo")
        end
    end

    local cmd = string.join_strings(" ", table.unpack(args))
    log_trace("Executing systemctl " .. cmd)
    local process = proc.spawn(bin, args, { stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
    if not process then
        error("Failed to execute systemctl command: " .. cmd)
    end
    log_trace("systemctl exit code: " .. process.exit_code)
    local stderr = process.stderr_stream:read("a")
    local stdout = process.stdout_stream:read("a")
    return process.exit_code, stdout, stderr
end

---@param user string
---@return string
local function get_user_home(user)
    local process = proc.spawn("getent", { "passwd", user }, { stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
    if not process then
        error("Failed to execute getent command")
    end
    local stdout = process.stdout_stream:read("a")
    local stderr = process.stderr_stream:read("a")
    if process.exit_code ~= 0 then
        error("failed to get home directory for user " .. user .. " - " .. stderr)
    end
    local home = stdout:match("^.*:.*:.*:.*:.*:(.*):.*$")
    if not home then
        home = "/home/" .. user
    end
    return home
end

---installs a service
---@param source_file string
---@param service_name string
---@param options SystemctlInstallServiceOptions?
function systemctl.install_service(source_file, service_name, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.kind) ~= "string" then
        options.kind = "service"
    end
    local container = options.container
    if type(container) == "string" and container ~= "root" then
        -- get home directory from passwd file
        local home = get_user_home(container)
        local ok, uid = fs.safe_getuid(container)
        ami_assert(ok, "Failed to get " .. container .. "uid - " .. (uid or ""))

        local unit_store_path = home .. "/.config/systemd/user/"
        local ok, err = fs.safe_mkdirp(unit_store_path .. "default.target.wants") -- create everything up to default.target.wants
        assert(ok, "failed to create user unit store directory - " .. (err or ""))

        local ok, err = fs.safe_copy_file(source_file, unit_store_path .. service_name .. "." .. options.kind)
        assert(ok, "failed to install " .. service_name .. "." .. options.kind .. " - " .. (err or ""))

        local ok, err = fs.chown(unit_store_path, uid, uid, { recurse = true })
        ami_assert(ok, "Failed to chown reports - " .. (err or ""))
    else
        local ok, err = fs.safe_copy_file(source_file, "/etc/systemd/system/" .. service_name .. "." .. options.kind)
        assert(ok, "failed to install " .. service_name .. "." .. options.kind .. " - " .. (err or ""))
    end

    if type(options.daemonReload) ~= "boolean" or options.daemonReload == true then
        local exit_code, stdout, stderr = systemctl.exec(options, "daemon-reload")
        if exit_code ~= 0 then
            log_warn({ msg = "Failed to reload systemd daemon!", stdout = stdout, stderr = stderr })
        end
    end
    assert(systemctl.exec(options, "enable", service_name .. "." .. options.kind) == 0,
        "Failed to enable service " .. service_name .. "!")
end

---starts a service
---@param service_name string
---@param options SystemctlExecOptions?
function systemctl.start_service(service_name, options)
    log_trace("Starting service: " .. service_name)
    local exit_code = systemctl.exec(options, "start", service_name)
    assert(exit_code == 0, "Failed to start service")
    log_trace("Service " .. service_name .. "started...")
end

---stops a service
---@param service_name string
---@param options SystemctlExecOptions?
function systemctl.stop_service(service_name, options)
    log_trace("Stoping service: " .. service_name)
    local exit_code = systemctl.exec(options, "stop", service_name)
    assert(exit_code == 0, "Failed to stop service")
    log_trace("Service " .. service_name .. "stopped...")
end

---checks if a service is installed
---@param service_name string
---@param options SystemctlRemoveServiceOptions?
function systemctl.is_service_installed(service_name, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.kind) ~= "string" then
        options.kind = "service"
    end
    local container = options.container
    if type(container) == "string" and container ~= "root" then
        local _home = get_user_home(container)
        local unit_store_path = _home .. "/.config/systemd/user/"
        return fs.exists(unit_store_path .. service_name .. "." .. options.kind)
    end
    return fs.exists("/etc/systemd/system/" .. service_name .. "." .. options.kind)
end

---removes a service
---@param service_name string
---@param options SystemctlRemoveServiceOptions?
function systemctl.remove_service(service_name, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.kind) ~= "string" then
        options.kind = "service"
    end

    local service_unit_file = "/etc/systemd/system/" .. service_name .. "." .. options.kind
    local container = options.container
    if type(container) == "string" and container ~= "root" then
        local _home = get_user_home(container)

        local unit_store_path = _home .. "/.config/systemd/user/"
        service_unit_file = unit_store_path .. service_name .. "." .. options.kind
    end
    if not fs.exists(service_unit_file) then return end -- service not found so skip

    log_trace("Removing service: " .. service_name)
    local exit_code = systemctl.exec(options, "stop", service_name)
    assert(exit_code == 0 or exit_code == 5, "Failed to stop service")
    log_trace("Service " .. service_name .. "stopped...")

    log_trace("Disabling service...")
    assert(systemctl.exec(options, "disable", service_name .. "." .. options.kind) == 0,
        "Failed to disable service " .. service_name .. "!")
    log_trace("Service disabled.")

    log_trace("Removing service...")
    local _ok, _error = fs.safe_remove(service_unit_file)
    if not _ok then
        error("Failed to remove " .. service_name .. "." .. options.kind .. " - " .. (_error or ""))
    end

    if type(options.daemonReload) ~= "boolean" or options.daemonReload == true then
        local exit_code, _stdout, _stderr = systemctl.exec(options, "daemon-reload")
        if exit_code ~= 0 then
            log_warn({ msg = "Failed to reload systemd daemon!", stdout = _stdout, stderr = _stderr })
        end
    end
    log_trace("Service " .. service_name .. "removed...")
end

---gets service status
---@param service_name string
---@param options SystemctlExecOptions?
---@return string
---@return string
function systemctl.get_service_status(service_name, options)
    log_trace("Getting service " .. service_name .. "status...")
    local exit_code, _stdout = systemctl.exec(options, "show", "-p", "SubState", service_name)
    assert(exit_code == 0, "Failed to get service status")
    local _status = _stdout:match("SubState=%s*(%S*)")
    local exit_code, _stdout = systemctl.exec(options, "show", "--timestamp=utc", "-p", "ExecMainStartTimestamp",
        service_name)
    if exit_code ~= 0 then -- fallback
        exit_code, _stdout = systemctl.exec(options, "show", "-p", "ExecMainStartTimestamp", service_name)
        assert(exit_code == 0, "Failed to get service start timestamp")
        local _started = type(_stdout) == "string" and _stdout:match("^ExecMainStartTimestamp=%s*(.-)%s*$")
        -- adjust to UTC
        local _proc = proc.spawn("date",
            { "-u", "-d", tostring(_started), '+ExecMainStartTimestamp=%a %Y-%m-%d %H:%M:%S UTC' },
            { stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
        if not _proc then
            error("Failed to execute date command")
        end
        log_trace("date exit code: " .. _proc.exit_code)
        _stdout = _proc.stdout_stream:read("a")
        exit_code = _proc.exit_code
    end
    assert(exit_code == 0, "Failed to get service start timestamp")
    local _started = type(_stdout) == "string" and _stdout:match("^ExecMainStartTimestamp=%s*(.-)%s*$")
    log_trace("Got service " .. service_name .. " status - " .. (_status or ""))
    return _status, _started
end

---creates a systemctl object with options preset
---@param cached_options SystemctlExecOptions
---@return table
function systemctl.with_options(cached_options)
    local function patch_options(options)
        return util.merge_tables(cached_options, options, true)
    end

    ---@type Systemctl
    ---@diagnostic disable-next-line: missing-fields
    local systemctl_with_options = {}
    function systemctl_with_options.exec(options, ...)
        return systemctl.exec(patch_options(options), ...)
    end

    function systemctl_with_options.install_service(source_file, service_name, options)
        return systemctl.install_service(source_file, service_name, patch_options(options))
    end

    function systemctl_with_options.start_service(service_name, options)
        return systemctl.start_service(service_name, patch_options(options))
    end

    function systemctl_with_options.stop_service(service_name, options)
        return systemctl.stop_service(service_name, patch_options(options))
    end

    function systemctl_with_options.remove_service(service_name, options)
        return systemctl.remove_service(service_name, patch_options(options))
    end

    function systemctl_with_options.get_service_status(service_name, options)
        return systemctl.get_service_status(service_name, patch_options(options))
    end

    function systemctl_with_options.is_service_installed(service_name, options)
        return systemctl.is_service_installed(service_name, patch_options(options))
    end

    return util.generate_safe_functions(systemctl_with_options)
end

return util.generate_safe_functions(systemctl)
