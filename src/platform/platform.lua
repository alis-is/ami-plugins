local ok, util = pcall(require, "eli.util")
local log_trace = function(...) end
local log_debug = function(...) end
if ok then
    log_trace, log_debug = util.global_log_factory("plugin/platform", "trace", "debug")
end

local function execute(cmd)
    local process_file = io.popen(cmd .. " 2>&1", "r")
    if not process_file then
        return false, -1, "failed to start " .. cmd
    end
    local output = process_file:read "a*"
    local ok, exit_code, code = process_file:close()
    return ok, exit_code, code, output
end

local supported_dists = {
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
local function parse_release_file(firstline)
    -- distro release x.x (codename)
    local dist, ver, codename = firstline:match("(.+) release ([%d.]+)[^(]*%((.+)%)")
    if dist ~= nil then
        goto RETURN
    end

    dist, ver, codename = firstline:match("(.+) release ([%d.]+)[^(]*")
    if dist ~= nil then
        goto RETURN
    end

    -- "distro x.x (codename)"
    dist, ver, codename = firstline:match("([^%d]+) release ([%d.]+)[^(]*%((.+)%)")
    if dist ~= nil then
        goto RETURN
    end

    dist, ver, codename = firstline:match("([^%d]+) ([%d.]+)[^(]*%((.+)%)")
    if dist ~= nil then
        goto RETURN
    end

    dist, ver, codename = firstline:match("([^%d]+) release ([%d.]+)[^(]*")
    if dist ~= nil then
        goto RETURN
    end

    dist, ver, codename = firstline:match("([^%d]+) ([%d.]+)[^(]*")
    if dist ~= nil then
        goto RETURN
    end

    -- unknown, first 2 words
    ver, dist = firstline:match("([^%s]+) ([^%s]+)")

    ::RETURN::
    return dist or "", ver or "", {CODENAME = codename}
end

-- returns distro, version, { additional info }
local function get_linux_dist()
    local dist = ""
    local ver = ""

    local file = io.open("/etc/lsb-release")
    if file then
        local ok, lsb = pcall(file.read, file, "a")
        if ok then
            dist = lsb:match("DISTRIB_ID=(%w*)")
            ver = lsb:match("DISTRIB_RELEASE=([%w%p]*)")
            local codename = lsb:match("DISTRIB_CODENAME=(%w*)")
            return dist, ver, {CODENAME = codename}
        end
    end

    local release_file_path = "/etc/os-release"
    local ok, fs = pcall(require, "eli.fs")
    if ok and fs.EFS then -- only if fs available
        local files = fs.read_dir("/etc", {return_full_paths = true})
        for _, file_path in ipairs(files) do
            local id = file_path:match(".*/%w+[-_](.*)")
            if id == "release" or id == "version" then
                local matched = nil
                for _, v in ipairs(supported_dists) do
                    if file_path:match(v) then
                        matched = v
                        break
                    end
                end
                if matched then
                    dist = matched
                    release_file_path = file_path
                    break
                end
            end
        end
    end

    if type(release_file_path) == "string" then
        local file = io.open(release_file_path)
        if file then
            local first_line = file:read("l")
            file:seek("set", 0)
            while true do
                local line = file:read("l")
                if line == nil then
                    break
                end
                local dist_candidate = line:match('^NAME="?([^"]+)"?$')
                if dist_candidate then dist = dist_candidate end
                local ver_candidate = line:match('^VERSION="?([^"]+)"?$')
                if ver_candidate then ver = ver_candidate end
            end
            if dist ~= "" then
                return dist, ver, {}
            end
            return parse_release_file(first_line)
        end
    end

    return dist, ver, {}
end

local function get_platform()
    local delimeter = package.config:sub(1, 1)
    if delimeter == "\\" then
        -- windows
        log_debug {msg = "Assuming windows platform."}
        local success, exit_code, _, output = execute("systeminfo.exe")
        log_trace {msg = output, type = "stdout", external_source = "systeminfo.exe", exit_code = exit_code}
        if not success then
            log_debug {msg = "Failed to get windows platform details."}
            return false
        else
            local details = {
                OS = "windows",
                OS_NAME = output:match("OS Name:%s*([^\n]*)"),
                OS_VERSION = output:match("OS Version::%s*([^\n]*)"),
                SYSTEM_TYPE = output:match("System Type:%s*([^\n]*)")
            }
            log_debug {msg = "Succefully got platform details.", details = details}
            return true, details
        end
    else
        -- unix or mac
        log_debug {msg = "Assuming unix platform."}
        local success, exit_code, _code, output = execute("uname -s")
        log_trace {msg = output, type = "stdout", external_source = "uname -s", exit_code = exit_code}
        if not success then
            log_debug {msg = "Failed to get unix platform details."}
            return false
        end
        local KERNEL = output:match("([^\n]*)") or ""
        local DISTRO
        local DISTRO_VERSION = nil
        local ADDITIONALS = {}
        if not KERNEL:match("[dD]arwin") then
            DISTRO, DISTRO_VERSION, ADDITIONALS = get_linux_dist()
        else
            DISTRO = "MacOS"
        end

        success, exit_code, _, output = execute("uname -r")
        log_trace {msg = output, type = "stdout", external_source = "uname -r", exit_code = exit_code}
        if not success then
            log_debug {msg = "Failed to get unix platform details."}
            return false
        end
        local KERNEL_VERSION = success and output:match("([^\n]*)") or ""

        success, exit_code, _, output = execute("uname -m")
        log_trace {msg = output, type = "stdout", external_source = "uname -m", exit_code = exit_code}
        local SYSTEM_TYPE = success and output:match("([^\n]*)") or ""

        success, exit_code, _, output = execute("uname -i")
        log_trace {msg = output, type = "stdout", external_source = "uname -i", exit_code = exit_code}
        local PLATFORM_TYPE = success and output:match("([^\n]*)") or ""

        success, exit_code, _, output = execute("uname -p")
        log_trace {msg = output, type = "stdout", external_source = "uname -p", exit_code = exit_code}
        local PROCESSOR_TYPE = success and output:match("([^\n]*)") or ""

        local details = {
            OS = "unix",
            DISTRO = DISTRO,
            DISTRO_VERSION = DISTRO_VERSION,
            KERNEL = KERNEL,
            KERNEL_VERSION = KERNEL_VERSION,
            SYSTEM_TYPE = SYSTEM_TYPE,
            PLATFORM_TYPE = PLATFORM_TYPE,
            PROCESSOR_TYPE = PROCESSOR_TYPE
        }
        for k, v in pairs(ADDITIONALS) do
            if details[k] == nil then
                details[k] = v
            end
        end
        log_debug {msg = "Succefully got platform details.", details = details}
        return true, details
    end
end

return {get_platform = get_platform}
