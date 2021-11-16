local _debug, _warn = require 'eli.util'.global_log_factory('plugin/platform', 'debug', 'warn')

local user = {}

function user.execute_cmd_as(cmd, user)
    return os.execute('su ' .. user .. ' -c ' .. cmd)
end

local function _lock_user()
    local _lockFile = '/var/run/ami.plugin.user.lockfile'
    if not fs.exists(_lockFile) then
        fs.write_file(_lockFile, '')
    end
    return fs.lock_file(_lockFile, 'w')
end

local function _unlock_user(lock)
    local _ok, _error = pcall(fs.unlock_file, lock)
    if not _ok then _warn("Failed to unlock plugin.user.lockfile - " .. tostring(_error) .. "!") end
end

function user.add(userName, options)
    local _lock
    while _lock == nil do
        _lock, _err = _lock_user()
        _debug('Waiting for add user lock...')
        os.sleep(1)
    end

    local _ok, _uid = user.get_uid(userName)
    if _ok and type(_uid) == "number" then
        _unlock_user(_lock)
        return true, "exit", 0
    end

    if type(options) ~= 'table' then
        options = {
            disableLogin = false,
            disablePassword = false,
            gecos = ''
        }
    end
    local _cmd = 'adduser '
    if options.disableLogin then
        _cmd = _cmd .. '--disabled-login '
    end
    if options.disablePassword then
        _cmd = _cmd .. '--disabled-password '
    end
    if options.gecos then
        _cmd = _cmd .. '--gecos "' .. options.gecos .. '" '
    end

    _debug('Creating user: ' .. tostring(userName))
    local _result = os.execute(_cmd .. userName)
    _unlock_user(_lock)
    return _result
end

function user.get_uid(user)
    return fs.safe_getuid(user)
end

function user.whoami()
    local _whoami = io.popen('whoami')
    local _user = _whoami:read('l')
    local _res, _code = _whoami:close()
    if _res then
        return _user
    else
        return _res, _code
    end
end

function user.get_current_user() return user.whoami() end

function user.is_root()
    local _root = os.execute("sh -c '[ \"$(id -u)\" -eq \"0\" ] && exit 0 || exit 1'")
    local _admin = os.execute('cmd.exe /C "NET SESSION >nul 2>&1 && EXIT /B 0 || EXIT /B 1"')
    return _root or _admin
end

return user
