# Highlighter

RichText highlighting Lua code with a pure Lua lexer

## Installation

Wally:

```toml
[dependencies]
Highlighter = "boatbomber/highlighter@0.9.0"
```

Roblox Model:

Download from [Releases](https://github.com/boatbomber/Highlighter/releases)

## API

**Functions:**

```Lua
function Highlighter.highlight(props: types.HighlightProps): () -> ()
```

Highlights the given textObject with the given props and returns a cleanup function.
Highlighting will automatically update when needed, so the cleanup function will disconnect
those connections and remove all labels.

```Lua
function Highlighter.buildRichTextLines(props: types.BuildRichTextLinesProps): { string }
```

Builds rich text lines from the given props. Useful for building rich text highlight strings for other UI objects.

```Lua
function Highlighter.refresh(): ()
```

Refreshes all highlighted textObjects. Automatically runs when the theme changes.

```Lua
function Highlighter.setTokenColors(colors: types.TokenColors): ()
```

Sets the token colors to the given colors and refreshes all highlighted textObjects.

```Lua
function Highlighter.getTokenColor(tokenName: types.TokenName): Color3
```

Gets a token color by name.
Mainly useful for setting "background" token color on other UI objects behind your text.

```Lua
function Highlighter.matchStudioSettings(): ()
```

Matches the token colors to the Studio theme settings and refreshes all highlighted textObjects.
Does nothing when not run in a Studio plugin.

**Types:**

```Lua
type TextObject = TextLabel | TextBox

type TokenName =
    "background"
    | "iden"
    | "keyword"
    | "builtin"
    | "string"
    | "number"
    | "comment"
    | "operator"
    | "custom"

type TokenColors = {
    ["background"]: Color3?,
    ["iden"]: Color3?,
    ["keyword"]: Color3?,
    ["builtin"]: Color3?,
    ["string"]: Color3?,
    ["number"]: Color3?,
    ["comment"]: Color3?,
    ["operator"]: Color3?,
    ["custom"]: Color3?,
}

type HighlightProps = {
    textObject: TextObject,
    src: string?,
    forceUpdate: boolean?,
    lexer: Lexer?,
    customLang: { [string]: string }?,
}

type BuildRichTextLinesProps = {
 src: string,
 lexer: Lexer?,
 customLang: { [string]: string }?,
}

type Lexer = {
    scan: (src: string, start: number?) -> () -> (string, string),
    navigator: () -> any,
    finished: boolean?,
}
```

## Simple Example

```Lua
local Highlighter = require(script.Highlighter)

-- When using in a Studio Plugin, this will automatically match the Studio theme
Highlighter.matchStudioSettings()

-- Add syntax highlighting to myTextLabel
Highlighter.highlight({
    textObject: myTextLabel,
})
```
