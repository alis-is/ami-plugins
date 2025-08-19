local log_trace, log_debug, log_warn = util.global_log_factory("plugin/launchctl", "trace", "debug", "warn")

local DAEMON_DIR = "/Library/LaunchDaemons/"
local SERVICE_FILE_EXT = ".plist"
local LOG_DIR = "/usr/local/var/log/"

-- shim
local copy_file = type(fs.safe_copy_file) == "function" and fs.safe_copy_file or fs.copy_file
local remove = type(fs.safe_remove) == "function" and fs.safe_remove or fs.remove
-- end shim

assert(os.execute('launchctl help 2>&1 >/dev/null'), "launchctl not found")
assert(proc.EPROC, "launchctl plugin requires posix proc extra api (eli.proc.extra)")

---@class LaunchctlExecOptions

---@class LaunchctlInstallServiceOptions: LaunchctlExecOptions
---@field setup_newsyslog boolean? If true, will set up a new syslog for the service

---@class LaunchctlRemoveServiceOptions: LaunchctlExecOptions
---@field setup_newsyslog boolean? If true, will remove the syslog configuration for the service

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

local function extract(content, key)
    -- Pattern matches <key>KEY</key> <string>VALUE</string>
    local val = content:match("<key>%s*" .. key .. "%s*</key>%s*<string>(.-)</string>")
    return val
end

local function setup_output_file(file_path, uid, gid)
    local ok, err = fs.mkdirp(path.dir(file_path))
    assert(ok, "failed to create directory for '" .. file_path .. "': " .. tostring(err))

    if not fs.exists(file_path) then
        local ok, err = fs.write_file(file_path, "")
        assert(ok, "failed to create '" .. file_path .. "': " .. tostring(err))
    end
    local ok, err = fs.chown(file_path, uid, gid)
    assert(ok, "failed to change ownership of '" .. file_path .. "': " .. tostring(err))
end

local function setup_newsyslog_for_service(unit_file, label)
    local plist_content, err = fs.read_file(unit_file)
    assert(plist_content, "failed to read plist file: " .. tostring(err))

    log_debug("Setting up newsyslog for service " .. label)
    log_trace("Plist content: " .. plist_content)

    local user = extract(plist_content, "UserName") or "root"
    log_trace("UserName extracted: " .. tostring(user))
    local group = extract(plist_content, "GroupName") or user or "wheel"
    log_trace("GroupName extracted: " .. tostring(group))
    local stdout_path = extract(plist_content, "StandardOutPath")
    log_trace("StandardOutPath extracted: " .. tostring(stdout_path))
    local stderr_path = extract(plist_content, "StandardErrorPath")
    log_trace("StandardErrorPath extracted: " .. tostring(stderr_path))

    local uid, gid = fs.getuid(user), fs.getgid(group)
    assert(uid and gid, "failed to get uid/gid for user/group: " .. tostring(user) .. "/" .. tostring(group))

    local syslog_dests = {}

    if stdout_path then
        setup_output_file(stdout_path, uid, gid)
        table.insert(syslog_dests, stdout_path)
    end

    if stderr_path and stdout_path ~= stderr_path then
        setup_output_file(stderr_path, uid, gid)
        table.insert(syslog_dests, stderr_path)
    end

    local content = ""
    local ownership = string.join(":", user, group)
    for _, syslog_dest in ipairs(syslog_dests) do
        content = content .. syslog_dest .. "  " .. ownership .. "  640  7     *    @T00  Z\n"
    end

    local ok, err = fs.write_file("/etc/newsyslog.d/" .. label .. ".conf", content)
    assert(ok, "failed to create newsyslog config: " .. tostring(err))
    os.execute "newsyslog" -- Reload newsyslog configuration
end

---Install a launchd service (copy .plist to correct place and bootstrap)
---@param source_file string
---@param label string
---@param options LaunchctlInstallServiceOptions?
function launchctl.install_service(source_file, label, options)
    options = options or {}
    log_debug("Setting up service " .. label .. " from " .. source_file)
    local dest = DAEMON_DIR .. label .. SERVICE_FILE_EXT
    assert(copy_file(source_file, dest), "failed to install plist: " .. source_file)

    if options.setup_newsyslog then
        -- Set up a new syslog for the service
        if fs.file_type(LOG_DIR) ~= "directory" then
            local ok, err = fs.mkdirp(LOG_DIR)
            assert(ok, "failed to create log directory: " .. tostring(err))
        end
        setup_newsyslog_for_service(source_file, label)
    end
end

---Remove a launchd service (bootout and delete .plist)
---@param label string
---@param options LaunchctlRemoveServiceOptions?
function launchctl.remove_service(label, options)
    options = options or {}
    local dest = DAEMON_DIR .. label .. SERVICE_FILE_EXT
    launchctl.exec({ "bootout", "system", dest }, options)
    if not fs.exists(dest) then return end
    remove(dest)

    if options.setup_newsyslog then
        -- Remove the syslog configuration if it exists
        local syslog_conf = "/etc/newsyslog.d/" .. label .. ".conf"
        if fs.exists(syslog_conf) then
            local ok, err = fs.remove(syslog_conf)
            assert(ok, "failed to remove newsyslog config: " .. tostring(err))
            os.execute "newsyslog" -- Reload newsyslog configuration
        end
    end
end

local function is_already_bootstrapped_error(exit_code, stderr)
    -- Some macOS versions return 36, others 5 for "already loaded"
    if exit_code == 36 or exit_code == 5 then
        if stderr and (
                stderr:match("already loaded") or
                stderr:match("Input/output error")
            ) then
            return true
        end
    end
    -- Extra fallback: message only
    if stderr and stderr:match("already loaded") then
        return true
    end
    return false
end

---Start a service (kickstart in launchd, label must match plist Label)
---@param label string
---@param options LaunchctlExecOptions?
function launchctl.start_service(label, options)
    options = options or {}
    local exit_code, _, strerr = launchctl.exec({ "bootstrap", "system", DAEMON_DIR .. label .. SERVICE_FILE_EXT },
        options)
    -- exit code 36 means the service is already loaded, 5 means it was already started
    assert(exit_code == 0 or is_already_bootstrapped_error(exit_code, strerr), "Failed to start service " .. label)
    local exit_code = launchctl.exec({ "start", "system/" .. label }, options)
    -- exit code 0 means it was started, 3 means it was already started
    assert(exit_code == 0 or exit_code == 3, "Failed to start service " .. label)
end

local function is_already_booted_out_error(exit_code, stderr)
    -- Some macOS versions return 36, others 5 for "already loaded"
    if exit_code == 5 then
        if stderr and (
                stderr:match("Input/output error") or
                stderr:match("No such process")
            ) then
            return true
        end
    end
    return false
end

---Stop a service
---@param label string
---@param options LaunchctlExecOptions?
function launchctl.stop_service(label, options)
    options = options or {}
    local exit_code, _, strerr = launchctl.exec({ "bootout", "system", DAEMON_DIR .. label .. SERVICE_FILE_EXT }, options)
    assert(exit_code == 0 or is_already_booted_out_error(exit_code, strerr), "Failed to stop service " .. label)
end

---Get status (very limited: checks if loaded)
---@param label string
---@param options LaunchctlExecOptions?
---@return string, string
function launchctl.get_service_status(label, options)
    options = options or {}
    local exit_code, stdout, _ = launchctl.exec({ "print", "system/" .. label }, options)
    if exit_code ~= 0 and launchctl.is_service_installed(label, options) then
        return "not loaded", "" -- service is installed but not loaded
    end
    assert(exit_code == 0, "failed to get service status for " .. label)

    local state = stdout:match("state = ([^\n]+)")
    state = state and state:match("^%s*(.-)%s*$") or ""
    local pid = stdout:match("pid = (%d+)")

    local start_time = ""
    if state == "running" and pid then
        -- Try to get start time using ps
        local process = proc.spawn("ps", { "-p", pid, "-o", "lstart" },
            { stdio = { stdout = "pipe", stderr = "pipe" }, wait = true })
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
            start_time = "" -- Could not determine
        end
    end

    return state, start_time
end

---Checks if plist is present in launchd directory
---@param label string
---@param options LaunchctlRemoveServiceOptions?
function launchctl.is_service_installed(label, options)
    return fs.exists(DAEMON_DIR .. label .. SERVICE_FILE_EXT)
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
