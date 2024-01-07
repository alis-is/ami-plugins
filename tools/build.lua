local plugins = fs.read_dir("src", { recurse = false, asDirEntries = false, returnFullPaths = true })

local OUTPUT_DIRECTORY = "build"

for _, plugin in ipairs(plugins) do
	if fs.file_type(plugin  --[[@as string]]) ~= "directory" then
		goto CONTINUE
	end
	local pluginName = path.nameext(plugin)
	local version = fs.read_file(path.combine(plugin, "VERSION"))

	local fileName = string.interpolate("${pluginName}-${version}.zip", { pluginName = pluginName, version = version })
	zip.compress(plugin .. "/", path.combine(OUTPUT_DIRECTORY, fileName), { recurse = true, contentOnly = true, overwrite = true })
	::CONTINUE::
end

