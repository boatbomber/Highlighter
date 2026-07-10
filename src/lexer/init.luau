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
local BYTE_STAR = constants.BYTE_STAR
local BYTE_SLASH = constants.BYTE_SLASH
local BYTE_PERCENT = constants.BYTE_PERCENT
local BYTE_CARET = constants.BYTE_CARET
local BYTE_HASH = constants.BYTE_HASH
local BYTE_TILDE = constants.BYTE_TILDE
local BYTE_DOT = constants.BYTE_DOT
local BYTE_COMMA = constants.BYTE_COMMA
local BYTE_COLON = constants.BYTE_COLON
local BYTE_SEMICOLON = constants.BYTE_SEMICOLON
local BYTE_QUESTION = constants.BYTE_QUESTION
local BYTE_PIPE = constants.BYTE_PIPE
local BYTE_AMPERSAND = constants.BYTE_AMPERSAND
local BYTE_UNDERSCORE = constants.BYTE_UNDERSCORE
local BYTE_EQUALS = constants.BYTE_EQUALS
local BYTE_OPEN_PAREN = constants.BYTE_OPEN_PAREN
local BYTE_CLOSE_PAREN = constants.BYTE_CLOSE_PAREN
local BYTE_OPEN_BRACE = constants.BYTE_OPEN_BRACE
local BYTE_CLOSE_BRACE = constants.BYTE_CLOSE_BRACE
local BYTE_OPEN_BRACKET = constants.BYTE_OPEN_BRACKET
local BYTE_CLOSE_BRACKET = constants.BYTE_CLOSE_BRACKET
local BYTE_LESS_THAN = constants.BYTE_LESS_THAN
local BYTE_GREATER_THAN = constants.BYTE_GREATER_THAN
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

-- How many bytes past a token's start the restart watermark reserves for
-- the fixed peeks that never fold into maxRead, which are the one and two
-- byte reads in scanOperator, the dispatcher, and checkTypeNewline. The
-- deepest of those reaches one byte past the next token's start, from the
-- third byte read of a lone dot operator and the arrow peek after a line
-- break, and the second byte keeps a margin over them. A new peek reaching
-- deeper than this must fold its position into maxRead the way the long
-- lookahead helpers do, or hotswap reuse will silently trust tokens whose
-- lookahead crossed an edit.
local FIXED_PEEK_SLACK = 2

--[[
	Scans one source string, calling yield(kind, content) for every token.
	All scanner state lives in locals here so concurrent scans of different
	sources never interfere. When a token ends at a safely resumable point,
	its yield also carries the bracket depth there and the furthest byte the
	scan has read, which is what lets the navigator resume a scan partway
	through an edited source. The optional seed restores the state such a
	resumed scan needs beyond its start position.
]]
local function scanSource(
	source: string,
	yield: (string, string, number?, number?) -> (),
	startIndex: number?,
	seed: Navigator.ScanSeed?
)
	local size = #source
	local index = startIndex or 1

	-- Tokens queue briefly before yielding so trailing whitespace can merge
	-- into them, and whitespace before the first token becomes its prefix.
	local queuedKind: string? = nil
	local queuedText = ""
	local pendingPrefix = ""

	-- The last three emitted token lexemes feed the library member heuristic,
	-- mirroring how members are detected for things like math.floor without
	-- misreading foo.floor. They hold exact lexemes with no whitespace, which
	-- lets the heuristic compare interned strings instead of running pattern
	-- matches on the identifier hot path.
	local previous1, previous2, previous3 = "", "", ""

	-- Bracket depth across parens, braces, and square brackets in code, and
	-- the depths at which interpolation holes opened.
	local depth = 0
	local holeStack = {}

	-- A resumed scan restores the depth and previous token lexemes it would
	-- have had at this point in a full scan. Cached token contents carry
	-- merged whitespace, so they strip once here to restore the exact lexeme
	-- invariant the heuristic relies on.
	if seed ~= nil then
		depth = seed.depth
		previous1 = (string.gsub(seed.previous1, "[%c%s]+", ""))
		previous2 = (string.gsub(seed.previous2, "[%c%s]+", ""))
		previous3 = (string.gsub(seed.previous3, "[%c%s]+", ""))
	end

	-- The furthest byte position any lookahead has read. Restart snapshots
	-- report it so the navigator can prove that a cached token, and the
	-- scanner state after it, never depended on bytes that later changed.
	local maxRead = 0

	-- Snapshot of the resumable state at the start of the token currently
	-- being scanned. When restartable, the previous token's yield carries it,
	-- since the position right after that token is where a resume would begin.
	local snapDepth = 0
	local snapWatermark = 0
	local snapRestartable = false

	-- Type context state. While typeMode is on, identifiers lex as type
	-- tokens until the context exits at its entry depth. typeAngle tracks
	-- generic argument brackets, typeofDepth suspends type classification
	-- inside typeof(...) since it takes a value expression, and the alias
	-- flags carry a "type Name = ..." statement through its equals sign.
	-- typeExpectsWord arms whenever the next identifier can extend the type
	-- expression, which is right after entering the context or a connector
	-- operator. An identifier arriving unarmed means a new value expression
	-- started on the same line, so the context exits instead of swallowing it.
	local typeMode = false
	local typeEntryDepth = 0
	local typeAngle = 0
	local typeContinues = false
	local typeExpectsWord = false
	local typeofDepth: number? = nil
	local typeofArmed = false
	local aliasNamePending = false
	local aliasAwaitEquals = false

	local function flushQueued()
		if queuedKind ~= nil then
			-- The snapshot rides along only when the position after this
			-- token is a safe place to resume a scan from.
			if snapRestartable then
				yield(queuedKind, queuedText, snapDepth, snapWatermark)
			else
				yield(queuedKind, queuedText)
			end
			queuedKind, queuedText = nil, ""
		end
	end

	local function emit(kind: string, text: string)
		flushQueued()
		-- The lexeme records before the prefix joins it, so the previous
		-- token texts stay whitespace free even at the start of the source.
		previous3, previous2, previous1 = previous2, previous1, text
		if pendingPrefix ~= "" then
			text = pendingPrefix .. text
			pendingPrefix = ""
		end
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
		typeExpectsWord = true
		typeofDepth = nil
	end

	local function exitTypeMode()
		typeMode = false
		typeAngle = 0
		typeExpectsWord = false
		typeofDepth = nil
		aliasAwaitEquals = false
	end

	--[[
		Ends the type context when a line break lands at its entry depth,
		unless the last significant token promised a continuation or the next
		line leads with a union bar, an intersection ampersand, or a return
		arrow. No statement can start with those bytes, so a line leading with
		one can only be continuing the type expression. The scanner sits on
		the first byte after the whitespace run when this is called, which is
		what makes the peek a plain read of the current position.
	]]
	local function checkTypeNewline()
		if typeMode and depth <= typeEntryDepth and typeAngle == 0 and not typeContinues and not aliasAwaitEquals then
			local nextByte = string.byte(source, index)
			if nextByte == BYTE_PIPE or nextByte == BYTE_AMPERSAND then
				return
			end
			if nextByte == BYTE_DASH and string.byte(source, index + 1) == BYTE_GREATER_THAN then
				return
			end
			exitTypeMode()
		end
	end

	local function skipSpace(position: number): number
		while position <= size and IS_SPACE[string.byte(source, position)] do
			position += 1
		end
		if position > maxRead then
			maxRead = position
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
			if position > maxRead then
				maxRead = position
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
		-- The equals run can reach well past the byte the scanner ends up
		-- consuming, so a failed match still counts as lookahead.
		if cursor > maxRead then
			maxRead = cursor
		end
		if string.byte(source, cursor) == BYTE_OPEN_BRACKET then
			return level
		end
		return nil
	end

	--[[
		Steps over whitespace and comments starting at the given position and
		returns the position of the next significant byte, or nil when an
		unfinished comment hides the rest of the source. Used only for
		lookahead, so it never consumes input.
	]]
	local function skipInsignificant(position: number): number?
		position = skipSpace(position)
		while string.byte(source, position) == BYTE_DASH and string.byte(source, position + 1) == BYTE_DASH do
			local level = matchLongOpen(position + 2)
			if level ~= nil then
				local closer = "]" .. string.rep("=", level) .. "]"
				local _, finish = string.find(source, closer, position + 2 + level + 2, true)
				if finish == nil then
					-- The failed search read every remaining byte.
					if size > maxRead then
						maxRead = size
					end
					return nil
				end
				if finish > maxRead then
					maxRead = finish
				end
				position = skipSpace(finish + 1)
			else
				local newlineAt = string.find(source, "\n", position + 2, true)
				if newlineAt == nil then
					if size > maxRead then
						maxRead = size
					end
					return nil
				end
				if newlineAt > maxRead then
					maxRead = newlineAt
				end
				position = skipSpace(newlineAt + 1)
			end
		end
		return position
	end

	--[[
		Decides whether a colon at the scanner's position starts a type
		annotation rather than a method access. A method name is followed
		immediately by call arguments, while an annotation's type is not.
		Comments may sit on either side of the name, so the lookahead steps
		over them the way the scanner itself will.
	]]
	local function isAnnotationColon(): boolean
		local position = skipInsignificant(index)
		if position == nil then
			return false
		end
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
		local afterName = skipInsignificant(afterChain)
		if afterName == nil then
			-- A name followed by an unfinished comment shows no call
			-- arguments, so it reads as an annotation.
			return true
		end
		-- An open bracket after the name is a long bracket string argument,
		-- since no type syntax puts one directly after an identifier chain.
		local nextByte = string.byte(source, afterName)
		return nextByte ~= BYTE_OPEN_PAREN
			and nextByte ~= BYTE_OPEN_BRACE
			and nextByte ~= BYTE_QUOTE
			and nextByte ~= BYTE_APOSTROPHE
			and nextByte ~= BYTE_BACKTICK
			and nextByte ~= BYTE_OPEN_BRACKET
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
		if position > maxRead then
			maxRead = position
		end
		position = skipSpace(position)
		if string.byte(source, position) == BYTE_LESS_THAN then
			local angle = 0
			while position <= size do
				local angleByte = string.byte(source, position)
				if angleByte == BYTE_LESS_THAN then
					angle += 1
				elseif angleByte == BYTE_GREATER_THAN then
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
		if position + 1 > maxRead then
			maxRead = position + 1
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
					typeExpectsWord = false
					return
				end
				-- nil, true, and false are singleton types, so they stay
				-- legal inside a type expression while any other keyword
				-- ends the context.
				if text ~= "nil" and text ~= "true" and text ~= "false" then
					exitTypeMode()
				else
					typeExpectsWord = false
				end
			elseif text == "type" and isAliasHead() then
				aliasNamePending = true
			end
			emit("keyword", text)
			return
		end

		if typeMode and typeofDepth == nil then
			if typeExpectsWord then
				typeExpectsWord = false
				emit("type", text)
				return
			end
			-- The type expression cannot take another bare identifier, so
			-- this one starts a new value expression and classifies below.
			exitTypeMode()
		end

		if builtins[text] ~= nil then
			emit("builtin", text)
			return
		end

		-- A library member sits directly after a member access dot whose left
		-- side is a known library that is not itself a member access, which
		-- keeps foo.math.floor plain. The previous lexemes are exact interned
		-- strings, so equality against the dot operator is all this costs.
		if previous1 == "." and previous3 ~= "." then
			local libraryMembers = libraries[previous2]
			if libraryMembers ~= nil and libraryMembers[text] ~= nil then
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
		typeExpectsWord = false
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
		readBackslashInString, and returns whether it consumed a line feed so
		string scanners can track line breaks without rescanning their text.
		An escaped carriage return also takes the line feed after it, and a z
		escape swallows all following whitespace including line breaks so the
		string continues on the next line.
	]]
	local function skipEscape(): boolean
		local escapeByte = string.byte(source, index + 1)
		if escapeByte == nil then
			index += 1
			return false
		elseif escapeByte == BYTE_RETURN then
			index += 2
			if string.byte(source, index) == BYTE_NEWLINE then
				index += 1
				return true
			end
			return false
		elseif escapeByte == BYTE_LOWER_Z then
			index += 2
			local sawNewline = false
			while index <= size do
				local spaceByte = string.byte(source, index)
				if not IS_SPACE[spaceByte] then
					break
				end
				if spaceByte == BYTE_NEWLINE then
					sawNewline = true
				end
				index += 1
			end
			return sawNewline
		else
			index += 2
			return escapeByte == BYTE_NEWLINE
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
		typeExpectsWord = false
		local start = index
		local sawNewline = false
		index += 1
		while index <= size do
			local byte = string.byte(source, index)
			if byte == BYTE_BACKSLASH then
				if skipEscape() then
					sawNewline = true
				end
			elseif byte == quoteByte or byte == BYTE_NEWLINE or byte == BYTE_RETURN then
				if byte == BYTE_NEWLINE then
					sawNewline = true
				end
				index += 1
				break
			else
				index += 1
			end
		end
		emit("string", string.sub(source, start, index - 1))
		if sawNewline then
			checkTypeNewline()
		end
	end

	--[[
		Scans from a long bracket opener through its matching closer, or to
		the end of the source when unfinished, emitting the given kind.
	]]
	local function scanLongBracket(kind: string, start: number, level: number, bodyStart: number)
		typeofArmed = false
		-- Comments stay transparent to the type context so an annotation can
		-- carry past one, while a long string ends any continuation the same
		-- way a quoted string does.
		if kind == "string" then
			typeContinues = false
			typeExpectsWord = false
		end
		local closer = "]" .. string.rep("=", level) .. "]"
		local _, finish = string.find(source, closer, bodyStart, true)
		if finish ~= nil then
			index = finish + 1
		else
			-- The failed search read every remaining byte looking for the
			-- closer, so the whole source counts as lookahead.
			index = size + 1
			if size > maxRead then
				maxRead = size
			end
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
		emit("comment", string.sub(source, start, index - 1))
		-- The terminator search already answers whether the comment carried
		-- its newline, so no rescan of the text is needed.
		if newlineAt ~= nil then
			checkTypeNewline()
		end
	end

	--[[
		Emits one interpolated string piece running from start to the current
		index, ending the type context when the piece carried a line break the
		way every other string and comment scanner does. A piece can hold a
		line break as the bare one that terminated an unfinished string or
		through an escape like a backslash z, and the scanners that consume
		those bytes report the flag rather than rescanning the text.
	]]
	local function emitInterpPiece(start: number, sawNewline: boolean)
		emit("string", string.sub(source, start, index - 1))
		if sawNewline then
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
		local sawNewline = false
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
				elseif skipEscape() then
					sawNewline = true
				end
			elseif byte == BYTE_BACKTICK or byte == BYTE_NEWLINE or byte == BYTE_RETURN then
				if byte == BYTE_NEWLINE then
					sawNewline = true
				end
				index += 1
				emitInterpPiece(start, sawNewline)
				return nil
			elseif byte == BYTE_OPEN_BRACE then
				index += 1
				emitInterpPiece(start, sawNewline)
				return "hole"
			else
				index += 1
			end
		end
		emitInterpPiece(start, sawNewline)
		return nil
	end

	--[[
		Applies an operator's side effects: bracket depth, interpolation
		hole tracking, and the type context's entries and exits. Each branch
		also records whether the operator lets a type context survive a line
		break, like a trailing union bar before a wrapped union member, since
		the chain is already comparing against every lexeme that does.
	]]
	local function handleOperator(operator: string)
		local continues = false
		if operator == "(" or operator == "{" or operator == "[" then
			depth += 1
			if operator == "(" and typeofArmed then
				typeofDepth = depth
			end
			continues = true
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
			continues = true
		elseif operator == "->" then
			if not typeMode then
				enterTypeMode()
			end
			continues = true
		elseif operator == ":" then
			if not typeMode and isAnnotationColon() then
				enterTypeMode()
			end
			continues = true
		elseif operator == "=" then
			if typeMode and depth <= typeEntryDepth and typeAngle == 0 then
				if aliasAwaitEquals then
					aliasAwaitEquals = false
				else
					exitTypeMode()
				end
			end
			continues = true
		elseif operator == "," or operator == ";" then
			if typeMode and depth <= typeEntryDepth and typeAngle == 0 then
				exitTypeMode()
			end
			continues = operator == ","
		elseif operator == "<" then
			if typeMode then
				typeAngle += 1
			end
			continues = true
		elseif operator == ">" then
			if typeMode and typeAngle > 0 then
				typeAngle -= 1
			end
		elseif operator == "|" or operator == "&" or operator == "." then
			continues = true
		end
		typeofArmed = false
		typeContinues = continues
		-- Continuing operators are exactly the ones a type word can follow,
		-- except the semicolon, which separates table type fields but never
		-- carries a context past a line break.
		typeExpectsWord = continues or operator == ";"
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
		Scans an operator by dispatching on its first byte, checking longer
		lexemes before their prefixes so ..= wins over .. and a lone dot.
		Every emitted lexeme is an interned literal and the chain is ordered
		roughly by how often each family appears in real code, which keeps
		this path free of substring allocations and table lookups. Bytes that
		are not part of any operator become single-character iden tokens so
		the stream still covers them. The at sign never arrives here because
		the dispatcher sends it to the attribute path first, and neither do
		two dashes, which go to the comment scanner.
	]]
	local function scanOperator()
		local byte = string.byte(source, index)
		local nextByte = string.byte(source, index + 1)
		local operator: string? = nil

		if byte == BYTE_OPEN_PAREN then
			operator = "("
		elseif byte == BYTE_CLOSE_PAREN then
			operator = ")"
		elseif byte == BYTE_EQUALS then
			operator = if nextByte == BYTE_EQUALS then "==" else "="
		elseif byte == BYTE_DOT then
			if nextByte == BYTE_DOT then
				local thirdByte = string.byte(source, index + 2)
				operator = if thirdByte == BYTE_EQUALS then "..=" elseif thirdByte == BYTE_DOT then "..." else ".."
			else
				operator = "."
			end
		elseif byte == BYTE_COMMA then
			operator = ","
		elseif byte == BYTE_COLON then
			operator = if nextByte == BYTE_COLON then "::" else ":"
		elseif byte == BYTE_OPEN_BRACE then
			operator = "{"
		elseif byte == BYTE_CLOSE_BRACE then
			operator = "}"
		elseif byte == BYTE_OPEN_BRACKET then
			operator = "["
		elseif byte == BYTE_CLOSE_BRACKET then
			operator = "]"
		elseif byte == BYTE_DASH then
			operator = if nextByte == BYTE_GREATER_THAN then "->" elseif nextByte == BYTE_EQUALS then "-=" else "-"
		elseif byte == BYTE_PLUS then
			operator = if nextByte == BYTE_EQUALS then "+=" else "+"
		elseif byte == BYTE_STAR then
			operator = if nextByte == BYTE_EQUALS then "*=" else "*"
		elseif byte == BYTE_SLASH then
			if nextByte == BYTE_SLASH then
				operator = if string.byte(source, index + 2) == BYTE_EQUALS then "//=" else "//"
			else
				operator = if nextByte == BYTE_EQUALS then "/=" else "/"
			end
		elseif byte == BYTE_LESS_THAN then
			operator = if nextByte == BYTE_EQUALS then "<=" else "<"
		elseif byte == BYTE_GREATER_THAN then
			operator = if nextByte == BYTE_EQUALS then ">=" else ">"
		elseif byte == BYTE_TILDE then
			operator = if nextByte == BYTE_EQUALS then "~=" else "~"
		elseif byte == BYTE_PERCENT then
			operator = if nextByte == BYTE_EQUALS then "%=" else "%"
		elseif byte == BYTE_CARET then
			operator = if nextByte == BYTE_EQUALS then "^=" else "^"
		elseif byte == BYTE_SEMICOLON then
			operator = ";"
		elseif byte == BYTE_HASH then
			operator = "#"
		elseif byte == BYTE_QUESTION then
			operator = "?"
		elseif byte == BYTE_PIPE then
			operator = "|"
		elseif byte == BYTE_AMPERSAND then
			operator = "&"
		end

		if operator ~= nil then
			-- The rebind casts because the new solver leaves the nil check's
			-- intersection unsimplified instead of narrowing it to a string.
			local operatorText = operator :: string
			index += #operatorText
			emit("operator", operatorText)
			handleOperator(operatorText)
		else
			typeofArmed = false
			typeContinues = false
			emit("iden", string.sub(source, index, index))
			index += 1
		end
	end

	while index <= size do
		local byte = string.byte(source, index)
		if IS_SPACE[byte] then
			local start = index
			local sawNewline = byte == BYTE_NEWLINE
			while true do
				index += 1
				if index > size then
					break
				end
				local spaceByte = string.byte(source, index)
				if not IS_SPACE[spaceByte] then
					break
				end
				if spaceByte == BYTE_NEWLINE then
					sawNewline = true
				end
			end
			emitSuffix(string.sub(source, start, index - 1))
			if sawNewline then
				checkTypeNewline()
			end
		else
			-- This byte starts a token, so the state here is what a resumed
			-- scan would need. The point is restartable when every carried
			-- flag is in its ground state, since depth is seedable and the
			-- previous token texts come back from the navigator's cache. The
			-- watermark reserves slack for the fixed peeks the scan functions
			-- make past their consumed bytes.
			snapDepth = depth
			snapWatermark = math.max(maxRead, index + FIXED_PEEK_SLACK)
			snapRestartable = not typeMode and holeStack[1] == nil and not aliasNamePending and not typeofArmed
			if IS_IDEN_START[byte] then
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
	end

	-- The lingering snapshot belongs to the final token's own start, not to
	-- the position after it, so the final flush must not carry it. A restart
	-- at the very end of the source would have nothing to rescan anyway.
	snapRestartable = false
	flushQueued()
	if pendingPrefix ~= "" then
		yield("iden", pendingPrefix)
	end
end

--[[
	Creates a token iterator whose returns also carry restart snapshots, and
	which accepts a seed for resuming a scan partway through a source. The
	navigator reads through this richer form so HotswapSource can reuse
	cached tokens, and tests wrap it to observe where a resumed scan begins.
]]
function Lexer.scanRestartable(
	source: string,
	startIndex: number?,
	seed: Navigator.ScanSeed?
): () -> (string?, string, number?, number?)
	local thread = coroutine.create(function()
		scanSource(source, coroutine.yield, startIndex, seed)
	end)

	return function(): (string?, string, number?, number?)
		if coroutine.status(thread) ~= "dead" then
			-- The type checks narrow resume's untyped results. The first two
			-- always pass since the scanner only yields string pairs, while
			-- the snapshot values are missing on most tokens.
			local success, kind, content, restartDepth, watermark = coroutine.resume(thread)
			if success and type(kind) == "string" and type(content) == "string" then
				return kind,
					content,
					if type(restartDepth) == "number" then restartDepth else nil,
					if type(watermark) == "number" then watermark else nil
			end
		end
		return nil, "", nil, nil
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
	local iterate = Lexer.scanRestartable(source, startIndex, nil)

	return function(): (string?, string)
		-- The wrapper drops the restart snapshot values so they never leak
		-- into callers reading extra returns.
		local kind, content = iterate()
		return kind, content
	end
end

--[[
	Calls onToken with every token of the source in order. This walks the
	same scanner as Lexer.scan without the iterator's coroutine, which makes
	it the cheapest way to read a whole source when tokens can be handled as
	they arrive. The extra optional parameters carry the restart snapshots
	the scanner attaches to some tokens, which callers are free to ignore.
]]
function Lexer.scanEach(source: string, onToken: (string, string, number?, number?) -> ())
	scanSource(source, onToken, nil, nil)
end

--[[
	Builds a token navigator supporting non-sequential reads over a source,
	caching scanned tokens so earlier ones can be revisited.
]]
function Lexer.navigator()
	return Navigator.new(Lexer.scanRestartable)
end

return Lexer
