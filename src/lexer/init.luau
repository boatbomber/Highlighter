--!strict
--!optimize 2

--[[
	Lexical scanner producing a stream of tokens from Luau source code.
	Built as a single-pass byte scanner so it can handle Luau syntax that
	pattern matching could not. It understands string escapes, interpolated
	strings with nested holes, type annotation operators, and contextual type positions.

	Lexer.scan(source) yields (kind, content) pairs whose contents
	concatenate back to the exact source, so consumers can walk token lengths
	to find positions. Whitespace merges into the preceding token's content.

	The possible token kinds are iden, keyword, builtin, type, string,
	number, comment, and operator.
]]

local language = require(script.language)
local constants = require(script.constants)
local Navigator = require(script.navigator)

local keywords = language.keyword
local builtins = language.builtin
local libraries = language.libraries

local Lexer = {}
Lexer.language = language

-- The constant tables rebind as locals so the scanner's hot loops read
-- upvalues instead of chasing module fields.
local BYTE_NEWLINE = constants.BYTE_NEWLINE
local BYTE_RETURN = constants.BYTE_RETURN
local BYTE_QUOTE = constants.BYTE_QUOTE
local BYTE_APOSTROPHE = constants.BYTE_APOSTROPHE
local BYTE_BACKTICK = constants.BYTE_BACKTICK
local BYTE_BACKSLASH = constants.BYTE_BACKSLASH
local BYTE_DASH = constants.BYTE_DASH
local BYTE_PLUS = constants.BYTE_PLUS
local BYTE_DOT = constants.BYTE_DOT
local BYTE_UNDERSCORE = constants.BYTE_UNDERSCORE
local BYTE_EQUALS = constants.BYTE_EQUALS
local BYTE_OPEN_PAREN = constants.BYTE_OPEN_PAREN
local BYTE_OPEN_BRACE = constants.BYTE_OPEN_BRACE
local BYTE_CLOSE_BRACE = constants.BYTE_CLOSE_BRACE
local BYTE_OPEN_BRACKET = constants.BYTE_OPEN_BRACKET
local BYTE_LESS_THAN = constants.BYTE_LESS_THAN
local BYTE_AT = constants.BYTE_AT
local BYTE_LOWER_E = constants.BYTE_LOWER_E
local BYTE_UPPER_E = constants.BYTE_UPPER_E
local BYTE_LOWER_U = constants.BYTE_LOWER_U
local BYTE_LOWER_Z = constants.BYTE_LOWER_Z
local IS_SPACE = constants.IS_SPACE
local IS_DIGIT = constants.IS_DIGIT
local IS_IDEN_START = constants.IS_IDEN_START
local IS_IDEN_CHAR = constants.IS_IDEN_CHAR
local IS_NUMBER_TAIL = constants.IS_NUMBER_TAIL
local THREE_CHAR_OPERATORS = constants.THREE_CHAR_OPERATORS
local TWO_CHAR_OPERATORS = constants.TWO_CHAR_OPERATORS
local SINGLE_CHAR_OPERATORS = constants.SINGLE_CHAR_OPERATORS
local TYPE_CONTINUERS = constants.TYPE_CONTINUERS
local TYPE_EXPRESSION_KEYWORDS = constants.TYPE_EXPRESSION_KEYWORDS

--[[
	Scans one source string, calling yield(kind, content) for every token.
	All scanner state lives in locals here so concurrent scans of different
	sources never interfere.
]]
local function scanSource(source: string, yield: (string, string) -> (), startIndex: number?)
	local size = #source
	local index = startIndex or 1

	-- Tokens queue briefly before yielding so trailing whitespace can merge
	-- into them, and whitespace before the first token becomes its prefix.
	local queuedKind: string? = nil
	local queuedText = ""
	local pendingPrefix = ""

	-- The last three emitted token texts and the last kind feed the library
	-- member heuristic, mirroring how members are detected for things like
	-- math.floor without misreading foo.floor.
	local previous1, previous2, previous3, previousKind = "", "", "", ""

	-- Bracket depth across parens, braces, and square brackets in code, and
	-- the depths at which interpolation holes opened.
	local depth = 0
	local holeStack = {}

	-- Type context state. While typeMode is on, identifiers lex as type
	-- tokens until the context exits at its entry depth. typeAngle tracks
	-- generic argument brackets, typeofDepth suspends type classification
	-- inside typeof(...) since it takes a value expression, and the alias
	-- flags carry a "type Name = ..." statement through its equals sign.
	local typeMode = false
	local typeEntryDepth = 0
	local typeAngle = 0
	local typeContinues = false
	local typeofDepth: number? = nil
	local typeofArmed = false
	local aliasNamePending = false
	local aliasAwaitEquals = false

	local function flushQueued()
		if queuedKind ~= nil then
			yield(queuedKind, queuedText)
			queuedKind, queuedText = nil, ""
		end
	end

	local function emit(kind: string, text: string)
		flushQueued()
		if pendingPrefix ~= "" then
			text = pendingPrefix .. text
			pendingPrefix = ""
		end
		previous3, previous2, previous1 = previous2, previous1, text
		previousKind = kind
		queuedKind, queuedText = kind, text
	end

	local function emitSuffix(text: string)
		if queuedKind ~= nil then
			queuedText ..= text
		else
			pendingPrefix ..= text
		end
	end

	local function enterTypeMode()
		typeMode = true
		typeEntryDepth = depth
		typeAngle = 0
		typeofDepth = nil
	end

	local function exitTypeMode()
		typeMode = false
		typeAngle = 0
		typeofDepth = nil
		aliasAwaitEquals = false
	end

	--[[
		Ends the type context when a line break lands at its entry depth,
		unless the last significant token promised a continuation.
	]]
	local function checkTypeNewline()
		if typeMode and depth <= typeEntryDepth and typeAngle == 0 and not typeContinues and not aliasAwaitEquals then
			exitTypeMode()
		end
	end

	local function skipSpace(position: number): number
		while position <= size and IS_SPACE[string.byte(source, position)] do
			position += 1
		end
		return position
	end

	--[[
		Reads a dotted identifier chain starting at the given position and
		returns the position after it, or nil when no identifier starts
		there. Used only for lookahead, so it never consumes input.
	]]
	local function skipIdenChain(position: number): number?
		local byte = string.byte(source, position)
		if byte == nil or not IS_IDEN_START[byte] then
			return nil
		end
		while true do
			position += 1
			while position <= size and IS_IDEN_CHAR[string.byte(source, position)] do
				position += 1
			end
			local afterSpace = skipSpace(position)
			if string.byte(source, afterSpace) ~= BYTE_DOT then
				return position
			end
			local nextIden = skipSpace(afterSpace + 1)
			if nextIden > size or not IS_IDEN_START[string.byte(source, nextIden)] then
				return position
			end
			position = nextIden - 1
		end
	end

	--[[
		Decides whether a colon at the scanner's position starts a type
		annotation rather than a method access. A method name is followed
		immediately by call arguments, while an annotation's type is not.
	]]
	local function isAnnotationColon(): boolean
		local position = skipSpace(index)
		local byte = string.byte(source, position)
		if byte == nil then
			return false
		end
		if byte == BYTE_OPEN_PAREN or byte == BYTE_OPEN_BRACE then
			return true
		end
		local afterChain = skipIdenChain(position)
		if afterChain == nil then
			return false
		end
		local nextByte = string.byte(source, skipSpace(afterChain))
		return nextByte ~= BYTE_OPEN_PAREN
			and nextByte ~= BYTE_OPEN_BRACE
			and nextByte ~= BYTE_QUOTE
			and nextByte ~= BYTE_APOSTROPHE
			and nextByte ~= BYTE_BACKTICK
	end

	--[[
		Decides whether the source after a type keyword looks like an alias
		declaration, meaning a name, optional generic parameter list, and an
		equals sign. This keeps calls to a variable named type lexing as
		plain code.
	]]
	local function isAliasHead(): boolean
		local position = skipSpace(index)
		local byte = string.byte(source, position)
		if byte == nil or not IS_IDEN_START[byte] then
			return false
		end
		while position <= size and IS_IDEN_CHAR[string.byte(source, position)] do
			position += 1
		end
		position = skipSpace(position)
		if string.byte(source, position) == BYTE_LESS_THAN then
			local angle = 0
			while position <= size do
				local angleByte = string.byte(source, position)
				if angleByte == BYTE_LESS_THAN then
					angle += 1
				elseif angleByte == string.byte(">") then
					angle -= 1
					if angle == 0 then
						position += 1
						break
					end
				end
				position += 1
			end
			position = skipSpace(position)
		end
		return string.byte(source, position) == BYTE_EQUALS and string.byte(source, position + 1) ~= BYTE_EQUALS
	end

	--[[
		Scans an identifier and classifies it. Type contexts win over the
		builtin table so annotations color consistently, and the library
		member heuristic still recognizes things like math.floor.
	]]
	local function scanIden()
		typeofArmed = false
		local start = index
		index += 1
		while index <= size and IS_IDEN_CHAR[string.byte(source, index)] do
			index += 1
		end
		local text = string.sub(source, start, index - 1)
		typeContinues = false

		if aliasNamePending then
			aliasNamePending = false
			emit("type", text)
			enterTypeMode()
			aliasAwaitEquals = true
			typeContinues = true
			return
		end

		if keywords[text] ~= nil then
			if typeMode then
				if text == "typeof" then
					emit("keyword", text)
					typeofArmed = true
					return
				end
				if not TYPE_EXPRESSION_KEYWORDS[text] then
					exitTypeMode()
				end
			elseif text == "type" and isAliasHead() then
				aliasNamePending = true
			end
			emit("keyword", text)
			return
		end

		if typeMode and typeofDepth == nil then
			emit("type", text)
			return
		end

		if builtins[text] ~= nil then
			emit("builtin", text)
			return
		end

		if string.find(previous1, "%.[%s%c]*$") ~= nil and previousKind ~= "comment" then
			local parent = string.gsub(previous2, "[%c%s]+", "")
			local libraryMembers = libraries[parent]
			if
				libraryMembers ~= nil
				and libraryMembers[text] ~= nil
				and string.find(previous3, "%.[%s%c]*$") == nil
			then
				emit("builtin", text)
				return
			end
		end

		emit("iden", text)
	end

	--[[
		Scans a numeric literal by skipping a number-like pattern exactly the
		way Luau's own lexer does. It greedily takes digits, dots, and
		underscores, then an exponent marker with an optional sign, then any
		trailing alphanumeric run. That trailing run is what keeps hex and
		binary notations whole and keeps malformed literals like 1.2.3 or 3px
		lexing as a single number token, matching how Luau reports them.
	]]
	local function scanNumber()
		typeofArmed = false
		typeContinues = false
		local start = index

		repeat
			index += 1
			local byte = string.byte(source, index)
		until byte == nil or not (IS_DIGIT[byte] or byte == BYTE_DOT or byte == BYTE_UNDERSCORE)

		local exponentByte = string.byte(source, index)
		if exponentByte == BYTE_LOWER_E or exponentByte == BYTE_UPPER_E then
			index += 1
			local signByte = string.byte(source, index)
			if signByte == BYTE_PLUS or signByte == BYTE_DASH then
				index += 1
			end
		end

		while index <= size and IS_NUMBER_TAIL[string.byte(source, index)] do
			index += 1
		end

		emit("number", string.sub(source, start, index - 1))
	end

	--[[
		Advances past a backslash escape inside a string, mirroring Luau's
		readBackslashInString. An escaped carriage return also takes the line
		feed after it, and a z escape swallows all following whitespace
		including line breaks so the string continues on the next line.
	]]
	local function skipEscape()
		local escapeByte = string.byte(source, index + 1)
		if escapeByte == nil then
			index += 1
		elseif escapeByte == BYTE_RETURN then
			index += 2
			if string.byte(source, index) == BYTE_NEWLINE then
				index += 1
			end
		elseif escapeByte == BYTE_LOWER_Z then
			index += 2
			while index <= size and IS_SPACE[string.byte(source, index)] do
				index += 1
			end
		else
			index += 2
		end
	end

	--[[
		Scans a quoted string with real escape handling, so escaped quotes
		stay inside the string and an escaped backslash before the closing
		quote still closes it. An unfinished string runs through the end of
		its line.
	]]
	local function scanQuoted(quoteByte: number)
		typeofArmed = false
		typeContinues = false
		local start = index
		index += 1
		while index <= size do
			local byte = string.byte(source, index)
			if byte == BYTE_BACKSLASH then
				skipEscape()
			elseif byte == quoteByte or byte == BYTE_NEWLINE or byte == BYTE_RETURN then
				index += 1
				break
			else
				index += 1
			end
		end
		local text = string.sub(source, start, index - 1)
		emit("string", text)
		if string.find(text, "\n", 1, true) ~= nil then
			checkTypeNewline()
		end
	end

	--[[
		Reads the level of a long bracket opener at the given position,
		returning the count of equals signs or nil when it is not one.
	]]
	local function matchLongOpen(position: number): number?
		if string.byte(source, position) ~= BYTE_OPEN_BRACKET then
			return nil
		end
		local level = 0
		local cursor = position + 1
		while string.byte(source, cursor) == BYTE_EQUALS do
			level += 1
			cursor += 1
		end
		if string.byte(source, cursor) == BYTE_OPEN_BRACKET then
			return level
		end
		return nil
	end

	--[[
		Scans from a long bracket opener through its matching closer, or to
		the end of the source when unfinished, emitting the given kind.
	]]
	local function scanLongBracket(kind: string, start: number, level: number, bodyStart: number)
		typeofArmed = false
		typeContinues = false
		local closer = "]" .. string.rep("=", level) .. "]"
		local _, finish = string.find(source, closer, bodyStart, true)
		if finish ~= nil then
			index = finish + 1
		else
			index = size + 1
		end
		local text = string.sub(source, start, index - 1)
		emit(kind, text)
		if string.find(text, "\n", 1, true) ~= nil then
			checkTypeNewline()
		end
	end

	--[[
		Scans a comment, either a long bracket form or a line comment that
		runs through its newline.
	]]
	local function scanComment()
		typeofArmed = false
		local start = index
		local level = matchLongOpen(index + 2)
		if level ~= nil then
			scanLongBracket("comment", start, level, index + 2 + level + 2)
			return
		end
		local newlineAt = string.find(source, "\n", index + 2, true)
		if newlineAt ~= nil then
			index = newlineAt + 1
		else
			index = size + 1
		end
		local text = string.sub(source, start, index - 1)
		emit("comment", text)
		if string.find(text, "\n", 1, true) ~= nil then
			checkTypeNewline()
		end
	end

	--[[
		Scans one string piece of an interpolated string, starting at the
		opening backtick or at the brace that just closed a hole. Returns
		"hole" when the piece ends by opening a hole, and nil when the
		string ends, hits a bare newline, or hits the end of the source.
	]]
	local function scanInterpPiece(): string?
		typeofArmed = false
		typeContinues = false
		local start = index
		index += 1
		while index <= size do
			local byte = string.byte(source, index)
			if byte == BYTE_BACKSLASH then
				-- A unicode escape's brace belongs to the string text, so it
				-- must not open an interpolation hole.
				if
					string.byte(source, index + 1) == BYTE_LOWER_U
					and string.byte(source, index + 2) == BYTE_OPEN_BRACE
				then
					index += 3
				else
					skipEscape()
				end
			elseif byte == BYTE_BACKTICK or byte == BYTE_NEWLINE or byte == BYTE_RETURN then
				index += 1
				emit("string", string.sub(source, start, index - 1))
				return nil
			elseif byte == BYTE_OPEN_BRACE then
				index += 1
				emit("string", string.sub(source, start, index - 1))
				return "hole"
			else
				index += 1
			end
		end
		emit("string", string.sub(source, start, index - 1))
		return nil
	end

	--[[
		Applies an operator's side effects: bracket depth, interpolation
		hole tracking, and the type context's entries and exits.
	]]
	local function handleOperator(operator: string)
		if operator == "(" or operator == "{" or operator == "[" then
			depth += 1
			if operator == "(" and typeofArmed then
				typeofDepth = depth
			end
		elseif operator == ")" or operator == "}" or operator == "]" then
			if typeMode and depth <= typeEntryDepth then
				exitTypeMode()
			end
			depth = math.max(depth - 1, 0)
			if typeofDepth ~= nil and depth < typeofDepth then
				typeofDepth = nil
			end
		elseif operator == "::" then
			enterTypeMode()
		elseif operator == "->" then
			if not typeMode then
				enterTypeMode()
			end
		elseif operator == ":" then
			if not typeMode and isAnnotationColon() then
				enterTypeMode()
			end
		elseif operator == "=" then
			if typeMode and depth <= typeEntryDepth and typeAngle == 0 then
				if aliasAwaitEquals then
					aliasAwaitEquals = false
				else
					exitTypeMode()
				end
			end
		elseif operator == "," or operator == ";" then
			if typeMode and depth <= typeEntryDepth and typeAngle == 0 then
				exitTypeMode()
			end
		elseif operator == "<" then
			if typeMode then
				typeAngle += 1
			end
		elseif operator == ">" then
			if typeMode and typeAngle > 0 then
				typeAngle -= 1
			end
		end
		typeofArmed = false
		typeContinues = TYPE_CONTINUERS[operator] == true
	end

	--[[
		Scans an at sign, taking the attribute name with it when one follows
		so @native lexes as a single token the way Luau's lexer reads it. A
		bare at sign, including the one that opens an @[...] attribute list,
		stays a lone operator.
	]]
	local function scanAttribute()
		typeofArmed = false
		typeContinues = false
		local start = index
		index += 1
		local nameByte = string.byte(source, index)
		if nameByte ~= nil and IS_IDEN_START[nameByte] then
			repeat
				index += 1
			until index > size or not IS_IDEN_CHAR[string.byte(source, index)]
			emit("keyword", string.sub(source, start, index - 1))
		else
			emit("operator", "@")
		end
	end

	--[[
		Scans an operator, longest lexeme first. Bytes that are not part of
		any operator become single-character iden tokens so the stream
		still covers them.
	]]
	local function scanOperator()
		local three = string.sub(source, index, index + 2)
		if THREE_CHAR_OPERATORS[three] then
			index += 3
			emit("operator", three)
			handleOperator(three)
			return
		end
		local two = string.sub(source, index, index + 1)
		if TWO_CHAR_OPERATORS[two] then
			index += 2
			emit("operator", two)
			handleOperator(two)
			return
		end
		local one = string.sub(source, index, index)
		index += 1
		if SINGLE_CHAR_OPERATORS[one] then
			emit("operator", one)
			handleOperator(one)
		else
			typeofArmed = false
			typeContinues = false
			emit("iden", one)
		end
	end

	while index <= size do
		local byte = string.byte(source, index)
		if IS_SPACE[byte] then
			local start = index
			repeat
				index += 1
			until index > size or not IS_SPACE[string.byte(source, index)]
			local run = string.sub(source, start, index - 1)
			emitSuffix(run)
			if string.find(run, "\n", 1, true) ~= nil then
				checkTypeNewline()
			end
		elseif IS_IDEN_START[byte] then
			scanIden()
		elseif IS_DIGIT[byte] or (byte == BYTE_DOT and IS_DIGIT[string.byte(source, index + 1) or 0]) then
			scanNumber()
		elseif byte == BYTE_DASH and string.byte(source, index + 1) == BYTE_DASH then
			scanComment()
		elseif byte == BYTE_QUOTE or byte == BYTE_APOSTROPHE then
			scanQuoted(byte)
		elseif byte == BYTE_BACKTICK then
			if scanInterpPiece() == "hole" then
				table.insert(holeStack, depth)
			end
		elseif byte == BYTE_CLOSE_BRACE and holeStack[#holeStack] == depth then
			table.remove(holeStack)
			if typeMode and typeEntryDepth >= depth then
				exitTypeMode()
			end
			if scanInterpPiece() == "hole" then
				table.insert(holeStack, depth)
			end
		elseif byte == BYTE_OPEN_BRACKET then
			local level = matchLongOpen(index)
			if level ~= nil then
				scanLongBracket("string", index, level, index + level + 2)
			else
				scanOperator()
			end
		elseif byte == BYTE_AT then
			scanAttribute()
		else
			scanOperator()
		end
	end

	flushQueued()
	if pendingPrefix ~= "" then
		yield("iden", pendingPrefix)
	end
end

--[[
	Creates a token iterator over the given source. Each call to the
	returned function produces the next (kind, content) pair. When a
	startIndex is given, scanning begins at that byte with fresh context,
	so tokens whose meaning depends on what came earlier (type positions,
	interpolation holes, library members) may classify differently than
	they would in a full scan.
]]
function Lexer.scan(source: string, startIndex: number?): () -> (string?, string)
	local thread = coroutine.create(function()
		scanSource(source, coroutine.yield, startIndex)
	end)

	return function(): (string?, string)
		if coroutine.status(thread) ~= "dead" then
			-- The type checks narrow resume's untyped results and always pass,
			-- since the scanner only ever yields a pair of strings.
			local success, kind, content = coroutine.resume(thread)
			if success and type(kind) == "string" and type(content) == "string" then
				return kind, content
			end
		end
		return nil, ""
	end
end

--[[
	Builds a token navigator supporting non-sequential reads over a source,
	caching scanned tokens so earlier ones can be revisited.
]]
function Lexer.navigator()
	return Navigator.new(Lexer.scan)
end

return Lexer
