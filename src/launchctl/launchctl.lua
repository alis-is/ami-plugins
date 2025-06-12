local log_trace, log_warn = util.global_log_factory("plugin/launchctl", "trace", "warn")

local DAEMON_DIR = "/Library/LaunchDaemons/"

-- shim
local copy_file = type(fs.safe_copy_file) == "function" and fs.safe_copy_file or fs.copy_file
local remove = type(fs.safe_remove) == "function" and fs.safe_remove or fs.remove
-- end shim

assert(os.execute('launchctl help 2>&1 >/dev/null'), "launchctl not found")
assert(proc.EPROC, "launchctl plugin requires posix proc extra api (eli.proc.extra)")

---@class LaunchctlExecOptions

---@class LaunchctlInstallServiceOptions: LaunchctlExecOptions

---@class LaunchctlRemoveServiceOptions: LaunchctlExecOptions

---@class Launchctl
---@field exec fun(args: table, options: LaunchctlExecOptions?): number, string, string
---@field install_service fun(source_file: string, label: string, options: LaunchctlInstallServiceOptions?)
---@field start_service fun(label: string, options: LaunchctlExecOptions?)
---@field stop_service fun(label: string, options: LaunchctlExecOptions?)
---@field remove_service fun(label: string, options: LaunchctlRemoveServiceOptions?)
---@field get_service_status fun(label: string, options: LaunchctlExecOptions?): string, string
---@field is_service_installed fun(label: string, options: LaunchctlRemoveServiceOptions?): boolean
---@field with_options fun(options: LaunchctlExecOptions): Launchctl

---@type Launchctl
local launchctl = {}

---Executes a launchctl command with options
---@param args table
---@param options LaunchctlExecOptions?
---@return number, string, string
function launchctl.exec(args, options)
    options = options or {}
    local bin = "launchctl"
    local full_args = {}

    for _, a in ipairs(args) do table.insert(full_args, a) end

    log_trace("Executing launchctl " .. table.concat(full_args, " "))
    local process = proc.spawn(bin, full_args, { stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
    if not process then
        error("Failed to execute launchctl command")
    end
    local stderr = process.stderr_stream:read("a")
    local stdout = process.stdout_stream:read("a")
    return process.exit_code, stdout, stderr
end

---Install a launchd service (copy .plist to correct place and bootstrap)
---@param source_file string
---@param label string
---@param options LaunchctlInstallServiceOptions?
function launchctl.install_service(source_file, label, options)
    options = options or {}
    local dest = DAEMON_DIR .. label .. ".plist"
    assert(copy_file(source_file, dest), "failed to install plist: " .. source_file)
    -- set permissions for daemon
    local exit_code = launchctl.exec({ "bootstrap", "system", dest }, options)
    assert(exit_code == 0, "Failed to load launchd plist")
end

---Remove a launchd service (bootout and delete .plist)
---@param label string
---@param options LaunchctlRemoveServiceOptions?
function launchctl.remove_service(label, options)
    options = options or {}
    local dest = DAEMON_DIR .. label .. ".plist"
    launchctl.exec({ "bootout", "system", dest }, options)
    if not fs.exists(dest) then return end
    remove(dest)
end

---Start a service (kickstart in launchd, label must match plist Label)
---@param label string
---@param options LaunchctlExecOptions?
function launchctl.start_service(label, options)
    options = options or {}
    local exit_code = launchctl.exec({ "kickstart", "-k", "system/" .. label }, options)
    assert(exit_code == 0, "Failed to start service " .. label)
end

---Stop a service
---@param label string
---@param options LaunchctlExecOptions?
function launchctl.stop_service(label, options)
    options = options or {}
    local exit_code = launchctl.exec({ "stop", "system/" .. label }, options)
    assert(exit_code == 0, "Failed to stop service " .. label)
end

---Get status (very limited: checks if loaded)
---@param label string
---@param options LaunchctlExecOptions?
---@return string, string
function launchctl.get_service_status(label, options)
    options = options or {}
    local exit_code, stdout, _ = launchctl.exec({ "print", "system/" .. label }, options)
    assert(exit_code == 0, "failed to get service status for " .. label)

    local state = stdout:match("state = ([^\n]+)")
    state = state and state:match("^%s*(.-)%s*$") or ""
    local pid = stdout:match("pid = (%d+)")

    local start_time = ""
    if state == "running" and pid then
        -- Try to get start time using ps
        local process = proc.spawn("ps", { "-p", pid, "-o", "lstart"}, { stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
        if not process then
            error("Failed to execute ps command")
        end
        local ps_err = process.stderr_stream:read("a")
        local ps_out = process.stdout_stream:read("a")
        if process.exit_code == 0 and ps_out and #ps_out > 0 then
            -- Get the last line and trim it
            local last_line = ps_out:match("([^\n]*)\n*$")
            start_time = last_line and last_line:match("^%s*(.-)%s*$") or ""
        else
            start_time = ""                          -- Could not determine
        end
    end

    return state, start_time
end

---Checks if plist is present in launchd directory
---@param label string
---@param options LaunchctlRemoveServiceOptions?
function launchctl.is_service_installed(label, options)
    return fs.exists(DAEMON_DIR .. label .. ".plist")
end

---Creates a launchctl object with options preset
---@param cached_options LaunchctlExecOptions
function launchctl.with_options(cached_options)
    local function patch_options(options)
        return util.merge_tables(cached_options, options, true)
    end

    local launchctl_with_options = {}
    function launchctl_with_options.exec(args, options)
        return launchctl.exec(args, patch_options(options))
    end

    function launchctl_with_options.install_service(source_file, label, options)
        return launchctl.install_service(source_file, label, patch_options(options))
    end

    function launchctl_with_options.start_service(label, options)
        return launchctl.start_service(label, patch_options(options))
    end

    function launchctl_with_options.stop_service(label, options)
        return launchctl.stop_service(label, patch_options(options))
    end

    function launchctl_with_options.remove_service(label, options)
        return launchctl.remove_service(label, patch_options(options))
    end

    function launchctl_with_options.get_service_status(label, options)
        return launchctl.get_service_status(label, patch_options(options))
    end

    function launchctl_with_options.is_service_installed(label, options)
        return launchctl.is_service_installed(label, patch_options(options))
    end

    return util.generate_safe_functions(launchctl_with_options)
end

return util.generate_safe_functions(launchctl)
