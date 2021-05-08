local _eliUtil = require "eli.util"
local _trace, _debug = _eliUtil.global_log_factory("plugin/podman", "trace", "debug")

local podman = {}

local _distroSetupFns = {
    ["ubuntu"] = function(platformInfo)
        _debug("Installing podman on Uubuntu...")
        _versionId = platformInfo.DISTRO_VERSION
        assert(type(_versionId) == "string", "Invalid ubuntu version!")
        assert(ver.compare_version("20.04", _versionId) <= 0, "Lowest supported Ubuntu version is 20.04!")
        -- add apt repository
        _debug("Adding kubic sources...")
        fs.write_file(
            "/etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list",
            "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_" .. _versionId .. "/ /"
        )
        _debug("Adding kubic sources...")
        local _keyFile = os.tmpname()
        local _ok, _error =
            net.safe_download_file(
            "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_" .. _versionId .. "/Release.key",
            _keyFile,
            {followRedirects = true}
        )
        if not _ok then
            os.remove(_keyFile)
            error("Failed to download repository key! (" .. _error .. ")")
        end
        local _ok = os.execute("apt-key add " .. _keyFile)
        assert(_ok, "Failed to apt-add repository key!")
        os.remove(_keyFile)

        _debug("Installing podman...")
        local _apt = APT_PLUGIN or am.plugin.get("apt")
        local _ok = _apt.update()
        assert(_ok, "Failed to apt update!")
        _apt.install("podman slirp4netns")
    end
    --    ["debian"] = function(platformInfo)
    --  // TODO
    --    end
}

local function _escape(s)
	s = s:gsub("'", "\'")
    s = s:gsub("\\", "\\\\")
	return s
end

local function _os_execute(cmd, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.runas) == "string" then
        cmd = "su " .. options.runas .. " -c '" .. _escape(cmd) .. "'"
    end
    return os.execute(cmd)
end

function podman.is_installed()
    return _os_execute("podman --version 2>&1 >/dev/null")
end

function podman.install()
    if podman.is_installed() then
        _debug("Podman is already installed. Skipping installation...")
        return
    end
    _debug("Installing podman...")

    local _platform = PLATFORM_PLUGIN or am.plugin.get("platform")
    local _identified, _platformInfo = _platform.get_platform()
    assert(_identified and _platformInfo.OS == "unix", "Unsupported platform!")
    local _installFn = _distroSetupFns[_platformInfo.DISTRO:lower()]
    _installFn(_platformInfo)
end

function podman.build(dockerfile, name, options)
    local _tag = ""
    if type(name) == "string" then
        _tag = "--tag " .. name .. " "
    end
    _trace("Executing: " .. "podman build " .. _tag .. " -f " .. dockerfile)
    local _ok, _exitcode = _os_execute("podman build " .. _tag .. " -f " .. dockerfile, options)
    return _ok, _exitcode
end

function podman.pull(imageOrCmd, options)
    local _ok, _exitcode = _os_execute("podman pull " .. imageOrCmd, options)
    return _ok, _exitcode
end

function podman.raw_exec(method, container, commandOrOptions, options)
    if type(method) ~= "string" then
        method = "run"
    end
    if type(commandOrOptions) == "table" then
        options = commandOrOptions
        commandOrOptions = nil
    end
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.args) ~= "string" then
        options.args = ""
    end
    if type(options.stdout) ~= "string" then
        options.stdout = "pipe"
    end
    if type(options.stderr) ~= "string" then
        options.stderr = "pipe"
    end
    _trace("Executing: " .. "podman " .. method .. " " .. options.args .. " " .. container .. " " .. (commandOrOptions or ""))
    local cmd = "podman " .. method .. " " .. options.args .. " " .. container .. " " .. (commandOrOptions or "")
    if type(options.runas) == "string" then
        cmd = "su " .. options.runas .. " -c '" .. _escape(cmd) .. "'"
    end
    return proc.exec(cmd, {stdout = options.stdout, stderr = options.stderr})
end

function podman.exec(container, command, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.args) ~= "string" then
        options.args = "-it"
    end
    return podman.raw_exec("exec", container, command, options)
end

function podman.run(image, command, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.args) ~= "string" then
        options.args = "-dt"
    end
    if type(options.container) == "string" then
        options.args = options.args .. " --name " .. options.container
    end
    return podman.raw_exec("run", image, command, options)
end

return _eliUtil.generate_safe_functions(podman)
