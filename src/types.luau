--!strict

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

export type Lexer = {
	scan: (src: string, startIndex: number?) -> () -> (TokenName?, string),
	navigator: () -> any,
}

export type LabelingInfo = {
	data: ObjectData,
	numLines: number,
	textBounds: Vector2,
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
	Lines: { string },
	Lexer: Lexer?,
	CustomLang: { [string]: string }?,
}

return nil
