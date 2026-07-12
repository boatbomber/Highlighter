# Highlighter

Highlighter renders syntax highlighted Luau code in Roblox using RichText and a pure Luau lexer.

## Installation

### Wally

```toml
[dependencies]
Highlighter = "boatbomber/highlighter@0.10.0"
```

### Roblox model

You can download a model file from the [Releases](https://github.com/boatbomber/Highlighter/releases) page.

## API

### Functions

```Lua
function Highlighter.highlight(props: types.HighlightProps): () -> ()
```

Highlights the given textObject with the given props and returns a cleanup function.
Highlighting will automatically update when needed, so the cleanup function will disconnect those connections and remove all labels.

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

### Properties

```Lua
Highlighter.defaultLexer: Lexer
```

The read-only built-in Luau lexer, used whenever props don't provide one. Assigning to `Highlighter.defaultLexer` is not supported, it is read-only.
Its scanning flow is documented in [docs/lexer.md](docs/lexer.md).
Its `navigator` factory is what lets `highlight` reuse cached tokens across edits, so typing near the end of a source only rescans and rebuilds the tail lines.
A custom lexer without one still works and pays a full scan per update, and a navigator missing any part of the `TokenNavigator` contract is ignored the same way rather than crashing.

### Types

```Lua
type TextObject = TextLabel | TextBox

type TokenName =
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

type TokenColors = {
    [TokenName]: Color3?,
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

type TokenNavigator = {
    SetSource: (self: TokenNavigator, sourceString: string) -> (),
    HotswapSource: (self: TokenNavigator, sourceString: string) -> number,
    SeekToByte: (self: TokenNavigator, position: number) -> number,
    Next: (self: TokenNavigator) -> (string?, string),
    Destroy: (self: TokenNavigator) -> (),
}

type Lexer = {
    scan: (src: string, startIndex: number?) -> () -> (TokenName?, string),
    scanEach: ((src: string, onToken: (TokenName, string) -> ()) -> ())?,
    navigator: (() -> TokenNavigator)?,
}
```

`customLang` is treated as immutable while it is in use by a highlighted TextObject. To change its mappings, pass a new table to `highlight`, or call `highlight` with `forceUpdate = true` after changing the existing table.

## Simple Example

```Lua
local Highlighter = require(script.Highlighter)

-- Inside a Studio plugin, this automatically matches the Studio theme.
Highlighter.matchStudioSettings()

-- This adds syntax highlighting to myTextLabel.
Highlighter.highlight({
    textObject = myTextLabel,
})
```

## Reference

The bundled lexer's scanning flow, state machine, and deliberate deviations from upstream are documented in [docs/lexer.md](docs/lexer.md).
The native [Luau lexer](https://github.com/luau-lang/luau/blob/master/Ast/src/Lexer.cpp) and [Luau parser](https://github.com/luau-lang/luau/blob/master/Ast/src/Parser.cpp) are useful references for how the language tokenizes.
