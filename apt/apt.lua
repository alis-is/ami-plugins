local util = require "eli.util"
local values, generate_safe_functions = util.values, util.generate_safe_functions
local eprocLoaded, eproc = pcall(require, "eli.proc.extra")
local eenvLoaded, eenv = pcall(require, "eli.env.extra")
local fs = require "eli.fs"
local is_tty = require "is_tty".is_stdout_tty()

local _exString = require "eli.extensions.string"
local _trace, _debug = require "eli.util".global_log_factory("plugin/apt", "trace", "debug")

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
assert(eprocLoaded, "APT plugin requires posix proc extra api (eli.proc.extra)")
assert(eenvLoaded, "APT plugin requires posix env extra api (eli.env.extra)")

local function _execute(cmd, args, options)
    _trace "Creating pipes"
    local rd, proc_wr = fs.pipe()
    local rderr, proc_werr = fs.pipe()
    rd:set_nonblocking(true)
    rderr:set_nonblocking(true)
    _trace "pipes created"

    if type(options) ~= "table" then
        options = {}
    end
    _trace {msg = "Spawning " .. APT, args = args, env = options.env, cmd = cmd}

    local proc, err = eproc.spawn {stdout = proc_wr, stderr = proc_werr, command = APT, args = args, env = options.env}
    proc_wr:close()
    proc_werr:close()

    if not proc then
        _debug {msg = "Failed to start " .. APT, error = err}
        return false, -1, err, err
    end

    local stdout, stderr = "", ""

    if type(options.stdout_cb) ~= "function" and type(options.stderr_cb) ~= "function" then
        proc:wait()
        stdout = rd:read "a"
        stderr = rderr:read "a"
    else
        while not proc:exited() do
            local noOutput = false
            if type(options.stdout_cb) == "function" then
                repeat
                    local tmp = rd:read("L")
                    stdout = stdout .. (tmp or "")
                    options.stdout_cb(tmp)
                    noOutput = tmp == ""
                until (noOutput)
            end

            if type(options.stderr_cb) == "function" then
                repeat
                    local tmp = rderr:read("L")
                    stderr = stderr .. (tmp or "")
                    noOutput = tmp == ""
                    if options.colorful or (options.colorful == nil and is_tty) then
                        tmp = colorize_error_msg(tmp)
                    end
                    options.stderr_cb(tmp)
                until (noOutput)
            end
            eproc.sleep(1)
        end

        proc:wait()
        stdout = stdout .. rd:read("a")
        stderr = stderr .. rderr:read("a")
    end
    local exitCode = proc:exitcode()
    _trace {msg = APT .. " exited", exitcode = exitCode, stdout = stdout, stderr = stderr}
    return exitCode == 0, exitCode, stdout, stderr
end

local function _is_installed(dependency)
    local success, exitcode = _execute(APT, {"dpkg", "-p", dependency})
    return success and exitcode == 0
end

local function install(dependencies, options)
    _debug {msg = "Installing dependencies...", dependencies = dependencies}
    if type(dependencies) == "table" then
        dependencies = values(dependencies)
    elseif type(dependencies) == "string" then
        dependencies = _exString.split(dependencies)
    end

    for i, dependency in ipairs(dependencies) do
        if not _is_installed(dependency) then
            local success, exitcode, stdout, stderr = _execute(APT, {"install", "-y", dependency}, options)
            if not success then
                _debug {
                    msg = "Failed to install dependency - " .. dependency .. ". APT stopped...",
                    dependency = dependency,
                    dependencies = dependencies
                }
                return false, exitcode, stdout, stderr, dependency
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
    local env = options.env or eenv.environment()
    env.DEBIAN_FRONTEND = "noninteractive"
    options.env = env
    return install(dependencies, options)
end

local function upgrade(options)
    local success, exitcode, stdout, stderr = _execute(APT, {"upgrade", "-y"}, options)
    return success, exitcode, stdout, stderr
end

local function upgrade_non_interactive(options)
    if type(options) ~= "table" then
        options = {}
    end
    local env = options.env or eenv.environment()
    env.DEBIAN_FRONTEND = "noninteractive"
    options.env = env
    return upgrade(options)
end

local function update(options)
    local success, exitcode, stdout, stderr = _execute(APT, {"update"}, options)
    return success, exitcode, stdout, stderr
end

local function autoremove(options)
    local success, exitcode, stdout, stderr = _execute(APT, {"autoremove"}, options)
    return success, exitcode, stdout, stderr
end

local function clean(options)
    local success, exitcode, stdout, stderr = _execute(APT, {"clean"}, options)
    return success, exitcode, stdout, stderr
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
