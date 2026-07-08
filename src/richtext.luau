--!strict

--[[
	Pure text work for the highlighter. This module normalizes and escapes
	source strings, wraps text in rich text color tags, and turns lexer token
	streams into rich text lines. Nothing in here touches Instances.
]]

local types = require(script.Parent.types)
local Theme = require(script.Parent.theme)

local defaultLexer = require(script.Parent.lexer) :: types.Lexer

-- Control characters that normalize strips. Newlines and tabs are excluded
-- because newlines delimit lines and tabs convert to spaces instead. Carriage
-- returns are included, which is what turns CRLF line endings into plain LF.
local CONTROL_CHARACTERS = "[\0\1\2\3\4\5\6\7\8\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31]+"

local RichText = {}

export type BuildLinesOptions = {
	src: string,
	lexer: types.Lexer,
	customLang: { [string]: string }?,
	alwaysTagText: boolean,
	shouldBuildLine: ((lineNumber: number) -> boolean)?,
	onLine: (lineNumber: number, richText: string?) -> (),
}

--[[
	Prepares raw source for highlighting by stripping control characters and
	replacing tabs with four spaces.
]]
function RichText.normalize(src: string): string
	return (string.gsub(string.gsub(src, CONTROL_CHARACTERS, ""), "\t", "    "))
end

--[[
	Escapes characters that rich text would otherwise parse as markup.
]]
function RichText.sanitize(text: string): string
	return (
		string.gsub(
			string.gsub(
				string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"),
				'"',
				"&quot;"
			),
			"'",
			"&apos;"
		)
	)
end

--[[
	Wraps the given text in a rich text font tag for the given color.
]]
function RichText.wrapColor(color: Color3, text: string): string
	return '<font color="#' .. color:ToHex() .. '">' .. text .. "</font>"
end

--[[
	Scans the source once and emits one rich text string per line through the
	onLine callback. Lines that shouldBuildLine declines receive nil instead of
	text, which lets callers keep existing content for unchanged lines while
	still hearing about every line number. When alwaysTagText is false, text in
	the default identifier color skips its font tag since the consuming label
	already renders that color. Returns the last line number emitted.
]]
function RichText.buildLines(options: BuildLinesOptions): number
	local customLang = options.customLang
	local alwaysTagText = options.alwaysTagText
	local shouldBuildLine = options.shouldBuildLine
	local onLine = options.onLine

	local function lineWillBuild(lineNumber: number): boolean
		if shouldBuildLine == nil then
			return true
		end
		return shouldBuildLine(lineNumber)
	end

	local idenColor = Theme.getColor("iden")

	local richTextBuffer, bufferIndex, lineNumber = table.create(5), 0, 1
	local buildingLine = lineWillBuild(1)

	for token, content in options.lexer.scan(options.src) do
		-- The token is cast because iterating the lexer widens its TokenName to a plain string.
		local color = Theme.getColor(token :: types.TokenName) or idenColor
		if customLang ~= nil then
			-- The lexer merges surrounding whitespace into token contents while
			-- customLang lists bare words, so the lookup trims the edges off.
			local word = string.match(content, "^%s*(.-)%s*$")
			if word ~= nil and customLang[word] ~= nil then
				color = Theme.getColor("custom")
			end
		end

		local tokenLines = string.split(RichText.sanitize(content), "\n")

		for l, tokenLine in tokenLines do
			-- Every piece after the first sits on a new line, so the current
			-- line is finished and emitted before moving on.
			if l > 1 then
				onLine(lineNumber, if buildingLine then table.concat(richTextBuffer) else nil)
				lineNumber += 1
				bufferIndex = 0
				table.clear(richTextBuffer)
				buildingLine = lineWillBuild(lineNumber)
			end

			if buildingLine then
				bufferIndex += 1
				-- Font tags only wrap visible characters, and only when the
				-- caller wants tags for the default color too.
				if (alwaysTagText or color ~= idenColor) and string.find(tokenLine, "[%S%C]") then
					richTextBuffer[bufferIndex] = RichText.wrapColor(color, tokenLine)
				else
					richTextBuffer[bufferIndex] = tokenLine
				end
			end
		end
	end

	onLine(lineNumber, if buildingLine then table.concat(richTextBuffer) else nil)

	return lineNumber
end

--[[
	Builds rich text lines from the given source code.
	Useful for cases where you want to render the labels yourself.
]]
function RichText.buildRichTextLines(props: types.BuildRichTextLinesProps): { string }
	local src = RichText.normalize(props.src)

	local richTextLines = table.create(select(2, string.gsub(src, "\n", "\n")) + 1) :: { string }

	RichText.buildLines({
		src = src,
		lexer = props.lexer or defaultLexer,
		customLang = props.customLang,
		alwaysTagText = true,
		onLine = function(lineNumber: number, richText: string?)
			-- Every line builds because there is no shouldBuildLine, so the
			-- check only narrows the type.
			if richText ~= nil then
				richTextLines[lineNumber] = richText
			end
		end,
	})

	return richTextLines
end

return RichText
