local _trace, _debug = require"eli.util".global_log_factory("plugin/platform", "trace", "debug")

local function _execute(cmd) 
    local _f = io.popen(cmd)
    local _output = _f:read"a*"
    local _success, _exit, _code = _f:close()
    return _success, _exit, _code, _output
end

local function _get_platform() 
    local _delim = package.config:sub(1,1);
    if _delim == '\\' then 
        -- windows
        _debug{ msg="Assuming windows platform." }
        local _success, _exit, _code, _output = _execute('systeminfo.exe');
        _trace{ msg=_output, type="stdout", external_source="systeminfo.exe", exitcode=_exit }
        if not _success then 
            _debug{ msg="Failed to get windows platform details." }
            return false
        else 
            local _details = {
                OS = "win",
                OS_NAME = _output:match("OS Name:%s*([^\n]*)"),
                OS_VERSION = _output:match("OS Version::%s*([^\n]*)"),
                SYSTEM_TYPE = _output:match("System Type:%s*([^\n]*)")
            }
            _debug{ msg="Succefully got platform details.", details = _details }
            return true, _details
        end
    else 
        -- unix
        _debug{ msg="Assuming windows platform." }
        local _success, _exit, _code, _output = _execute('lsb_release -a 2>/dev/null')
        _trace{ msg=_output, type="stdout", external_source="lsb_release -a", exitcode=_exit }
        if not _success then 
            _debug{ msg="Failed to get unix platform details." }
            return false 
        end

        local _DISTRO = _output:match("Distributor ID:%s*(.*)") or ''
        local _DISTRO_VERSION = _output:match("Release:%s*(.*)") or ''

        _success, _exit, _code, _output = _execute('uname -s')
        _trace{ msg=_output, type="stdout", external_source="uname -s", exitcode=_exit }
        if not _success then 
            _debug{ msg="Failed to get unix platform details." }
            return false 
        end
        local _KERNEL = _output:match("([^\n]*)") or ''

        _success, _exit, _code, _output = _execute('uname -r')
        _trace{ msg=_output, type="stdout", external_source="uname -r", exitcode=_exit }
        if not _success then 
            _debug{ msg="Failed to get unix platform details." }
            return false 
        end
        local _KERNEL_VERSION = _success and _output:match("([^\n]*)") or ''

        _success, _exit, _code, _output = _execute('uname -m')
        _trace{ msg=_output, type="stdout", external_source="uname -m", exitcode=_exit }
        local _SYSTEM_TYPE = _success and _output:match("([^\n]*)") or ''

        _success, _exit, _code, _output = _execute('uname -i')
        _trace{ msg=_output, type="stdout", external_source="uname -i", exitcode=_exit }
        local _PLATFORM_TYPE = _success and _output:match("([^\n]*)") or ''

        _success, _exit, _code, _output = _execute('uname -p')
        _trace{ msg=_output, type="stdout", external_source="uname -p", exitcode=_exit }
        local _PROCESSOR_TYPE = _success and _output:match("([^\n]*)") or ''

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
        _debug{ msg="Succefully got platform details.", details = _details }
        return true, _details
    end
end

return { get_platform = _get_platform }
