--!strict

--[[
	Pure text work for the highlighter. This module normalizes and escapes
	source strings, wraps text in rich text color tags, and turns lexer token
	streams into rich text lines. Nothing in here touches Instances.
]]

local types = require(script.Parent.types)
local Theme = require(script.Parent.theme)

local defaultLexer = require(script.Parent.lexer) :: types.Lexer

-- Control characters that normalize strips, including delete at 127. Newlines
-- and tabs are excluded because newlines delimit lines and tabs convert to
-- spaces instead. Carriage returns are included, which is what turns CRLF
-- line endings into plain LF.
local CONTROL_CHARACTERS = "[\0\1\2\3\4\5\6\7\8\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31\127]+"

local RichText = {}

export type BuildLinesOptions = {
	src: string,
	lexer: types.Lexer,
	-- An optional token iterator that stands in for scanning src, following
	-- the same contract as the lexer's scan iterator. Label population feeds
	-- one backed by its navigator cache so an edit skips rescanning tokens
	-- the edit left untouched. The iterator must cover src exactly, from the
	-- first byte of startLine when one is given.
	tokens: (() -> (string?, string))?,
	-- The line number the first emitted line takes, defaulting to one.
	-- Callers that skip rebuilding a clean prefix pass the first dirty line
	-- here along with a tokens iterator starting at that line's first byte.
	startLine: number?,
	customLang: { [string]: string }?,
	alwaysTagText: boolean,
	onLine: (lineNumber: number, richText: string) -> (),
}

--[[
	Prepares raw source for highlighting by stripping control characters and
	replacing tabs with four spaces.
]]
function RichText.normalize(src: string): string
	return (string.gsub(string.gsub(src, CONTROL_CHARACTERS, ""), "\t", "    "))
end

-- Replacements for the characters rich text parses as markup. gsub applies
-- them in a single pass over the text, so replacement text is never
-- rescanned and the ampersand inside an inserted escape stays as it is.
local RICH_TEXT_ESCAPES = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&apos;",
}
local RICH_TEXT_UNSAFE = "[&<>\"']"

-- The token kinds whose contents can equal a bare customLang word. Strings
-- carry their quotes and comments their dashes, so only these four can ever
-- match, and gating on them keeps the trim allocation off every other token.
local WORD_KINDS: { [string]: boolean } = {
	iden = true,
	keyword = true,
	builtin = true,
	type = true,
}

--[[
	Escapes characters that rich text would otherwise parse as markup.
]]
function RichText.sanitize(text: string): string
	return (string.gsub(text, RICH_TEXT_UNSAFE, RICH_TEXT_ESCAPES))
end

--[[
	Walks the source's tokens once and emits one rich text string per line
	through the onLine callback, beginning at startLine when the options
	carry one. A line's tokens can change from edits on earlier lines alone,
	so every line from the start line on builds, and callers that want to
	skip work compare the built text against what they already have. When
	alwaysTagText is false, text in the default identifier color skips its
	font tag since the consuming label already renders that color. Returns
	the last line number emitted.
]]
function RichText.buildLines(options: BuildLinesOptions): number
	local customLang = options.customLang
	local alwaysTagText = options.alwaysTagText
	local onLine = options.onLine
	-- Rebound as a local so the per token loop skips the module field read.
	local sanitize = RichText.sanitize

	local idenTag = Theme.getOpenTag("iden")

	-- The theme prebuilds the open font tags, so this call level cache only
	-- resolves each kind once against alwaysTagText. An empty string means
	-- pieces of that kind go into the line untagged.
	local openTags: { [string]: string } = {}

	--[[
		Resolves and caches the open font tag for a token kind, or an empty
		string when that kind's text should stay untagged because it renders
		in the default color the consuming label already has.
	]]
	local function resolveOpenTag(kind: string): string
		-- The kind is cast because it arrives widened to a plain string.
		local openTag = Theme.getOpenTag(kind :: types.TokenName)
		if not alwaysTagText and openTag == idenTag then
			openTag = ""
		end
		openTags[kind] = openTag
		return openTag
	end

	local richTextBuffer, bufferIndex, lineNumber = table.create(16), 0, options.startLine or 1

	--[[
		Appends one line piece of a token onto the current line's buffer.
		Tagged pieces go in as three slots so the per line table.concat does
		the joining, which avoids allocating a wrapped string per piece.
		Empty pieces skip the tag so blank lines stay truly empty. Sources
		reach the builder normalized, so a nonempty piece always has
		something to render.
	]]
	local function appendPiece(piece: string, openTag: string)
		if openTag ~= "" and piece ~= "" then
			richTextBuffer[bufferIndex + 1] = openTag
			richTextBuffer[bufferIndex + 2] = piece
			richTextBuffer[bufferIndex + 3] = "</font>"
			bufferIndex += 3
		else
			bufferIndex += 1
			richTextBuffer[bufferIndex] = piece
		end
	end

	--[[
		Turns one token into line pieces on the current buffer, finishing and
		emitting lines as the token's newlines go by.
	]]
	local function handleToken(token: string, content: string)
		local openTag = openTags[token]
		if openTag == nil then
			openTag = resolveOpenTag(token)
		end
		if customLang ~= nil and WORD_KINDS[token] ~= nil then
			-- The lexer merges surrounding whitespace into token contents while
			-- customLang lists bare words, so the lookup trims the edges off.
			local word = string.match(content, "^%s*(.-)%s*$")
			if word ~= nil and customLang[word] ~= nil then
				openTag = openTags.custom
				if openTag == nil then
					openTag = resolveOpenTag("custom")
				end
			end
		end

		local sanitized = sanitize(content)

		if string.find(sanitized, "\n", 1, true) == nil then
			-- Most tokens sit on a single line, so they skip the split and
			-- the table it allocates.
			appendPiece(sanitized, openTag)
		else
			local tokenLines = string.split(sanitized, "\n")
			for l, tokenLine in tokenLines do
				-- Every piece after the first sits on a new line, so the
				-- current line is finished and emitted before moving on.
				if l > 1 then
					onLine(lineNumber, table.concat(richTextBuffer))
					lineNumber += 1
					bufferIndex = 0
					table.clear(richTextBuffer)
				end

				appendPiece(tokenLine, openTag)
			end
		end
	end

	-- A caller-provided token iterator replaces scanning the source outright.
	-- Otherwise the direct callback walk skips the iterator's coroutine round
	-- trip per token, so it wins whenever the lexer offers it.
	local tokens = options.tokens
	local scanEach = options.lexer.scanEach
	if tokens ~= nil then
		for token, content in tokens do
			handleToken(token, content)
		end
	elseif scanEach ~= nil then
		scanEach(options.src, handleToken)
	else
		for token, content in options.lexer.scan(options.src) do
			handleToken(token, content)
		end
	end

	onLine(lineNumber, table.concat(richTextBuffer))

	return lineNumber
end

--[[
	Builds rich text lines from the given source code.
	Useful for cases where you want to render the labels yourself.
]]
function RichText.buildRichTextLines(props: types.BuildRichTextLinesProps): { string }
	local src = RichText.normalize(props.src)

	-- Counting newlines through plain finds sizes the array without gsub
	-- building a full copy of the source just to report its match count.
	local lineCount = 1
	local newlineAt = string.find(src, "\n", 1, true)
	while newlineAt ~= nil do
		lineCount += 1
		newlineAt = string.find(src, "\n", newlineAt + 1, true)
	end

	local richTextLines = table.create(lineCount) :: { string }

	RichText.buildLines({
		src = src,
		lexer = props.lexer or defaultLexer,
		customLang = props.customLang,
		alwaysTagText = true,
		onLine = function(lineNumber: number, richText: string)
			richTextLines[lineNumber] = richText
		end,
	})

	return richTextLines
end

return RichText
