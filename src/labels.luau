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
		return Vector2.new(0, (textObject.TextSize * textObject.LineHeight) * numLines)
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
	Matches the line labels' font and text size to the textObject. Label
	creation writes the same properties, so this only needs to run when the
	font or text size changes, while theme refreshes recolor the labels in
	Labels.refresh instead.
]]
local function restyleLabels(textObject: types.TextObject)
	local data = textObjectData[textObject]
	if data == nil then
		return
	end

	local textFont = textObject.FontFace
	local textSize = textObject.TextSize
	for _, lineLabel in data.Labels do
		lineLabel.FontFace = textFont
		lineLabel.TextSize = textSize
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
	Builds a navigator from the lexer's factory when the result carries the
	full TokenNavigator contract populate resumes through. A factory whose
	navigator lacks any of the required methods yields nil instead, which
	keeps lexers built against a looser navigator shape rendering through
	the plain scanning path rather than crashing mid populate.
]]
local function buildNavigator(lexer: types.Lexer): types.TokenNavigator?
	local navigatorFactory = lexer.navigator
	if navigatorFactory == nil then
		return nil
	end
	local candidate: any = navigatorFactory()
	if
		type(candidate) ~= "table"
		or type(candidate.SetSource) ~= "function"
		or type(candidate.HotswapSource) ~= "function"
		or type(candidate.SeekToByte) ~= "function"
		or type(candidate.Next) ~= "function"
		or type(candidate.Destroy) ~= "function"
	then
		return nil
	end
	return candidate
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
	-- line cache below decides which labels actually need a write. The
	-- cached source only counts as unchanged while the Instance side still
	-- matches it, since a raw Text write can normalize back to the cached
	-- string and the label folder can be deleted out from under us. Empty
	-- sources deliberately have no folder, so they skip that check.
	local forceUpdate = props.forceUpdate == true or lexer ~= data.Lexer or customLang ~= data.CustomLang
	if data.Text == src and not forceUpdate and textObject.Text == src then
		if src == "" or textObject:FindFirstChild("SyntaxHighlights") ~= nil then
			return
		end
	end

	local lineLabels = data.Labels
	local richLines = data.RichLines

	-- Every cache updates before the Text write below, because under
	-- immediate signal behavior that write re-enters populate through the
	-- Text connection synchronously, and the nested call must find a fully
	-- updated cache so its early return fires instead of rebuilding the
	-- same lines a second time.
	data.Text = src

	-- The navigator's token cache belongs to the lexer that filled it, so a
	-- lexer change tears the navigator down and builds a fresh one from the
	-- new lexer's factory before anything reads stale tokens.
	if lexer ~= data.Lexer then
		if data.Navigator ~= nil then
			data.Navigator:Destroy()
		end
		data.Navigator = buildNavigator(lexer)
	end

	data.Lexer = lexer
	data.CustomLang = customLang

	-- Luau cannot assign properties through a union of instance types, so writes
	-- go through this narrowed alias. TextBox shares every property written here.
	local writableTextObject = textObject :: TextLabel

	-- The textObject text always matches the normalized source.
	writableTextObject.Text = src

	-- Empty sources blank the existing labels and skip the lexer entirely.
	-- The navigator resets too, since the blanked labels no longer reflect
	-- its cached tokens and a later edit must not skip lines on their word.
	if src == "" then
		if data.Navigator ~= nil then
			data.Navigator:SetSource("")
		end
		blankLabelsFrom(data, 1)
		return
	end

	-- Skipping clean line rebuilds is only sound while the existing labels
	-- are trusted, so force updates rebuild every line and a healed folder
	-- does too, since its labels start out blank.
	local canSkipLines = not forceUpdate

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
		canSkipLines = false
	end

	local labelingInfo = getLabelingInfo(textObject, data)

	-- A force update distrusts every cached line, and clearing the cache is
	-- what makes the diff below write each one. The clear sits after the
	-- labeling info read so the line count sizing new labels still reflects
	-- the previous build.
	if forceUpdate then
		table.clear(richLines)
	end

	--[[
		Grabs the label for the given line, building and positioning a new one
		when the line has never had a label before.
	]]
	local function getOrCreateLabel(lineNumber: number): TextLabel
		-- The cached label only counts while it still sits in the folder.
		-- Writes to a destroyed instance succeed silently, so without the
		-- liveness check a label deleted from outside would eat every future
		-- write for its line. The dead label's cached rich line clears too,
		-- so the replacement always receives the text it missed. The array's
		-- indexer claims every read succeeds, so the annotation widens the
		-- result back to optional for the check.
		local lineLabel: TextLabel? = lineLabels[lineNumber]
		if lineLabel ~= nil and lineLabel.Parent == lineFolder then
			return lineLabel
		end
		richLines[lineNumber] = nil

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

	-- Reading tokens through the navigator lets an edit reuse every cached
	-- token the scanner proves untouched, so a keystroke near the end of the
	-- source only pays to rescan and rebuild the tail lines. Hotswapping an
	-- unchanged source keeps the whole cache, which is what force updates
	-- from theme and customLang changes drain.
	local tokens, startLine = RichText.resumeTokens(data.Navigator, src, canSkipLines)

	local lastLine = RichText.buildLines({
		src = src,
		lexer = lexer,
		tokens = tokens,
		startLine = startLine,
		customLang = customLang,
		alwaysTagText = false,
		onLine = function(lineNumber: number, richText: string)
			-- Labels exist for every line, while text only writes when the
			-- built output differs from the cached rich line. The comparison
			-- is against built output rather than raw source lines because
			-- an edit on an earlier line can change a later line's tokens
			-- without touching its text. Force updates clear the cache up
			-- front, which makes this comparison write every line and is
			-- what lets refresh repair externally clobbered label text.
			local lineLabel = getOrCreateLabel(lineNumber)
			if richLines[lineNumber] ~= richText then
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

	-- The lexer starts nil so the first populate takes its lexer change
	-- branch, which is the one place navigators get built and torn down.
	local data: types.ObjectData = {
		Text = "",
		Labels = {},
		RichLines = {},
		Lexer = nil,
		CustomLang = props.customLang,
		Navigator = nil,
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

		-- The navigator reads back through data since populate rebuilds it
		-- whenever the lexer changes.
		if data.Navigator ~= nil then
			data.Navigator:Destroy()
			data.Navigator = nil
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
	local backgroundColor = Theme.getColor("background")
	local idenColor = Theme.getColor("iden")

	for textObject, data in textObjectData do
		-- The base object colors only write on the first highlight call, so
		-- a theme change reapplies them here, along with each label's own
		-- color since untagged text renders in it. The writes go through a
		-- narrowed alias because Luau cannot assign through a union of
		-- instance types. Geometry stays untouched because a color change
		-- cannot move it, which is why this calls populate directly rather
		-- than paying highlight's realignment pass.
		local writableTextObject = textObject :: TextLabel
		writableTextObject.BackgroundColor3 = backgroundColor
		writableTextObject.TextColor3 = idenColor
		for _, lineLabel in data.Labels do
			lineLabel.TextColor3 = idenColor
		end

		populateLabels({
			textObject = textObject,
			forceUpdate = true,
			src = data.Text,
			lexer = data.Lexer,
			customLang = data.CustomLang,
		})
	end
end

return Labels
