--!strict

--[[
	Token colors for the highlighter. This module owns the active color map,
	merges caller overrides into it, and can mirror the Studio script editor
	theme from inside a plugin.
]]

local types = require(script.Parent.types)

local Theme = {
	-- Starts with default dark theme colors.
	-- Keyed by string rather than TokenName because iterating
	-- widens the keys, while the public getters stay strictly typed.
	tokenColors = {
		["background"] = Color3.fromRGB(47, 47, 47),
		["iden"] = Color3.fromRGB(234, 234, 234),
		["keyword"] = Color3.fromRGB(215, 174, 255),
		["builtin"] = Color3.fromRGB(131, 206, 255),
		["type"] = Color3.fromRGB(77, 227, 169),
		["string"] = Color3.fromRGB(196, 255, 193),
		["number"] = Color3.fromRGB(255, 125, 125),
		["comment"] = Color3.fromRGB(140, 140, 155),
		["operator"] = Color3.fromRGB(255, 239, 148),
		["custom"] = Color3.fromRGB(119, 122, 255),
	} :: { [string]: Color3 },
}

-- Tracks the active Studio theme subscription so repeated calls to
-- matchStudioSettings replace the connection instead of stacking new ones.
local themeChangedConnection: RBXScriptConnection? = nil

--[[
	Merges the given token colors into the active color map.
]]
function Theme.setColors(tokenColors: types.TokenColors)
	assert(type(tokenColors) == "table", "Theme.setColors expects a table")

	for tokenName, color in tokenColors do
		-- Iteration never produces nil values, so this check only narrows the type.
		if color ~= nil then
			Theme.tokenColors[tokenName] = color
		end
	end
end

--[[
	Looks up the active color for the given token name.
]]
function Theme.getColor(tokenName: types.TokenName): Color3
	return Theme.tokenColors[tokenName]
end

--[[
	Applies the Studio script editor colors and subscribes to theme changes,
	invoking the given callback whenever the colors update. Returns whether the
	Studio settings were reachable, which is only true inside a Studio plugin.
]]
function Theme.matchStudioSettings(refreshCallback: () -> ()): boolean
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
	return success
end

return Theme
