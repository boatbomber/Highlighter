local Lexer = require(script.lexer)

local TokenColors = table.create(7)
local TokenFormats = table.create(7)
local ActiveLabels = table.create(3)

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

local function SanitizeUnicode(s: string): string
	local n = #s
	local NewString = table.create(n)

	local i = 0
	for Index = 1, n do
		local Byte = string.byte(s, Index)
		if (Byte >= 32 and Byte <= 126) or (Byte == 9 or Byte == 10) then
			i += 1
			NewString[i] = string.sub(s, Index, Index)
		end
	end

	return table.concat(NewString)
end

local function highlight(Label: Instance, Src: string?)
	Src = Src or Label.Text

	Label.TextColor3 = TokenColors.iden

	local RichText, Index = {}, 0
	for token, src in Lexer.scan(Src) do
		local Color = TokenColors[token] or TokenColors.iden
		local sanitized = SanitizeTabs(SanitizeRichText(SanitizeUnicode(src)))

		Index += 1
		if Color ~= Label.TextColor then
			RichText[Index] = string.format(TokenFormats[token], sanitized)
		else
			RichText[Index] = sanitized
		end
	end

	local Formatted = table.concat(RichText)
	if #Formatted <= 16300 then
		Label.Text = Formatted
	else
		Label.Text = SanitizeTabs(SanitizeRichText(SanitizeUnicode(Src)))
	end

	ActiveLabels[Label] = Src

	local Cleanup; Cleanup = Label.AncestryChanged:Connect(function()
		if Label.Parent then return end
		ActiveLabels[Label] = nil
		Cleanup:Disconnect()
	end)
end

local function updateColors()
	-- Setup color data
	TokenColors.background = Color3.fromRGB(47, 47, 47)
	TokenColors.iden = Color3.fromRGB(234, 234, 234)
	TokenColors.keyword = Color3.fromRGB(215, 174, 255)
	TokenColors.builtin = Color3.fromRGB(131, 206, 255)
	TokenColors.string = Color3.fromRGB(196, 255, 193)
	TokenColors.number = Color3.fromRGB(255, 125, 125)
	TokenColors.comment = Color3.fromRGB(140, 140, 155)
	TokenColors.operator = Color3.fromRGB(255, 239, 148)

	for key, color in pairs(TokenColors) do
		TokenFormats[key] = "<font color=\"#" .. string.format("%.2x%.2x%.2x", color.R*255,color.G*255,color.B*255) .. "\">%s</font>"
	end

	-- Rehighlight existing labels using latest colors
	for label, src in pairs(ActiveLabels) do
		highlight(label, src)
	end
end
pcall(updateColors)

return highlight
