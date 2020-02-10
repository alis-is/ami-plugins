local _trace, _debug = require"eli.util".global_log_factory("plugin/platform", "trace", "debug")

local function _execute_cmd_as(cmd, user)
    return os.execute("su " .. user .. " -c " .. cmd)
end

local function _add_user(user, options)
    if type(options) ~= 'table' then 
        options = {
            disableLogin = false,
            disablePassword = false,
            gecos = ""
        }
    end
    local _cmd = 'adduser '
    if options.disableLogin then 
        _cmd = _cmd .. "--disabled-login "
    end
    if options.disablePassword then 
        _cmd = _cmd .. "--disabled-password "
    end
    if options.gecos then 
        _cmd = _cmd .. '--gecos "' .. options.gecos .. '" '
    end

    return os.execute(_cmd .. _user)
end

local function _whoami()
    local _whoami = io.popen("whoami")
    local _user = _whoami:read("l")
    local _res, _code = _whoami:close()
    return _res, _user 
end

return {
    execute_cmd_as = _execute_cmd_as,
    add_user = _add_user,
    whoami = _whoami
}
