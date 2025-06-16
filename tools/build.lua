local plugins = fs.read_dir("src", { recurse = false, as_dir_entries = false, return_full_paths = true })

local OUTPUT_DIRECTORY = "build"

for _, plugin in ipairs(plugins) do
	if fs.file_type(plugin  --[[@as string]]) ~= "directory" then
		goto CONTINUE
	end
	local plugin_name = path.nameext(plugin)
	local version = fs.read_file(path.combine(plugin, "VERSION"))

	local file_name = string.interpolate("${plugin_name}-${version}.zip", { plugin_name = plugin_name, version = version })
	zip.compress(plugin .. "/", path.combine(OUTPUT_DIRECTORY, file_name), { recurse = true, content_only = true, overwrite = true })
	::CONTINUE::
end

