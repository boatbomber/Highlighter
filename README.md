# Highlighter
RichText highlighting Lua code with a pure Lua lexer

*Note: Intended for use with short snippets, not long programs. The outputted RichText string ends up going over the length limit of a TextLabel rather quickly.*

Usage:
```Lua
local Highlighter = require(script.Highlighter)

Highlighter(TextLabel) -- Highlights the text in the TextLabel
```
