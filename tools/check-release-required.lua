local built_plugins = fs.read_dir("build", { recurse = false, as_dir_entries = false, return_full_paths = false }) --[=[@as string[]]=]

local release_id = os.getenv("RELEASE_ID")
if not release_id then
	error("RELEASE_ID is not set!")
end

local to_be_released = {}
-- https://air.alis.is/ami/plugin/platform/v/0.2.0.json
local client = net.RestClient:new("https://air.alis.is/ami/plugin/")

for _, plugin in ipairs(built_plugins) do
	if fs.file_type(path.combine("build", plugin)) ~= "file" or plugin == ".gitkeep" then
		goto CONTINUE
	end
	local plugin_name, version = string.match(plugin, "^(.+)-(.+)%.zip$")
	if not plugin_name or not version then
		goto CONTINUE
	end
    local response, err = client:get(plugin_name .. "/v/" .. version .. ".json", { follow_redirects = true})
	if response and response.code == 200 then goto CONTINUE end
	table.insert(to_be_released,
		{ plugin_name = plugin_name, version = version, sha256 = fs.hash_file(path.combine("build", plugin),
			{ hex = true, type = "sha256" }) })

	::CONTINUE::
end

if #to_be_released == 0 then
	io.write("")
	return
end

-- air supports coma separated packages
-- plugins require `plugin:` prefix
local ids = string.join(",", table.map(to_be_released, function(item) return "plugin:" .. item.plugin_name end))
-- https://github.com/alis-is/ami-plugins/releases/download/<release_id>/<plugin_name>-<version>.zip
local sources = string.join(",", table.map(to_be_released, function(item)
	local msg = string.interpolate(
		"https://github.com/alis-is/ami-plugins/releases/download/${release_id}/${plugin_name}-${version}.zip", {
			release_id = release_id,
			plugin_name = item.plugin_name,
			version = item.version
		})
	return msg
end))
local versions = string.join(",", table.map(to_be_released, function(item) return item.version end))
local hashes = string.join(",", table.map(to_be_released, function(item) return item.sha256 end))

local REPOSITORY = os.getenv("GITHUB_REPOSITORY")

local payload = string.interpolate(
	'{ "id": "${ids}", "repository": "${repository}", "version": "${versions}", "package": "${packages}", "sha256": "${hashes}"}',
		{
			ids = ids,
			versions = versions,
			packages = sources,
			hashes = hashes,
			repository = REPOSITORY
		})

io.write(payload)