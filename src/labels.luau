--!strict

--[[
	Everything Instance-facing in the highlighter lives here. This module owns
	the per TextObject state, builds and positions the line labels, wires up
	the connections that keep highlights in sync, and tears it all down when a
	TextObject goes away.
]]

local types = require(script.Parent.types)
local Theme = require(script.Parent.theme)
local RichText = require(script.Parent.richtext)

local defaultLexer = require(script.Parent.lexer) :: types.Lexer

local textObjectData: { [types.TextObject]: types.ObjectData } = {}
local cleanups: { [types.TextObject]: () -> () } = {}

local Labels = {}

--[[
	Measures the text area of the given textObject with any UIPadding applied.
]]
local function getInnerAbsoluteSize(textObject: types.TextObject): Vector2
	local fullSize = textObject.AbsoluteSize

	local padding: UIPadding? = textObject:FindFirstChildWhichIsA("UIPadding")
	if padding then
		local offsetX = padding.PaddingLeft.Offset + padding.PaddingRight.Offset
		local scaleX = (fullSize.X * padding.PaddingLeft.Scale) + (fullSize.X * padding.PaddingRight.Scale)
		local offsetY = padding.PaddingTop.Offset + padding.PaddingBottom.Offset
		local scaleY = (fullSize.Y * padding.PaddingTop.Scale) + (fullSize.Y * padding.PaddingBottom.Scale)
		return Vector2.new(fullSize.X - (scaleX + offsetX), fullSize.Y - (scaleY + offsetY))
	else
		return fullSize
	end
end

--[[
	Grabs the text bounds of the given textObject. The engine computes bounds
	asynchronously, so they can briefly read as zero or NaN. Rather than
	yielding here, invalid bounds fall back to an estimate from TextSize, and
	the TextBounds property connection realigns the labels once the engine
	reports real values. Never yielding also keeps label population atomic, so
	rapid text changes cannot interleave their label writes.
]]
local function getTextBounds(textObject: types.TextObject, numLines: number): Vector2
	if textObject.ContentText == "" then
		return Vector2.zero
	end

	local textBounds = textObject.TextBounds
	if (textBounds.Y ~= textBounds.Y) or (textBounds.Y < 1) then
		return Vector2.new(0, textObject.TextSize * numLines)
	end
	return textBounds
end

--[[
	Gathers the info that is needed in order to set up a line label. The
	caller passes the textObject's data in, so this always succeeds.
]]
local function getLabelingInfo(textObject: types.TextObject, data: types.ObjectData): types.LabelingInfo
	-- One rich line builds per source line, so the cache length is the line
	-- count and the alignment path never rescans the source. Empty sources
	-- keep a floor of one line.
	local numLines = math.max(#data.RichLines, 1)

	local textBounds = getTextBounds(textObject, numLines)
	local textHeight = textBounds.Y / numLines

	return {
		textHeight = textHeight,
		innerAbsoluteSize = getInnerAbsoluteSize(textObject),
		textColor = Theme.getColor("iden"),
		textFont = textObject.FontFace,
		textSize = textObject.TextSize,
		labelSize = UDim2.new(1, 0, 0, math.ceil(textHeight)),
	}
end

--[[
	Computes a line label's position from the labeling info. A zero inner
	height would divide into NaN, so the labels pin to the top until the
	AbsoluteSize connection realigns them against a real size.
]]
local function getLabelPosition(labelingInfo: types.LabelingInfo, lineNumber: number): UDim2
	local innerHeight = labelingInfo.innerAbsoluteSize.Y
	if innerHeight <= 0 then
		return UDim2.fromScale(0, 0)
	end
	return UDim2.fromScale(0, labelingInfo.textHeight * (lineNumber - 1) / innerHeight)
end

--[[
	Sizes and positions the line labels against the textObject's geometry.
	Style properties stay untouched here because geometry events fire far
	more often than the font, size, or theme actually changes.
]]
local function alignLabels(textObject: types.TextObject)
	local data = textObjectData[textObject]
	if data == nil then
		return
	end

	local labelingInfo = getLabelingInfo(textObject, data)
	for lineNumber, lineLabel in data.Labels do
		lineLabel.Size = labelingInfo.labelSize
		lineLabel.Position = getLabelPosition(labelingInfo, lineNumber)
	end
end

--[[
	Matches the line labels' color, font, and text size to the textObject and
	the active theme. Label creation writes the same properties, so this only
	needs to run when the font or text size changes and when the theme
	refreshes.
]]
local function restyleLabels(textObject: types.TextObject)
	local data = textObjectData[textObject]
	if data == nil then
		return
	end

	local labelingInfo = getLabelingInfo(textObject, data)
	for _, lineLabel in data.Labels do
		lineLabel.TextColor3 = labelingInfo.textColor
		lineLabel.FontFace = labelingInfo.textFont
		lineLabel.TextSize = labelingInfo.textSize
	end
end

--[[
	Blanks every label from firstLine onward and drops its cached rich line,
	so the source can grow back into the labels later and a regrown line
	always rebuilds instead of trusting a stale cache entry. Labels that are
	already empty skip the write.
]]
local function blankLabelsFrom(data: types.ObjectData, firstLine: number)
	local lineLabels = data.Labels
	local richLines = data.RichLines
	for l = firstLine, #lineLabels do
		richLines[l] = nil
		if lineLabels[l].Text ~= "" then
			lineLabels[l].Text = ""
		end
	end
end

--[[
	Creates and populates the line labels with the appropriate rich text.
]]
local function populateLabels(props: types.HighlightProps)
	local textObject = props.textObject

	-- Untracked textObjects have nothing to populate.
	local data = textObjectData[textObject]
	if data == nil then
		return
	end

	local src = RichText.normalize(props.src or textObject.Text)
	local lexer = props.lexer or defaultLexer
	local customLang = props.customLang

	-- When nothing changed at all, the update skips entirely unless the
	-- caller forces one. Everything else rebuilds every line, and the per
	-- line cache below decides which labels actually need a write.
	local forceUpdate = props.forceUpdate == true or lexer ~= data.Lexer or customLang ~= data.CustomLang
	if data.Text == src and not forceUpdate then
		return
	end

	-- Luau cannot assign properties through a union of instance types, so writes
	-- go through this narrowed alias. TextBox shares every property written here.
	local writableTextObject = textObject :: TextLabel

	-- The textObject text always matches the normalized source.
	writableTextObject.Text = src

	local lineLabels = data.Labels
	local richLines = data.RichLines

	data.Text = src
	data.Lexer = lexer
	data.CustomLang = customLang

	-- Empty sources blank the existing labels and skip the lexer entirely.
	if src == "" then
		blankLabelsFrom(data, 1)
		return
	end

	-- The folder holding the line labels resolves once per populate rather
	-- than once per label. When something outside the highlighter deleted it,
	-- the old labels died with it and destroyed instances can never be
	-- reparented, so the caches clear and every label rebuilds into a fresh
	-- folder here.
	local lineFolder = textObject:FindFirstChild("SyntaxHighlights")
	if lineFolder == nil then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "SyntaxHighlights"
		newFolder.Parent = textObject
		lineFolder = newFolder
		table.clear(lineLabels)
		table.clear(richLines)
	end

	local labelingInfo = getLabelingInfo(textObject, data)

	--[[
		Grabs the label for the given line, building and positioning a new one
		when the line has never had a label before.
	]]
	local function getOrCreateLabel(lineNumber: number): TextLabel
		local lineLabel = lineLabels[lineNumber]
		if lineLabel then
			return lineLabel
		end

		local newLabel = Instance.new("TextLabel")
		newLabel.Name = "Line_" .. lineNumber
		newLabel.AutoLocalize = false
		newLabel.RichText = true
		newLabel.BackgroundTransparency = 1
		newLabel.Text = ""
		newLabel.TextXAlignment = Enum.TextXAlignment.Left
		newLabel.TextYAlignment = Enum.TextYAlignment.Top
		newLabel.TextColor3 = labelingInfo.textColor
		newLabel.FontFace = labelingInfo.textFont
		newLabel.TextSize = labelingInfo.textSize
		newLabel.Size = labelingInfo.labelSize
		newLabel.Position = getLabelPosition(labelingInfo, lineNumber)

		newLabel.Parent = lineFolder
		lineLabels[lineNumber] = newLabel
		return newLabel
	end

	local lastLine = RichText.buildLines({
		src = src,
		lexer = lexer,
		customLang = customLang,
		alwaysTagText = false,
		onLine = function(lineNumber: number, richText: string)
			-- Labels exist for every line, while text only writes when the
			-- built output differs from what the label already shows. The
			-- comparison is against built output rather than raw source
			-- lines because an edit on an earlier line can change a later
			-- line's tokens without touching its text. A forced update
			-- distrusts the labels entirely and writes every line, which is
			-- what lets refresh repair externally clobbered label text.
			local lineLabel = getOrCreateLabel(lineNumber)
			if forceUpdate or richLines[lineNumber] ~= richText then
				richLines[lineNumber] = richText
				lineLabel.Text = richText
			end
		end,
	})

	-- Labels beyond the last source line are emptied rather than destroyed,
	-- so they can be reused when the source grows again.
	blankLabelsFrom(data, lastLine + 1)
end

--[[
	Highlights the given textObject with the given props and returns a cleanup function.
	Highlighting will automatically update when needed, so the cleanup function will disconnect
	those connections and remove all labels.
]]
function Labels.highlight(props: types.HighlightProps): () -> ()
	local textObject = props.textObject

	-- A tracked textObject only needs its labels repopulated and realigned.
	if cleanups[textObject] then
		populateLabels(props)
		alignLabels(textObject)
		return cleanups[textObject]
	end

	local lexer = props.lexer or defaultLexer
	local customLang = props.customLang

	-- Luau cannot assign properties through a union of instance types, so writes
	-- go through this narrowed alias. TextBox shares every property written here.
	-- The normalized source itself writes inside populateLabels, which is the
	-- one place that computes it.
	local writableTextObject = textObject :: TextLabel
	writableTextObject.RichText = false
	writableTextObject.TextXAlignment = Enum.TextXAlignment.Left
	writableTextObject.TextYAlignment = Enum.TextYAlignment.Top
	writableTextObject.BackgroundColor3 = Theme.getColor("background")
	writableTextObject.TextColor3 = Theme.getColor("iden")
	writableTextObject.TextTransparency = 0.5

	local data: types.ObjectData = {
		Text = "",
		Labels = {},
		RichLines = {},
		Lexer = lexer,
		CustomLang = customLang,
	}
	textObjectData[textObject] = data

	-- The cleanup handler releases everything this highlight created. The
	-- label folder resolves here rather than capturing one, since populate
	-- rebuilds the folder whenever it goes missing.
	local connections: { [string]: RBXScriptConnection } = {}
	local function cleanup()
		local lineFolder = textObject:FindFirstChild("SyntaxHighlights")
		if lineFolder ~= nil then
			lineFolder:Destroy()
		end

		textObjectData[textObject] = nil
		cleanups[textObject] = nil

		for _key, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
	cleanups[textObject] = cleanup

	connections["AncestryChanged"] = textObject.AncestryChanged:Connect(function()
		if textObject.Parent then
			return
		end

		cleanup()
	end)
	connections["TextChanged"] = textObject:GetPropertyChangedSignal("Text"):Connect(function()
		-- The rebuild reads the live text with the latest stored lexer and
		-- customLang, so a src prop from the original call never pins text
		-- changes to a stale source.
		populateLabels({
			textObject = textObject,
			lexer = data.Lexer,
			customLang = data.CustomLang,
		})
	end)
	connections["TextBoundsChanged"] = textObject:GetPropertyChangedSignal("TextBounds"):Connect(function()
		alignLabels(textObject)
	end)
	connections["AbsoluteSizeChanged"] = textObject:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		alignLabels(textObject)
	end)
	-- A font or text size change restyles the labels and realigns them right
	-- away with whatever bounds the engine currently reports. The bounds
	-- recompute asynchronously, and their own connection realigns again once
	-- the real values arrive.
	connections["FontFaceChanged"] = textObject:GetPropertyChangedSignal("FontFace"):Connect(function()
		restyleLabels(textObject)
		alignLabels(textObject)
	end)
	connections["TextSizeChanged"] = textObject:GetPropertyChangedSignal("TextSize"):Connect(function()
		restyleLabels(textObject)
		alignLabels(textObject)
	end)

	populateLabels(props)
	alignLabels(textObject)

	return cleanup
end

--[[
	Refreshes all highlighted textObjects. Used when the theme changes.
]]
function Labels.refresh(): ()
	for textObject, data in textObjectData do
		-- The base object colors only write on the first highlight call, so
		-- a theme change reapplies them here. The write goes through a
		-- narrowed alias because Luau cannot assign through a union of
		-- instance types.
		local writableTextObject = textObject :: TextLabel
		writableTextObject.BackgroundColor3 = Theme.getColor("background")
		writableTextObject.TextColor3 = Theme.getColor("iden")

		-- Untagged label text renders in the label's own color, so a theme
		-- change has to restyle the labels too.
		restyleLabels(textObject)

		Labels.highlight({
			textObject = textObject,
			forceUpdate = true,
			src = data.Text,
			lexer = data.Lexer,
			customLang = data.CustomLang,
		})
	end
end

return Labels
