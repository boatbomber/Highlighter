local Lexer = require(script.lexer)

local TokenColors = {}
local TokenFormats = {}
local ActiveLabels = {}
local LastText = {}
local Cleanups = {}

local function SanitizeRichText(s: string): string
	return string.gsub(string.gsub(string.gsub(string.gsub(string.gsub(s,
		"&", "&amp;"),
		"<", "&lt;"),
		">", "&gt;"),
		"\"", "&quot;"),
		"'", "&apos;"
	)
end

local function SanitizeTabs(s: string): string
	return string.gsub(s, "\t", "    ")
end

local function SanitizeControl(s: string): string
	return string.gsub(s, "[\0\1\2\3\4\5\6\7\8\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31]+", "")
end

local function highlight(textObject: Instance, src: string?)
	src = SanitizeTabs(SanitizeControl(src or textObject.Text))
	if LastText[textObject] == src then
		return
	end
	LastText[textObject] = src

	textObject.RichText = false
	textObject.Text = src
	textObject.TextXAlignment = Enum.TextXAlignment.Left
	textObject.TextYAlignment = Enum.TextYAlignment.Top
	textObject.BackgroundColor3 = TokenColors.background
	textObject.TextColor3 = TokenColors.iden
	textObject.TextTransparency = 0.5

	local lineFolder = textObject:FindFirstChild("SyntaxHighlights")
	if not lineFolder then
		lineFolder = Instance.new("Folder")
		lineFolder.Name = "SyntaxHighlights"
		lineFolder.Parent = textObject
	end

	local _, numLines = string.gsub(src, "\n", "")
	numLines += 1

	local textHeight = textObject.TextBounds.Y/numLines

	local lineLabels = ActiveLabels[textObject]
	if not lineLabels then
		-- No existing lineLabels, create all new
		lineLabels = table.create(numLines)
		for i = 1, numLines do
			local lineLabel = Instance.new("TextLabel")
			lineLabel.Name = "Line_" .. i
			lineLabel.RichText = true
			lineLabel.BackgroundTransparency = 1
			lineLabel.TextXAlignment = Enum.TextXAlignment.Left
			lineLabel.TextYAlignment = Enum.TextYAlignment.Top
			lineLabel.TextColor3 = TokenColors.iden
			lineLabel.Font = textObject.Font
			lineLabel.TextSize = textObject.TextSize
			lineLabel.Size = UDim2.new(1, 0, 0, math.ceil(textHeight))
			lineLabel.Position = UDim2.fromOffset(0, textHeight * (i - 1))
			lineLabel.Text = ""

			lineLabel.Parent = lineFolder
			lineLabels[i] = lineLabel
		end
	else
		for i=1, math.max(numLines, #lineLabels) do
			local label = lineLabels[i]
			if not label then
				label = Instance.new("TextLabel")
				label.Name = "Line_" .. i
				label.RichText = true
				label.BackgroundTransparency = 1
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.TextYAlignment = Enum.TextYAlignment.Top
				label.TextColor3 = TokenColors.iden
				label.Font = textObject.Font
				label.Parent = lineFolder
				lineLabels[i] = label
			end

			label.Text = ""
			label.TextSize = textObject.TextSize
			label.Size = UDim2.new(1, 0, 0, math.ceil(textHeight))
			label.Position = UDim2.fromOffset(0, textHeight * (i - 1))
		end
	end

	local richText, index, lineNumber = {}, 0, 1
	for token, content in Lexer.scan(src) do
		local Color = TokenColors[token] or TokenColors.iden

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
			if Color ~= TokenColors.iden and string.find(line, "[%S%C]") then
				richText[index] = string.format(TokenFormats[token], line)
			else
				richText[index] = line
			end
		end
	end

	-- Set final line
	lineLabels[lineNumber].Text = table.concat(richText)

	ActiveLabels[textObject] = lineLabels

	local cleanup = Cleanups[textObject]
	if not cleanup then
		local connection

		cleanup = function()
			for _, label in ipairs(lineLabels) do
				label:Destroy()
			end
			table.clear(lineLabels)

			ActiveLabels[textObject] = nil
			LastText[textObject] = nil
			Cleanups[textObject] = nil

			if connection then
				connection:Disconnect()
			end
		end
		Cleanups[textObject] = cleanup

		connection = textObject.AncestryChanged:Connect(function()
			if textObject.Parent then
				return
			end
			cleanup()
		end)
	end

	return cleanup
end

export type HighlighterColors = {
	background: Color3?,
	iden: Color3?,
	keyword: Color3?,
	builtin: Color3?,
	string: Color3?,
	number: Color3?,
	comment: Color3?,
	operator: Color3?
}

local function updateColors(colors: HighlighterColors?)
	-- Setup color data
	TokenColors.background = (colors and colors.background) or Color3.fromRGB(47, 47, 47)
	TokenColors.iden = (colors and colors.iden) or Color3.fromRGB(234, 234, 234)
	TokenColors.keyword = (colors and colors.keyword) or Color3.fromRGB(215, 174, 255)
	TokenColors.builtin = (colors and colors.builtin) or Color3.fromRGB(131, 206, 255)
	TokenColors.string = (colors and colors.string) or Color3.fromRGB(196, 255, 193)
	TokenColors.number = (colors and colors.number) or Color3.fromRGB(255, 125, 125)
	TokenColors.comment = (colors and colors.comment) or Color3.fromRGB(140, 140, 155)
	TokenColors.operator = (colors and colors.operator) or Color3.fromRGB(255, 239, 148)

	for key, color in pairs(TokenColors) do
		TokenFormats[key] = '<font color="#'
			.. string.format("%.2x%.2x%.2x", color.R * 255, color.G * 255, color.B * 255)
			.. '">%s</font>'
	end

	-- Rehighlight existing labels using latest colors
	for label, lineLabels in pairs(ActiveLabels) do
		for _, lineLabel in ipairs(lineLabels) do
			lineLabel.TextColor3 = TokenColors.iden
		end
		highlight(label)
	end
end
pcall(updateColors)

return setmetatable({
	UpdateColors = updateColors,
	Highlight = highlight
}, {
	__call = function(_, textObject: Instance, src: string?)
		return highlight(textObject, src)
	end
})