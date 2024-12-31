local util = require "eli.util"

local trace, debug = util.global_log_factory("plugin/podman", "trace", "debug")

local podman = {}

local distro_setup_fns = {
    ["ubuntu"] = function(platform_info, options)
        debug("Installing podman on Uubuntu...")
        local version_id = platform_info.DISTRO_VERSION
        assert(type(version_id) == "string", "Invalid ubuntu version!")
        assert(ver.compare("20.04", version_id) <= 0, "Lowest supported Ubuntu version is 20.04!")
        -- add apt repository
        debug("Adding kubic sources...")
        fs.write_file(
            "/etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list",
            "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_" .. version_id .. "/ /"
        )
        debug("Adding kubic sources...")
        local key_file = os.tmpname()
        local ok, err =
            net.safe_download_file(
            "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_" .. version_id .. "/Release.key",
            key_file,
            {follow_redirects = true}
        )
        if not ok then
            os.remove(key_file)
            error("Failed to download repository key! (" .. err .. ")")
        end
        local ok = os.execute("apt-key add " .. key_file)
        assert(ok, "Failed to apt-add repository key!")
        os.remove(key_file)

        debug("Installing podman...")
        local apt = APT_PLUGIN or am.plugin.get("apt")
        local ok = apt.update()
        assert(ok, "Failed to apt update!")
        apt.install("podman slirp4netns")
    end
    --    ["debian"] = function(platformInfo)
    --  // TODO
    --    end
}

local lib_setup_fns = {
    ["ubuntu"] = {
        ["libpam-cgfs"] = function(platform_info, options)
           local apt = APT_PLUGIN or am.plugin.get("apt")
           local ok = apt.update()
           assert(ok, "Failed to apt update!")
           apt.install("libpam-cgfs")
        end
    }
}

local function escape(s)
	s = s:gsub("'", "\'")
    s = s:gsub("\\", "\\\\")
	return s
end

local function os_execute(cmd, options)
    if type(options) ~= "table" then
        options = {}
    end
    if type(options.runas) == "string" then
        cmd = "su -l " .. options.runas .. " -c 'cd \"" .. escape(os.cwd()) .."\" && " .. escape(cmd) .. "'"
    end
    trace("Executing: " .. cmd)
    return os.execute(cmd)
end

function podman.is_installed()
    return os_execute("podman --version 2>&1 >/dev/null")
end

function podman.install_lib(lib, options)
   local platform = PLATFORM_PLUGIN or am.plugin.get("platform")
   local _, platform_info = platform.get_platform()
   local platform_lib_setup_fns = lib_setup_fns[platform_info.DISTRO:lower()]
   local lib_setup_fn = platform_lib_setup_fns[lib]
   if type(lib_setup_fn) == "function" then 
       lib_setup_fn(platform_info, options)
   end
end

function podman.install(options)
    if type(options) ~= "table" then 
       options = {}
    end
    local platform = PLATFORM_PLUGIN or am.plugin.get("platform")
    local identified, platform_info = platform.get_platform()
     
    if podman.is_installed() then
       debug("Podman is already installed. Skipping installation...")
       return
    end
    debug("Installing podman...")    
    assert(identified and platform_info.OS == "unix", "Unsupported platform!")  
    local install_fn = distro_setup_fns[platform_info.DISTRO:lower()]
    install_fn(platform_info, options)
end

function podman.build(dockerfile, name, options)
    local tag = ""
    if type(name) == "string" then
        tag = "--tag " .. name .. " "
    end
    local ok, exit_code = os_execute("podman build " .. tag .. " -f " .. dockerfile, options)
    return ok, exit_code
end

function podman.pull(image_or_cmd, options)
    local ok, exit_code = os_execute("podman pull " .. image_or_cmd, options)
    return ok, exit_code
end

function podman.raw_exec(method, options)
    if type(method) ~= "string" then
        method = "run"
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
    local cmd = "podman " .. method .. " " .. options.args .. " " .. (options.container or "").. " " .. (options.command or "")
    if options.useOsExec == true then
       return os_execute(cmd, options)
    end    

    if type(options.runas) == "string" then
        cmd = "su -l " .. options.runas .. " -c 'cd \"" .. escape(os.cwd()) .."\" && " .. escape(cmd) .. "'"
    end
    trace("Executing: " .. cmd)
    if options.stdPassthrough then 
       options.stdout = "ignore"
       options.stderr = "ignore"
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
    options.container = container
    options.command = command
    return podman.raw_exec("exec", options)
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
    options.container = image
    options.command = command
    return podman.raw_exec("run", options)
end

return util.generate_safe_functions(podman)
