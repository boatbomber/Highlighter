export type HighlighterColors = { [string]: Color3 }

export type HighlightProps = {
	textObject: TextLabel | TextBox,
	src: string?,
	forceUpdate: boolean?,
	lexer: Lexer?,
}

export type Lexer = {
	scan: (src: string) -> () -> (string, string),
	navigator: () -> any,
	finished: boolean?,
}

export type Highlighter = {
	defaultLexer: Lexer,
	setTokenColors: (colors: HighlighterColors?) -> (),
	highlight: (props: HighlightProps) -> (() -> ())?,
	refresh: () -> (),
}

local function SanitizeRichText(s: string): string
	return string.gsub(
		string.gsub(string.gsub(string.gsub(string.gsub(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"), '"', "&quot;"),
		"'",
		"&apos;"
	)
end

local function SanitizeTabs(s: string): string
	return string.gsub(s, "\t", "    ")
end

local function SanitizeControl(s: string): string
	return string.gsub(s, "[\0\1\2\3\4\5\6\7\8\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31]+", "")
end

local TokenColors: HighlighterColors = {
	["background"] = Color3.fromRGB(47, 47, 47),
	["iden"] = Color3.fromRGB(234, 234, 234),
	["keyword"] = Color3.fromRGB(215, 174, 255),
	["builtin"] = Color3.fromRGB(131, 206, 255),
	["string"] = Color3.fromRGB(196, 255, 193),
	["number"] = Color3.fromRGB(255, 125, 125),
	["comment"] = Color3.fromRGB(140, 140, 155),
	["operator"] = Color3.fromRGB(255, 239, 148),
}
local ColorFormatter: { [Color3]: string } = {}
local LastData: { [TextLabel | TextBox]: { Text: string, Lexer: Lexer?, Lines: { TextLabel } } } = {}
local Cleanups: { [TextLabel | TextBox]: () -> () } = {}

local Highlighter = {
	defaultLexer = require(script.lexer),
}

function Highlighter.refresh(): ()
	-- Rehighlight existing labels using latest colors
	for textObject, data in pairs(LastData) do
		for _, lineLabel in ipairs(data.Lines) do
			lineLabel.TextColor3 = TokenColors["iden"]
		end

		Highlighter.highlight({
			textObject = textObject,
			src = data.Text,
			forceUpdate = true,
			lexer = data.Lexer,
		})
	end
end

function Highlighter.highlight(props: HighlightProps)
	-- Gather props
	local textObject = props.textObject
	local src = SanitizeTabs(SanitizeControl(props.src or textObject.Text))
	local lexer = props.lexer or Highlighter.defaultLexer

	-- Avoid updating when unnecessary
	local data = LastData[textObject]
	if not data then
		data = {
			Text = "",
			Lexer = lexer,
			Lines = {},
		}
		LastData[textObject] = data
	end
	if props.forceUpdate ~= true and data.Text == src then
		return
	end

	data.Text = src
	data.Lexer = lexer

	-- Ensure valid object properties
	textObject.RichText = false
	textObject.Text = src
	textObject.TextXAlignment = Enum.TextXAlignment.Left
	textObject.TextYAlignment = Enum.TextYAlignment.Top
	textObject.BackgroundColor3 = TokenColors.background
	textObject.TextColor3 = TokenColors.iden
	textObject.TextTransparency = 0.5

	-- Build the highlight labels
	local lineFolder = textObject:FindFirstChild("SyntaxHighlights")
	if lineFolder == nil then
		local newLineFolder = Instance.new("Folder")
		newLineFolder.Name = "SyntaxHighlights"
		newLineFolder.Parent = textObject

		lineFolder = newLineFolder
	end

	local _, numLines = string.gsub(src, "\n", "")
	numLines += 1

	-- Wait for TextBounds to be non-NaN and non-zero because Roblox
	local textBounds = textObject.TextBounds
	while (textBounds.Y ~= textBounds.Y) or (textBounds.Y < 1) do
		task.wait()
		textBounds = textObject.TextBounds
	end

	local textHeight = textBounds.Y / numLines

	local lineLabels = LastData[textObject].Lines
	for i = 1, math.max(numLines, #lineLabels) do
		local label: TextLabel? = lineLabels[i]
		if label ~= nil then
			label.Text = ""
			label.TextSize = textObject.TextSize
			label.Size = UDim2.new(1, 0, 0, math.ceil(textHeight))
			label.Position = UDim2.fromScale(0, textHeight * (i - 1) / textObject.AbsoluteSize.Y)
		else
			local newLabel = Instance.new("TextLabel")
			newLabel.Name = "Line_" .. i
			newLabel.RichText = true
			newLabel.BackgroundTransparency = 1
			newLabel.Text = ""
			newLabel.TextXAlignment = Enum.TextXAlignment.Left
			newLabel.TextYAlignment = Enum.TextYAlignment.Top
			newLabel.TextColor3 = TokenColors["iden"]
			newLabel.Font = textObject.Font
			newLabel.TextSize = textObject.TextSize
			newLabel.Size = UDim2.new(1, 0, 0, math.ceil(textHeight))
			newLabel.Position = UDim2.fromScale(0, textHeight * (i - 1) / textObject.AbsoluteSize.Y)
			newLabel.Parent = lineFolder
			lineLabels[i] = newLabel
		end
	end

	-- Lex and highlight appropriately
	local richText, index, lineNumber = {}, 0, 1
	for token: string, content: string in lexer.scan(src) do
		local Color = TokenColors[token] or TokenColors["iden"]

		local lines = string.split(SanitizeRichText(content), "\n")
		for l, line in ipairs(lines) do
			if l > 1 then
				-- Set line
				lineLabels[lineNumber].Text = table.concat(richText)
				-- Move to next line
				lineNumber += 1
				index = 0
				table.clear(richText)
			end

			index += 1

			-- Only add RichText tags when the color is non-default and the characters are non-whitespace
			if Color ~= TokenColors["iden"] and string.find(line, "[%S%C]") then
				richText[index] = string.format(ColorFormatter[Color], line)
			else
				richText[index] = line
			end
		end
	end

	-- Set final line
	lineLabels[lineNumber].Text = table.concat(richText)

	-- Add a cleanup handler for this textObject
	local cleanup = Cleanups[textObject]
	if not cleanup then
		local connections: { RBXScriptConnection } = {}
		local function newCleanup()
			for _, label in ipairs(lineLabels) do
				label:Destroy()
			end
			table.clear(lineLabels)
			lineLabels = nil

			LastData[textObject] = nil
			Cleanups[textObject] = nil

			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
			connections = nil
		end
		Cleanups[textObject] = newCleanup
		cleanup = newCleanup

		table.insert(
			connections,
			textObject.AncestryChanged:Connect(function()
				if textObject.Parent then
					return
				end

				cleanup()
			end)
		)
		table.insert(
			connections,
			textObject:GetPropertyChangedSignal("TextBounds"):Connect(function()
				Highlighter.highlight({
					textObject = textObject,
					lexer = lexer,
				})
			end)
		)
		table.insert(
			connections,
			textObject:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				Highlighter.highlight({
					textObject = textObject,
					lexer = lexer,
				})
			end)
		)
	end

	return cleanup
end

function Highlighter.setTokenColors(colors: HighlighterColors)
	for token, color in colors do
		TokenColors[token] = color
		ColorFormatter[color] = string.format(
			'<font color="#%.2x%.2x%.2x">',
			color.R * 255,
			color.G * 255,
			color.B * 255
		) .. "%s</font>"
	end

	Highlighter.refresh()
end
Highlighter.setTokenColors(TokenColors)

return Highlighter :: Highlighter
