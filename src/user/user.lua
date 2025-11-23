local log_debug, log_info, log_warn = require 'eli.util'.global_log_factory('plugin/user', 'debug', "info", 'warn')

local user = {}

-- shim
local function get_plugin(name)
    local success_or_plugin, plugin_or_error = am.plugin.get(name)
    if type(success_or_plugin) == "boolean" then
        if success_or_plugin then
            return success_or_plugin
        end
        return nil, plugin_or_error or "failed to get plugin"
    end
    return success_or_plugin, plugin_or_error
end
-- shim end

local platform_plugin = get_plugin("platform")
local platform_identified, platform = platform_plugin.get_platform()
assert(platform_identified, "failed to identify platform")
assert(platform.OS == "unix", "user plugin is only supported on unix-like systems")

local distro = type(platform.DISTRO) == "string" and platform.DISTRO:lower() or ""
local isMacOs = distro == "macos" or distro == "darwin"
local isWindows = platform.OS == "windows"

function user.execute_cmd_as(cmd, user)
    return os.execute('su ' .. user .. ' -c ' .. cmd)
end

local function lock_user()
    local lock_file = '/var/run/ami.plugin.user.lockfile'
    if not fs.exists(lock_file) then
        fs.write_file(lock_file, '')
    end
    return fs.lock_file(lock_file, 'w')
end

local function unlock_user(lock)
    local ok, err = pcall(fs.unlock_file, lock)
    if not ok then log_warn("Failed to unlock plugin.user.lockfile - " .. tostring(err) .. "!") end
end

local function command_exists(cmd)
    -- Redirect output to /dev/null so it doesn't clutter logs
    local status = os.execute('command -v ' .. cmd .. ' >/dev/null 2>&1')

    -- Handle differences between Lua 5.1 and 5.2+ return values for os.execute
    if type(status) == "boolean" then
        return status -- Lua 5.2+
    else
        return status == 0 -- Lua 5.1 (returns exit code directly)
    end
end

local function linux_user_add(user_name, options)
    if type(options) ~= 'table' then
        options = {
            disable_login = false,
            disable_password = false,
            gecos = '',
            timeout = 60
        }
    end

    local timeout = options.timeout or 60

    local lock
    local counter = 0
    while lock == nil do
        lock, _ = lock_user()
        os.sleep(1)
        counter = counter + 1
        if counter > timeout and timeout > 0 then
            log_warn('Timeout while waiting for user lock!')
            return false, "timeout", 1
        end
        log_info('Waiting for user add lock...')
    end

    local uid, _ = user.get_uid(user_name) -- Assuming user.get_uid is defined
    if uid and type(uid) == "number" then
        unlock_user(lock)
        return true, "exit", 0
    end

    local cmd = ""
    local fullname = options.fullname or options.gecos

    if command_exists("adduser") then
        -- DEBIAN/UBUNTU STYLE
        cmd = 'adduser '
        if options.disable_login then
            cmd = cmd .. '--disabled-login '
        end
        if options.disable_password then
            cmd = cmd .. '--disabled-password '
        end
        if fullname and fullname ~= "" then
            cmd = cmd .. '--gecos "' .. fullname .. '" '
        end
        -- Suppress interactive output/prompts where possible
        cmd = cmd .. '--quiet '
        cmd = cmd .. user_name
    else
        -- RHEL/CENTOS/GENERIC LINUX STYLE (Fallback)
        cmd = 'useradd '
        cmd = cmd .. '-M ' -- Do not create home directory

        if fullname and fullname ~= "" then
            cmd = cmd .. '-c "' .. fullname .. '" '
        end

        cmd = cmd .. user_name
    end

    log_debug('Creating user with command: ' .. tostring(cmd))
    local result = os.execute(cmd)

    unlock_user(lock)
    return result
end

local function macos_user_add(user_name, options)
    if type(options) ~= 'table' then
        options = {
            disable_login = false,
            disable_password = false, -- If true, creates a "System User" via dscl
            timeout = 60
        }
    end

    local timeout = options.timeout or 60

    local lock
    local counter = 0
    while lock == nil do
        lock, _ = lock_user()
        os.sleep(1)
        counter = counter + 1
        if counter > timeout and timeout > 0 then
            log_warn('Timeout while waiting for user lock!')
            return false, "timeout", 1
        end
        log_info('Waiting for user add lock...')
    end

    local uid, _ = user.get_uid(user_name)
    if uid and type(uid) == "number" then
        unlock_user(lock)
        return true, "exit", 0
    end

    local result = true

    if options.disable_password then
        log_debug('Creating passwordless system user via DSCL: ' .. user_name)

        local handle = io.popen("dscl . -list /Users UniqueID | awk '$2 > 400 && $2 < 500 { print $2 }' | sort -n | tail -1")
        local max_uid = handle:read("*a")
        handle:close()

        local new_uid = 401
        if max_uid and tonumber(max_uid) then
            new_uid = tonumber(max_uid) + 1
        end

        local home_dir = "/var/" .. user_name
        local fullname = options.fullname or options.gecos or user_name

        local cmds = {
            'dscl . -create /Users/' .. user_name,
            'dscl . -create /Users/' .. user_name .. ' UserShell /usr/bin/false',
            'dscl . -create /Users/' .. user_name .. ' RealName "' .. fullname .. '"',
            'dscl . -create /Users/' .. user_name .. ' UniqueID ' .. new_uid,
            'dscl . -create /Users/' .. user_name .. ' PrimaryGroupID 20', -- Group 20 is 'staff'
            'dscl . -create /Users/' .. user_name .. ' NFSHomeDirectory ' .. home_dir,
            'dscl . -create /Users/' .. user_name .. ' IsHidden 1', -- Hide from login screen
            -- Manually create home dir because dscl won't do it
            'mkdir -p ' .. home_dir,
            'chown ' .. new_uid .. ':20 ' .. home_dir
        }

        for _, cmd in ipairs(cmds) do
            log_debug("Exec: " .. cmd)
            local status = os.execute(cmd)
            if not status then 
                log_warn("Failed to execute: " .. cmd)
                result = false 
            end
        end
    else
        local cmd = 'sysadminctl -addUser ' .. user_name .. ' '
        local fullname = options.fullname or options.gecos
        if fullname then
            cmd = cmd .. '-fullName "' .. fullname .. '" '
        end

        log_debug('Creating standard user: ' .. tostring(cmd))
        result = os.execute(cmd)
    end

    unlock_user(lock)
    return result
end

local function windows_user_add(user_name, options)
    return false, "not supported", 1
end

function user.add(user_name, options)
    if isMacOs then
        return macos_user_add(user_name, options)
    end
    if isWindows then
        return windows_user_add(user_name, options)
    end
    return linux_user_add(user_name, options)
end

local function linux_add_group(group_name, options)
    if type(options) ~= 'table' then options = {} end

    local timeout = options.timeout or 60

    local lock
    local counter = 0
    while lock == nil do
        lock, _ = lock_user()
        os.sleep(1)
        counter = counter + 1
        if counter > timeout and timeout > 0 then
            log_warn('Timeout while waiting for user lock!')
            return false, "timeout", 1
        end
        log_info('Waiting for user add lock...')
    end

    local gid, _ = user.get_gid(group_name)
    if gid and type(gid) == "number" then
        unlock_user(lock)
        return true, "exit", 0
    end

    local cmd = ""
    if command_exists('addgroup') then
        -- Debian/Ubuntu style
        cmd = 'addgroup '

        if options.system then
            cmd = cmd .. '--system '
        end

        cmd = cmd .. group_name
    else
        -- RHEL/CentOS/Generic Linux style
        cmd = 'groupadd '
        
        if options.system then
            cmd = cmd .. '--system '
        end
        
        cmd = cmd .. group_name
    end

    log_debug('Creating group: ' .. tostring(cmd))
    local result = os.execute(cmd)
    unlock_user(lock)
    return result
end

local function macos_add_group(group_name, options)
    if type(options) ~= 'table' then options = {} end

    local timeout = options.timeout or 60

    local lock
    local counter = 0
    while lock == nil do
        lock, _ = lock_user()
        os.sleep(1)
        counter = counter + 1
        if counter > timeout and timeout > 0 then
            log_warn('Timeout while waiting for user lock!')
            return false, "timeout", 1
        end
        log_info('Waiting for user add lock...')
    end

    local uid, _ = user.get_gid(group_name)
    if uid and type(uid) == "number" then
        unlock_user(lock)
        return true, "exit", 0
    end

    local cmd = 'dseditgroup -o create ' .. group_name
    log_debug('Creating group: ' .. tostring(cmd))
    local result = os.execute(cmd)
    unlock_user(lock)
    return result
end

local function windows_add_group(group_name, options)
    return false, "not supported", 1
end

function user.add_group(group_name, options)
    if isMacOs then
        return macos_add_group(group_name, options)
    end
    if isWindows then
        return windows_add_group(group_name, options)
    end
    return linux_add_group(group_name, options)
end

local function linux_add_into_group(user, group)
    return os.execute('usermod -a -G ' .. group .. ' ' .. user)
end

local function macos_add_into_group(user, group)
    return os.execute('dseditgroup -o edit -a ' .. user .. ' -t user ' .. group)
end

local function windows_add_into_group(user, group)
    return false, "not supported", 1
end

function user.add_into_group(user, group)
    local lock
    while lock == nil do
        lock, _ = lock_user()
        log_debug('Waiting for group add user lock...')
        os.sleep(1)
    end

    local result = false
    if isMacOs then
        result = macos_add_into_group(user, group)
    elseif isWindows then
        result = windows_add_into_group(user, group)
    else
        result = linux_add_into_group(user, group)
    end
    unlock_user(lock)
    return result
end

function user.get_uid(user)
    if type(fs.safe_getuid) == "function" then --// TODO: remove shim
        local ok, uid = fs.safe_getuid(user)
        if ok then
            return uid, nil
        else
            return nil, uid
        end
    end
    return fs.getuid(user)
end

function user.get_gid(user)
    return fs.getgid(user)
end

function user.whoami()
    local whoami = io.popen('whoami')
    local user = whoami:read('l')
    local res, code = whoami:close()
    if res then
        return user
    else
        return res, code
    end
end

function user.get_current_user() return user.whoami() end

function user.is_root()
    local root = os.execute("sh -c '[ \"$(id -u)\" -eq \"0\" ] && exit 0 || exit 1'")
    local admin = os.execute('cmd.exe /C "NET SESSION >nul 2>&1 && EXIT /B 0 || EXIT /B 1"')
    return root or admin
end

return user
