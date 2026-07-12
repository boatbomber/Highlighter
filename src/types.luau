--!strict

--[[
	Shared type definitions used across the highlighter's modules. This module
	only exports types, so it returns nil.
]]

export type TextObject = TextLabel | TextBox

export type TokenName =
	"background"
	| "iden"
	| "keyword"
	| "builtin"
	| "type"
	| "string"
	| "number"
	| "comment"
	| "operator"
	| "custom"

export type TokenColors = {
	[TokenName]: Color3?,
}

export type HighlightProps = {
	textObject: TextObject,
	src: string?,
	forceUpdate: boolean?,
	lexer: Lexer?,
	customLang: { [string]: string }?,
}

export type BuildRichTextLinesProps = {
	src: string,
	lexer: Lexer?,
	customLang: { [string]: string }?,
}

-- The navigator contract label population resumes through. Next follows the
-- scan iterator's convention where the second value only matters while the
-- first is non-nil. A lexer may return a richer navigator (the built-in one
-- also carries Peek), but populate only requires these five methods and
-- falls back to plain scanning when any of them is missing.
export type TokenNavigator = {
	SetSource: (self: TokenNavigator, sourceString: string) -> (),
	HotswapSource: (self: TokenNavigator, sourceString: string) -> number,
	SeekToByte: (self: TokenNavigator, position: number) -> number,
	Next: (self: TokenNavigator) -> (string?, string),
	Destroy: (self: TokenNavigator) -> (),
}

export type Lexer = {
	scan: (src: string, startIndex: number?) -> () -> (TokenName?, string),
	scanEach: ((src: string, onToken: (TokenName, string) -> ()) -> ())?,
	navigator: (() -> TokenNavigator)?,
}

export type LabelingInfo = {
	textHeight: number,
	innerAbsoluteSize: Vector2,
	textColor: Color3,
	textFont: Font,
	textSize: number,
	labelSize: UDim2,
}

export type ObjectData = {
	Text: string,
	Labels: { TextLabel },
	RichLines: { string },
	Lexer: Lexer?,
	CustomLang: { [string]: string }?,
	-- The token navigator serving this textObject's rebuilds, present when
	-- the lexer offers a navigator factory whose result carries the full
	-- TokenNavigator contract.
	Navigator: TokenNavigator?,
}

return nil
