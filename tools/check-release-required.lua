local builtPlugins = fs.read_dir("build", { recurse = false, asDirEntries = false, returnFullPaths = false })

local releaseId = os.getenv("RELEASE_ID")
if not releaseId then
	error("RELEASE_ID is not set!")
end

local toBeReleased = {}
-- https://air.alis.is/ami/plugin/platform/v/0.2.0.json
local client = net.RestClient:new("https://air.alis.is/ami/plugin/")

for _, plugin in ipairs(builtPlugins) do
	if fs.file_type(path.combine("build", plugin)) ~= "file" or plugin == ".gitkeep" then
		goto CONTINUE
	end
	local pluginName, version = string.match(plugin, "^(.+)-(.+)%.zip$")
	if not pluginName or not version then
		goto CONTINUE
	end

	local ok, response = client:safe_get(pluginName .. "/v/" .. version .. ".json", { followRedirects = true })
	if ok and response.code == 200 then goto CONTINUE end

	table.insert(toBeReleased,
		{ pluginName = pluginName, version = version, sha256 = fs.hash_file(path.combine("build", plugin),
			{ hex = true, type = "sha256" }) })

	::CONTINUE::
end

if #toBeReleased == 0 then
	io.write("")
	return
end

-- air supports coma separated packages
-- plugins require `plugin:` prefix
local ids = string.join(",", table.map(toBeReleased, function(item) return "plugin:" .. item.pluginName end))
-- https://github.com/alis-is/ami-plugins/releases/download/<releaseId>/<pluginName>-<version>.zip
local sources = string.join(",", table.map(toBeReleased, function(item)
	return string.interpolate(
	"https://github.com/alis-is/ami-plugins/releases/download/${releaseId}/${pluginName}-${version}.zip", {
		releaseId = releaseId,
		pluginName = item.pluginName,
		version = item.version
	})
end))
local versions = string.join(",", table.map(toBeReleased, function(item) return item.version end))
local hashes = string.join(",", table.map(toBeReleased, function(item) return item.sha256 end))

local REPOSITORY = os.getenv("GITHUB_REPOSITORY")

io.write(
	string.interpolate(
	'{ "id": "${ids}", "repository": "${repository}", "version": "${versions}", "package": "${packages}", "sha256": "${hashes}"}',
		{
			ids = ids,
			versions = versions,
			packages = sources,
			hashes = hashes,
			repository = REPOSITORY
		})
)