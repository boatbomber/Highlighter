--!strict

--[[
	Static classification tables the scanner dispatches on. The language module
	holds the word tables, while this module holds raw byte values, byte class
	lookups, and operator lexeme sets.
]]

-- Byte class lookups, indexed by byte value. Bytes at 128 and above are
-- treated as identifier characters so multibyte text lexes as idens.
local IS_SPACE: { [number]: boolean } = {}
local IS_DIGIT: { [number]: boolean } = {}
local IS_IDEN_START: { [number]: boolean } = {}
local IS_IDEN_CHAR: { [number]: boolean } = {}
for byteValue = 0, 255 do
	local char = string.char(byteValue)
	IS_SPACE[byteValue] = string.find(char, "[%c%s]") ~= nil
	IS_DIGIT[byteValue] = string.find(char, "%d") ~= nil
	IS_IDEN_START[byteValue] = string.find(char, "[%a_]") ~= nil or byteValue >= 128
	IS_IDEN_CHAR[byteValue] = string.find(char, "[%w_]") ~= nil or byteValue >= 128
end

-- Operator lexemes by length, checked longest first.
local THREE_CHAR_OPERATORS: { [string]: boolean } = { ["..="] = true, ["..."] = true, ["//="] = true }
local TWO_CHAR_OPERATORS: { [string]: boolean } = {
	["::"] = true,
	["->"] = true,
	["=="] = true,
	["~="] = true,
	["<="] = true,
	[">="] = true,
	["+="] = true,
	["-="] = true,
	["*="] = true,
	["/="] = true,
	["%="] = true,
	["^="] = true,
	[".."] = true,
	["//"] = true,
}
local SINGLE_CHAR_OPERATORS: { [string]: boolean } = {}
for char in string.gmatch("+-*/%^#<>=(){}[];:,.?|&@~", ".") do
	SINGLE_CHAR_OPERATORS[char] = true
end

-- Tokens that let a type context survive a line break, like a trailing
-- union bar before a wrapped union member.
local TYPE_CONTINUERS: { [string]: boolean } = {
	["|"] = true,
	["&"] = true,
	[","] = true,
	["<"] = true,
	["("] = true,
	["{"] = true,
	["["] = true,
	["->"] = true,
	["::"] = true,
	[":"] = true,
	["="] = true,
	["."] = true,
}

-- Keywords that appear inside type expressions without ending them, since
-- nil, true, and false are singleton types and typeof wraps a value.
local TYPE_EXPRESSION_KEYWORDS: { [string]: boolean } = {
	["nil"] = true,
	["true"] = true,
	["false"] = true,
	["typeof"] = true,
}

return {
	-- Byte values the dispatcher compares against directly.
	BYTE_NEWLINE = string.byte("\n"),
	BYTE_QUOTE = string.byte('"'),
	BYTE_APOSTROPHE = string.byte("'"),
	BYTE_BACKTICK = string.byte("`"),
	BYTE_BACKSLASH = string.byte("\\"),
	BYTE_DASH = string.byte("-"),
	BYTE_DOT = string.byte("."),
	BYTE_EQUALS = string.byte("="),
	BYTE_OPEN_PAREN = string.byte("("),
	BYTE_OPEN_BRACE = string.byte("{"),
	BYTE_CLOSE_BRACE = string.byte("}"),
	BYTE_OPEN_BRACKET = string.byte("["),
	BYTE_LESS_THAN = string.byte("<"),

	IS_SPACE = IS_SPACE,
	IS_DIGIT = IS_DIGIT,
	IS_IDEN_START = IS_IDEN_START,
	IS_IDEN_CHAR = IS_IDEN_CHAR,

	THREE_CHAR_OPERATORS = THREE_CHAR_OPERATORS,
	TWO_CHAR_OPERATORS = TWO_CHAR_OPERATORS,
	SINGLE_CHAR_OPERATORS = SINGLE_CHAR_OPERATORS,

	TYPE_CONTINUERS = TYPE_CONTINUERS,
	TYPE_EXPRESSION_KEYWORDS = TYPE_EXPRESSION_KEYWORDS,
}
