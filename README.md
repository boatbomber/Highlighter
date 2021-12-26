# Highlighter
RichText highlighting Lua code with a pure Lua lexer

Usage:
```Lua
local Highlighter = require(script.Highlighter)

Highlighter(TextLabel) -- Highlights the text in the TextLabel

-- Alternatively
Highlighter.Highlight(TextLabel) -- Identical to just calling
```
Changing Colors:
```Lua
-- Any of the given entries can be left nil for default
Highlighter.UpdateColors({
	background = Color3.new(...),
	iden = Color3.new(...),
	keyword = Color3.new(...),
	builtin = Color3.new(...),
	string = Color3.new(...),
	number = Color3.new(...),
	comment = Color3.new(...),
	operator = Color3.new(...)
})
```
Reset colors to default:
```Lua
Highlighter.UpdateColors()
```
