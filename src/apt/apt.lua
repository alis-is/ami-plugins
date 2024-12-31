local values, generate_safe_functions = util.values, util.generate_safe_functions
local is_tty = require "is_tty".is_stdout_tty()

local _trace, _debug = util.global_log_factory("plugin/apt", "trace", "debug")

local function get_apt_binary()
    local os = require "os"
    _trace "Looking for apt binary"
    if os.execute("apt -v 2>&1 >/dev/null") then
        _debug "'apt' available."
        return "apt"
    elseif os.execute("apt-get -v 2>&1 >/dev/null") then
        _debug "'apt-get' available."
        return "apt-get"
    else
        _debug "No APT binary found."
        return nil
    end
end

local function colorize_error_msg(msg)
    if type(msg) ~= "string" then
        return msg
    end
    local _end = ""
    if msg:sub(#msg, #msg) == "\n" then
        msg = msg:sub(1, #msg - 1)
        _end = "\n"
    end
    return string.char(27) .. "[31m" .. msg .. string.char(27) .. "[0m" .. _end
end

local APT = get_apt_binary()
assert(APT, "No supported 'apt' binary found")
assert(proc.EPROC, "APT plugin requires posix proc extra api (eli.proc.extra)")
assert(env.EENV, "APT plugin requires posix env extra api (eli.env.extra)")

local function _execute(cmd, args, options)
    if type(options) ~= "table" then
        options = {}
    end
    _trace {msg = "Spawning " .. cmd, args = args, env = options.env, cmd = cmd}

    local proc, err = proc.spawn(cmd,  args, { stdio = { stdout = "pipe", stderr = "pipe" }, env = options.env})

    if not proc then
        _debug {msg = "Failed to start " .. cmd, error = err}
        return false, -1, err, err
    end

    local stdout, stderr = "", ""

    if type(options.stdout_cb) ~= "function" and type(options.stderr_cb) ~= "function" then
        proc:wait()
        stdout = proc:get_stdout():read "a"
        stderr = proc:get_stderr():read "a"
    else
        local stdout_stream = proc:get_stdout()
        local stderr_stream = proc:get_stderr()
        if not stdout_stream then return false, -1, "Failed to get stdout stream" end
        stdout_stream:set_nonblocking(true)
        if not stderr_stream then return false, -1, "Failed to get stderr stream" end
        stderr_stream:set_nonblocking(true)
        while not proc:exited() do
            local no_output
            if type(options.stdout_cb) == "function" then
                repeat
                    local tmp = stdout_stream:read("L")
                    stdout = stdout .. (tmp or "")
                    options.stdout_cb(tmp)
                    no_output = tmp == ""
                until (no_output)
            end

            if type(options.stderr_cb) == "function" then
                repeat
                    local tmp = stderr_stream:read("L")
                    stderr = stderr .. (tmp or "")
                    no_output = tmp == ""
                    if options.colorful or (options.colorful == nil and is_tty) then
                        tmp = colorize_error_msg(tmp)
                    end
                    options.stderr_cb(tmp)
                until (no_output)
            end
            os.sleep(1)
        end

        proc:wait()
        stdout = stdout .. stdout_stream:read("a")
        stderr = stderr .. stderr_stream:read("a")
    end
    local exit_code = proc:get_exit_code()
    _trace {msg = cmd .. " exited", exit_code = exit_code, stdout = stdout, stderr = stderr}
    return exit_code == 0, exit_code, stdout, stderr
end

local function _is_installed(dependency)
    local success, exit_code = _execute("dpkg", {"-l", dependency})
    if not success or exit_code ~= 0 then return false end
    local success, exit_code, stdout = _execute("apt", {"-qq", "list", dependency})
    if not success or exit_code ~= 0 then -- apt may not be available we rely on dpkg only
        return true
    end
    return stdout:match("installed")
end

local function install(dependencies, options)
    _debug {msg = "Installing dependencies...", dependencies = dependencies}
    if type(dependencies) == "table" then
        dependencies = values(dependencies)
    elseif type(dependencies) == "string" then
        dependencies = string.split(dependencies, " ")
    end

    for i, dependency in ipairs(dependencies) do
        if not _is_installed(dependency) then
            local success, exit_code, stdout, stderr = _execute(APT, {"install", "-y", dependency}, options)
            if not success then
                _debug {
                    msg = "Failed to install dependency - " .. dependency .. ". APT stopped...",
                    dependency = dependency,
                    dependencies = dependencies
                }
                return false, exit_code, stdout, stderr, dependency
            end
        end
    end
    _debug {msg = "Dependencies successfuly installed.", dependencies = dependencies}
    return true
end

local function install_non_interactive(dependencies, options)
    if type(options) ~= "table" then
        options = {}
    end
    local env = options.env or env.environment()
    env.DEBIAN_FRONTEND = "noninteractive"
    options.env = env
    return install(dependencies, options)
end

local function upgrade(options)
    local success, exit_code, stdout, stderr = _execute(APT, {"upgrade", "-y"}, options)
    return success, exit_code, stdout, stderr
end

local function upgrade_non_interactive(options)
    if type(options) ~= "table" then
        options = {}
    end
    local env = options.env or env.environment()
    env.DEBIAN_FRONTEND = "noninteractive"
    options.env = env
    return upgrade(options)
end

local function update(options)
    local success, exit_code, stdout, stderr = _execute(APT, {"update"}, options)
    return success, exit_code, stdout, stderr
end

local function autoremove(options)
    local success, exit_code, stdout, stderr = _execute(APT, {"autoremove"}, options)
    return success, exit_code, stdout, stderr
end

local function clean(options)
    local success, exit_code, stdout, stderr = _execute(APT, {"clean"}, options)
    return success, exit_code, stdout, stderr
end

return generate_safe_functions(
    {
        upgrade = upgrade,
        clean = clean,
        install = install,
        update = update,
        autoremove = autoremove,
        get_apt_binary = get_apt_binary,
        install_non_interactive = install_non_interactive,
        upgrade_non_interactive = upgrade_non_interactive
    }
)

