local log_debug, log_warn = require 'eli.util'.global_log_factory('plugin/platform', 'debug', 'warn')

local user = {}

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

function user.add(user_name, options)
    local lock
    while lock == nil do
        lock, _ = lock_user()
        log_debug('Waiting for add user lock...')
        os.sleep(1)
    end

    local ok, uid = user.get_uid(user_name)
    if ok and type(uid) == "number" then
        unlock_user(lock)
        return true, "exit", 0
    end

    if type(options) ~= 'table' then
        options = {
            disableLogin = false,
            disablePassword = false,
            gecos = ''
        }
    end
    local cmd = 'adduser '
    if options.disableLogin then
        cmd = cmd .. '--disabled-login '
    end
    if options.disablePassword then
        cmd = cmd .. '--disabled-password '
    end
    if options.gecos then
        cmd = cmd .. '--gecos "' .. options.gecos .. '" '
    end

    log_debug('Creating user: ' .. tostring(user_name))
    local result = os.execute(cmd .. user_name)
    unlock_user(lock)
    return result
end

function user.add_into_group(user, group)
    local lock
    while lock == nil do
        lock, _ = lock_user()
        log_debug('Waiting for group add user lock...')
        os.sleep(1)
    end

    local result = os.execute('usermod -a -G ' .. group .. ' ' .. user)
    unlock_user(lock)
    return result
end

function user.get_uid(user)
    return fs.safe_getuid(user)
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
