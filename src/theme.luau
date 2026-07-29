--!strict

--[[
	Token colors for the highlighter. This module owns the active color map,
	merges caller overrides into it, and can mirror the Studio script editor
	theme from inside a plugin.
]]

local RunService = game:GetService("RunService")

local types = require(script.Parent.types)

-- The canonical token name list, one entry per TokenName. The annotation
-- makes a typo here fail analyze, and the load check below keeps the color
-- and Studio style maps complete against the list.
local tokenNames: { types.TokenName } = {
	"background",
	"iden",
	"keyword",
	"builtin",
	"type",
	"string",
	"number",
	"comment",
	"operator",
	"custom",
}

local Theme = {
	tokenNames = tokenNames,

	-- Starts with default dark theme colors.
	-- Keyed by string rather than TokenName because iterating
	-- widens the keys, while the public getters stay strictly typed.
	tokenColors = {
		["background"] = Color3.fromRGB(30, 32, 37),
		["iden"] = Color3.fromRGB(210, 211, 220),
		["keyword"] = Color3.fromRGB(235, 121, 115),
		["builtin"] = Color3.fromRGB(143, 180, 255),
		["type"] = Color3.fromRGB(82, 139, 255),
		["string"] = Color3.fromRGB(142, 233, 182),
		["number"] = Color3.fromRGB(242, 186, 42),
		["comment"] = Color3.fromRGB(106, 111, 129),
		["operator"] = Color3.fromRGB(180, 186, 218),
		["custom"] = Color3.fromRGB(158, 119, 255),
	} :: { [string]: Color3 },
}

-- A name missing from either map would silently render or theme wrong,
-- since getColor falls back to iden and the Studio mapping would skip the
-- name entirely, so module load verifies both against the canonical list.
for _, tokenName in tokenNames do
	local color: Color3? = Theme.tokenColors[tokenName]
	assert(color ~= nil, `Theme.tokenColors is missing an entry for {tokenName}`)
end

-- Tracks the active Studio theme subscription so repeated calls to
-- matchStudioSettings replace the connection instead of stacking new ones.
local themeChangedConnection: RBXScriptConnection? = nil

-- Open font tags derived from the active colors. They rebuild whenever a
-- color changes, so the rich text builder reads finished strings instead of
-- paying a ToHex call and a concatenation per lookup.
local tokenOpenTags: { [string]: string } = {}

--[[
	Builds the open font tag for the given color.
]]
local function openTagFor(color: Color3): string
	return `<font color="#{color:ToHex()}">`
end

for tokenName, color in Theme.tokenColors do
	tokenOpenTags[tokenName] = openTagFor(color)
end

--[[
	Merges the given token colors into the active color map and rebuilds the
	derived open tags for the names that changed.
]]
function Theme.setColors(tokenColors: types.TokenColors)
	assert(type(tokenColors) == "table", "Theme.setColors expects a table")

	for tokenName, color in tokenColors do
		-- Iteration never produces nil values, so this check only narrows the type.
		if color ~= nil then
			Theme.tokenColors[tokenName] = color
			tokenOpenTags[tokenName] = openTagFor(color)
		end
	end
end

--[[
	Looks up the active color for the given token name. Unknown names fall
	back to the identifier color, so a custom lexer emitting kinds outside
	the built in set still renders readably.
]]
function Theme.getColor(tokenName: types.TokenName): Color3
	-- The map's indexer claims every read succeeds, so the annotation widens
	-- the result back to optional for the fallback check.
	local color: Color3? = Theme.tokenColors[tokenName]
	if color == nil then
		return Theme.tokenColors.iden
	end
	return color
end

--[[
	Looks up the prebuilt open font tag for the given token name. Unknown
	names fall back to the identifier tag, matching how their color reads
	fall back to the identifier color.
]]
function Theme.getOpenTag(tokenName: types.TokenName): string
	local openTag = tokenOpenTags[tokenName]
	if openTag == nil then
		return tokenOpenTags.iden
	end
	return openTag
end

--[[
	Applies the Studio script editor colors and subscribes to theme changes,
	invoking the given callback whenever the colors update, the initial apply
	included. Returns whether the Studio settings were reachable, which is
	only true inside a Studio plugin.
]]
function Theme.matchStudioSettings(refreshCallback: () -> ()): boolean
	if not RunService:IsStudio() then
		return false
	end

	local success = pcall(function()
		-- Accessing Studio settings errors outside of a Studio plugin,
		-- so the surrounding pcall silently returns false there.
		local studio = settings().Studio
		local studioTheme = studio.Theme

		local function getTokens(): types.TokenColors
			return {
				["background"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptBackground),
				["iden"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptText),
				["keyword"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptKeyword),
				["builtin"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptBuiltInFunction),
				["type"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptLuauKeyword),
				["string"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptString),
				["number"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptNumber),
				["comment"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptComment),
				["operator"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptOperator),
				["custom"] = studioTheme:GetColor(Enum.StudioStyleGuideColor.ScriptBool),
			}
		end

		Theme.setColors(getTokens())

		if themeChangedConnection ~= nil then
			themeChangedConnection:Disconnect()
		end
		themeChangedConnection = studio.ThemeChanged:Connect(function()
			studioTheme = studio.Theme
			Theme.setColors(getTokens())
			refreshCallback()
		end)
	end)
	-- The initial apply reports through the same callback as later theme
	-- changes, and it runs outside the pcall so a callback error propagates
	-- instead of reading as unreachable settings.
	if success then
		refreshCallback()
	end
	return success
end

return Theme
