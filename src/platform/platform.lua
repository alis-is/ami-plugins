local _ok, _util = pcall(require, "eli.util")
local _trace = function(...)
end
local _debug = function(...)
end
if _ok then
    _trace, _debug = _util.global_log_factory("plugin/platform", "trace", "debug")
end

local function _execute(cmd)
    local _f = io.popen(cmd)
    local _output = _f:read "a*"
    local _success, _exit, _code = _f:close()
    return _success, _exit, _code, _output
end

local _supported_dists = {
    "SuSE",
    "debian",
    "fedora",
    "redhat",
    "centos",
    "mandrake",
    "mandriva",
    "rocks",
    "slackware",
    "yellowdog",
    "gentoo",
    "UnitedLinux",
    "turbolinux",
    "arch",
    "mageia"
}

-- returns distro, version, { additional info }
local function _parse_release_file(firstline)
    -- distro release x.x (codename)
    local _dist, _ver, _codename = firstline:match("(.+) release ([%d.]+)[^(]*%((.+)%)")
    if _dist ~= nil then
        goto RETURN
    end

    _dist, _ver, _codename = firstline:match("(.+) release ([%d.]+)[^(]*")
    if _dist ~= nil then
        goto RETURN
    end

    -- "distro x.x (codename)"
    _dist, _ver, _codename = firstline:match("([^%d]+) release ([%d.]+)[^(]*%((.+)%)")
    if _dist ~= nil then
        goto RETURN
    end

    _dist, _ver, _codename = firstline:match("([^%d]+) ([%d.]+)[^(]*%((.+)%)")
    if _dist ~= nil then
        goto RETURN
    end

    _dist, _ver, _codename = firstline:match("([^%d]+) release ([%d.]+)[^(]*")
    if _dist ~= nil then
        goto RETURN
    end

    _dist, _ver, _codename = firstline:match("([^%d]+) ([%d.]+)[^(]*")
    if _dist ~= nil then
        goto RETURN
    end

    -- unknown, first 2 words
    _ver, _dist = firstline:match("([^%s]+) ([^%s]+)")

    ::RETURN::
    return _dist or "", _ver or "", {CODENAME = _codename}
end

-- returns distro, version, { additional info }
local function get_dist()
    local dist = ""
    local _ver = ""

    local file = io.open("/etc/lsb-release")
    if file then
        local ok, lsb = pcall(file.read, file, "a")
        if ok then
            dist = lsb:match("DISTRIB_ID=(%w*)")
            _ver = lsb:match("DISTRIB_RELEASE=([%w%p]*)")
            local codename = lsb:match("DISTRIB_CODENAME=(%w*)")
            return dist, _ver, {CODENAME = codename}
        end
    end

    local release_file_path = "/etc/os-release"
    local _ok, _fs = pcall(require, "eli.fs")
    if _ok and _fs.EFS then -- only if fs available
        local files = _fs.read_dir("/etc", {return_full_paths = true})
        for _, _path in ipairs(files) do
            local _id = _path:match(".*/%w+[-_](.*)")
            if _id == "release" or _id == "version" then
                local _matched = nil
                for _, v in ipairs(_supported_dists) do
                    if _path:match(v) then
                        _matched = v
                        break
                    end
                end
                if _matched then
                    dist = _matched
                    release_file_path = _path
                    break
                end
            end
        end
    end

    if type(release_file_path) == "string" then
        local file = io.open(release_file_path)
        if file then
            local _firstline = file:read("l")
            file:seek("set", 0)
            while true do
                local _line = file:read("l")
                if _line == nil then
                    break
                end
                local dist_candidate = _line:match('^NAME="?([^"]+)"?$')
                if dist_candidate then dist = dist_candidate end
                local ver_candidate = _line:match('^VERSION="?([^"]+)"?$')
                if ver_candidate then _ver = ver_candidate end
            end
            if dist ~= "" then
                return dist, _ver, {}
            end
            return _parse_release_file(_firstline)
        end
    end

    return dist, _ver, {}
end

local function _get_platform()
    local _delim = package.config:sub(1, 1)
    if _delim == "\\" then
        -- windows
        _debug {msg = "Assuming windows platform."}
        local _success, exit_code, _code, _output = _execute("systeminfo.exe")
        _trace {msg = _output, type = "stdout", external_source = "systeminfo.exe", exit_code = exit_code}
        if not _success then
            _debug {msg = "Failed to get windows platform details."}
            return false
        else
            local _details = {
                OS = "win",
                OS_NAME = _output:match("OS Name:%s*([^\n]*)"),
                OS_VERSION = _output:match("OS Version::%s*([^\n]*)"),
                SYSTEM_TYPE = _output:match("System Type:%s*([^\n]*)")
            }
            _debug {msg = "Succefully got platform details.", details = _details}
            return true, _details
        end
    else
        -- unix or mac
        _debug {msg = "Assuming unix platform."}
        local _success, exit_code, _code, _output = _execute("uname -s")
        _trace {msg = _output, type = "stdout", external_source = "uname -s", exit_code = exit_code}
        if not _success then
            _debug {msg = "Failed to get unix platform details."}
            return false
        end
        local _KERNEL = _output:match("([^\n]*)") or ""
        local _DISTRO
        local _DISTRO_VERSION = nil
        local _ADDITIONALS = {}
        if not _KERNEL:match("[dD]arvin") then
            _DISTRO, _DISTRO_VERSION, _ADDITIONALS = get_dist()
        else
            _DISTRO = "MacOS"
        end

        _success, exit_code, _code, _output = _execute("uname -r")
        _trace {msg = _output, type = "stdout", external_source = "uname -r", exit_code = exit_code}
        if not _success then
            _debug {msg = "Failed to get unix platform details."}
            return false
        end
        local _KERNEL_VERSION = _success and _output:match("([^\n]*)") or ""

        _success, exit_code, _code, _output = _execute("uname -m")
        _trace {msg = _output, type = "stdout", external_source = "uname -m", exit_code = exit_code}
        local _SYSTEM_TYPE = _success and _output:match("([^\n]*)") or ""

        _success, exit_code, _code, _output = _execute("uname -i")
        _trace {msg = _output, type = "stdout", external_source = "uname -i", exit_code = exit_code}
        local _PLATFORM_TYPE = _success and _output:match("([^\n]*)") or ""

        _success, exit_code, _code, _output = _execute("uname -p")
        _trace {msg = _output, type = "stdout", external_source = "uname -p", exit_code = exit_code}
        local _PROCESSOR_TYPE = _success and _output:match("([^\n]*)") or ""

        local _details = {
            OS = "unix",
            DISTRO = _DISTRO,
            DISTRO_VERSION = _DISTRO_VERSION,
            KERNEL = _KERNEL,
            KERNEL_VERSION = _KERNEL_VERSION,
            SYSTEM_TYPE = _SYSTEM_TYPE,
            PLATFORM_TYPE = _PLATFORM_TYPE,
            PROCESSOR_TYPE = _PROCESSOR_TYPE
        }
        for k, v in pairs(_ADDITIONALS) do
            if _details[k] == nil then
                _details[k] = v
            end
        end
        _debug {msg = "Succefully got platform details.", details = _details}
        return true, _details
    end
end

return {get_platform = _get_platform}
