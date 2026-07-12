--!strict

--[[
	The public face of Highlighter. Rendering math lives in richtext.luau,
	Instance management lives in labels.luau, and colors live in theme.luau.
	This module just exposes them as one cohesive API.
]]

local types = require(script.types)
local Theme = require(script.theme)
local RichText = require(script.richtext)
local Labels = require(script.labels)

local Highlighter = {
	defaultLexer = require(script.lexer) :: types.Lexer,
}

--[[
	Highlights the given textObject with the given props and returns a cleanup function.
	Highlighting will automatically update when needed, so the cleanup function will disconnect
	those connections and remove all labels.
]]
function Highlighter.highlight(props: types.HighlightProps): () -> ()
	return Labels.highlight(props)
end

--[[
	Builds rich text lines from the given source code.
	Useful for cases where you want to render the labels yourself for something.
]]
function Highlighter.buildRichTextLines(props: types.BuildRichTextLinesProps): { string }
	return RichText.buildRichTextLines(props)
end

--[[
	Refreshes all highlighted textObjects. Used when the theme changes.
]]
function Highlighter.refresh(): ()
	Labels.refresh()
end

--[[
	Sets the token colors to the given colors and refreshes all highlighted textObjects.
]]
function Highlighter.setTokenColors(colors: types.TokenColors): ()
	Theme.setColors(colors)

	Labels.refresh()
end

--[[
	Gets a token color by name.
	Mainly useful for setting "background" token color on other UI objects behind your text.
]]
function Highlighter.getTokenColor(tokenName: types.TokenName): Color3
	return Theme.getColor(tokenName)
end

--[[
	Matches the token colors to the Studio theme settings and refreshes all highlighted textObjects.
	Does nothing when not run in a Studio plugin.
]]
function Highlighter.matchStudioSettings(): ()
	Theme.matchStudioSettings(Labels.refresh)
end

return table.freeze(Highlighter)
