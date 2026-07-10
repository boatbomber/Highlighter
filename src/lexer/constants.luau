--!strict

--[[
	Static classification tables the scanner dispatches on. The language module
	holds the word tables, while this module holds raw byte values and byte
	class lookups. Operator lexemes and the type context words live inline in
	the scanner's comparison chains since nothing else reads them.
]]

-- Byte class lookups, indexed by byte value. Bytes at 128 and above are
-- treated as identifier characters so multibyte text lexes as idens.
local IS_SPACE: { [number]: boolean } = {}
local IS_DIGIT: { [number]: boolean } = {}
local IS_IDEN_START: { [number]: boolean } = {}
local IS_IDEN_CHAR: { [number]: boolean } = {}
local IS_NUMBER_TAIL: { [number]: boolean } = {}
for byteValue = 0, 255 do
	local char = string.char(byteValue)
	IS_SPACE[byteValue] = string.find(char, "[%c%s]") ~= nil
	IS_DIGIT[byteValue] = string.find(char, "%d") ~= nil
	IS_IDEN_START[byteValue] = string.find(char, "[%a_]") ~= nil or byteValue >= 128
	IS_IDEN_CHAR[byteValue] = string.find(char, "[%w_]") ~= nil or byteValue >= 128
	-- Number tails follow Luau's lexer, which greedily consumes trailing
	-- ASCII alphanumerics so malformed literals like 3px stay one token.
	IS_NUMBER_TAIL[byteValue] = string.find(char, "[%w_]") ~= nil
end

return {
	-- Byte values the dispatcher compares against directly.
	BYTE_NEWLINE = string.byte("\n"),
	BYTE_RETURN = string.byte("\r"),
	BYTE_QUOTE = string.byte('"'),
	BYTE_APOSTROPHE = string.byte("'"),
	BYTE_BACKTICK = string.byte("`"),
	BYTE_BACKSLASH = string.byte("\\"),
	BYTE_DASH = string.byte("-"),
	BYTE_PLUS = string.byte("+"),
	BYTE_STAR = string.byte("*"),
	BYTE_SLASH = string.byte("/"),
	BYTE_PERCENT = string.byte("%"),
	BYTE_CARET = string.byte("^"),
	BYTE_HASH = string.byte("#"),
	BYTE_TILDE = string.byte("~"),
	BYTE_DOT = string.byte("."),
	BYTE_COMMA = string.byte(","),
	BYTE_COLON = string.byte(":"),
	BYTE_SEMICOLON = string.byte(";"),
	BYTE_QUESTION = string.byte("?"),
	BYTE_PIPE = string.byte("|"),
	BYTE_AMPERSAND = string.byte("&"),
	BYTE_UNDERSCORE = string.byte("_"),
	BYTE_EQUALS = string.byte("="),
	BYTE_OPEN_PAREN = string.byte("("),
	BYTE_CLOSE_PAREN = string.byte(")"),
	BYTE_OPEN_BRACE = string.byte("{"),
	BYTE_CLOSE_BRACE = string.byte("}"),
	BYTE_OPEN_BRACKET = string.byte("["),
	BYTE_CLOSE_BRACKET = string.byte("]"),
	BYTE_LESS_THAN = string.byte("<"),
	BYTE_GREATER_THAN = string.byte(">"),
	BYTE_AT = string.byte("@"),
	BYTE_LOWER_E = string.byte("e"),
	BYTE_UPPER_E = string.byte("E"),
	BYTE_LOWER_U = string.byte("u"),
	BYTE_LOWER_Z = string.byte("z"),

	IS_SPACE = IS_SPACE,
	IS_DIGIT = IS_DIGIT,
	IS_IDEN_START = IS_IDEN_START,
	IS_IDEN_CHAR = IS_IDEN_CHAR,
	IS_NUMBER_TAIL = IS_NUMBER_TAIL,
}
