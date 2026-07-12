local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Highlighter = require(Packages:WaitForChild("Highlighter"))
local Spies = require(script.Parent:WaitForChild("spies"))

local createdGuis: { ScreenGui } = {}

--[[
	Builds a TextLabel or TextBox inside a fresh ScreenGui under StarterGui so
	the engine computes real text bounds for it. The gui is tracked for
	teardown after each test.
]]
local function makeTextObject(text: string, className: string?)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HighlighterLabelsTest"

	local textObject = Instance.new(className or "TextLabel") :: TextLabel
	textObject.Size = UDim2.fromOffset(400, 300)
	textObject.TextSize = 16
	textObject.Text = text
	textObject.Parent = screenGui

	screenGui.Parent = StarterGui
	table.insert(createdGuis, screenGui)

	return textObject
end

--[[
	Collects the line labels under the given textObject keyed by line number.
]]
local function getLineLabels(textObject: Instance): { TextLabel }
	local folder = textObject:FindFirstChild("SyntaxHighlights")
	if folder == nil then
		return {}
	end

	local labels = {}
	for _, child in folder:GetChildren() do
		local lineNumber = tonumber(string.match(child.Name, "^Line_(%d+)$"))
		if lineNumber then
			labels[lineNumber] = child
		end
	end
	return labels
end

--[[
	Reports whether the given line's label exists and its rich text carries
	the given color as a hex string.
]]
local function lineHasColor(textObject: Instance, lineNumber: number, color: Color3): boolean
	local lineLabel = getLineLabels(textObject)[lineNumber]
	return lineLabel ~= nil and string.find(lineLabel.Text, color:ToHex(), 1, true) ~= nil
end

--[[
	Polls the given predicate until it returns true or the timeout passes,
	returning whether it ever succeeded.
]]
local function waitUntil(predicate: () -> boolean, timeout: number?): boolean
	local deadline = os.clock() + (timeout or 3)
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait()
	end
	return predicate()
end

afterEach(function()
	for _, screenGui in createdGuis do
		screenGui:Destroy()
	end
	table.clear(createdGuis)
end)

describe("highlight", function()
	it("creates one line label per source line", function()
		local textObject = makeTextObject("local a = 1\nlocal b = 2\nlocal c = 3")
		Highlighter.highlight({ textObject = textObject })

		local labels = getLineLabels(textObject)
		expect(#labels).toBe(3)
		expect(labels[1].Name).toBe("Line_1")
		expect(labels[3].Name).toBe("Line_3")
	end)

	it("configures line labels for rich text rendering", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		local lineLabel = getLineLabels(textObject)[1]
		expect(lineLabel.RichText).toBe(true)
		expect(lineLabel.BackgroundTransparency).toBe(1)
		expect(lineLabel.AutoLocalize).toBe(false)
		expect(lineLabel.TextXAlignment).toEqual(Enum.TextXAlignment.Left)
		expect(lineLabel.TextSize).toBe(textObject.TextSize)
	end)

	it("stacks line labels down the textObject", function()
		local textObject = makeTextObject("local a = 1\nlocal b = 2")
		Highlighter.highlight({ textObject = textObject })

		local labels = getLineLabels(textObject)
		expect(labels[1].Position.Y.Scale).toBe(0)
		expect(labels[2].Position.Y.Scale > 0).toBe(true)
		expect(labels[1].Size.X.Scale).toBe(1)
		expect(labels[1].Size.Y.Offset > 0).toBe(true)
	end)

	it("writes colored rich text into the line labels", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		expect(lineHasColor(textObject, 1, Highlighter.getTokenColor("keyword"))).toBe(true)
	end)

	it("leaves text in the default color untagged", function()
		local textObject = makeTextObject("identifier")
		Highlighter.highlight({ textObject = textObject })

		local lineLabel = getLineLabels(textObject)[1]
		expect(lineLabel.Text).toBe("identifier")
	end)

	it("normalizes tabs in the textObject text", function()
		local textObject = makeTextObject("a\tb")
		Highlighter.highlight({ textObject = textObject })

		expect(textObject.Text).toBe("a    b")
	end)

	it("prepares the textObject to sit behind the labels", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		expect(textObject.RichText).toBe(false)
		expect(textObject.TextTransparency).toBe(0.5)
		expect(textObject.BackgroundColor3).toEqual(Highlighter.getTokenColor("background"))
	end)

	it("uses the src prop over the current text", function()
		local textObject = makeTextObject("old text")
		Highlighter.highlight({ textObject = textObject, src = "print(1)" })

		expect(textObject.Text).toBe("print(1)")

		expect(lineHasColor(textObject, 1, Highlighter.getTokenColor("builtin"))).toBe(true)
	end)

	it("clears the displayed text when first highlighted with an empty source", function()
		local textObject = makeTextObject("print(1)")
		Highlighter.highlight({ textObject = textObject, src = "" })

		expect(textObject.Text).toBe("")
		expect(#getLineLabels(textObject)).toBe(0)
	end)

	it("highlights TextBoxes", function()
		local textObject = makeTextObject("local x = 1", "TextBox")
		Highlighter.highlight({ textObject = textObject })

		expect(lineHasColor(textObject, 1, Highlighter.getTokenColor("keyword"))).toBe(true)
	end)

	it("returns the existing cleanup when highlighting twice", function()
		local textObject = makeTextObject("local x = 1")
		local firstCleanup = Highlighter.highlight({ textObject = textObject })
		local secondCleanup = Highlighter.highlight({ textObject = textObject })

		expect(secondCleanup).toBe(firstCleanup)

		local folderCount = 0
		for _, child in textObject:GetChildren() do
			if child.Name == "SyntaxHighlights" then
				folderCount += 1
			end
		end
		expect(folderCount).toBe(1)
	end)
end)

describe("automatic updates", function()
	it("rebuilds labels when the text changes", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		textObject.Text = "print(1)"

		local updated = waitUntil(function()
			return lineHasColor(textObject, 1, Highlighter.getTokenColor("builtin"))
		end)
		expect(updated).toBe(true)
	end)

	it("recolors unchanged lines when an earlier edit changes their context", function()
		local textObject = makeTextObject("local a = 1\nprint(2)")
		Highlighter.highlight({ textObject = textObject })

		-- Opening a block comment on line 1 leaves line 2's text identical
		-- while changing every token on it.
		textObject.Text = "--[[ a = 1\nprint(2)"

		local updated = waitUntil(function()
			return lineHasColor(textObject, 2, Highlighter.getTokenColor("comment"))
		end)
		expect(updated).toBe(true)
	end)

	it("creates labels for added lines", function()
		local textObject = makeTextObject("local a = 1")
		Highlighter.highlight({ textObject = textObject })

		textObject.Text = "local a = 1\nlocal b = 2\nlocal c = 3"

		local grown = waitUntil(function()
			return getLineLabels(textObject)[3] ~= nil
		end)
		expect(grown).toBe(true)
	end)

	it("blanks trailing labels for reuse instead of destroying them", function()
		local textObject = makeTextObject("local a = 1\nlocal b = 2\nlocal c = 3")
		Highlighter.highlight({ textObject = textObject })

		local thirdLabel = getLineLabels(textObject)[3]

		textObject.Text = "local a = 1"
		local blanked = waitUntil(function()
			return thirdLabel.Text == ""
		end)
		expect(blanked).toBe(true)
		expect(thirdLabel.Parent).never.toBe(nil)

		textObject.Text = "local a = 1\nlocal b = 2\nprint(3)"
		local refilled = waitUntil(function()
			return thirdLabel.Text ~= ""
		end)
		expect(refilled).toBe(true)
		expect(getLineLabels(textObject)[3]).toBe(thirdLabel)
	end)

	it("rebuilds from the current text after highlighting with a src prop", function()
		local textObject = makeTextObject("ignored")
		Highlighter.highlight({ textObject = textObject, src = "local x = 1" })

		textObject.Text = "print(1)"

		local updated = waitUntil(function()
			return lineHasColor(textObject, 1, Highlighter.getTokenColor("builtin"))
		end)
		expect(updated).toBe(true)
	end)

	it("applies a new customLang on a repeated highlight call", function()
		local textObject = makeTextObject("myFunc(1)")
		Highlighter.highlight({ textObject = textObject })

		local customColor = Highlighter.getTokenColor("custom")
		expect(lineHasColor(textObject, 1, customColor)).toBe(false)

		Highlighter.highlight({ textObject = textObject, customLang = { myFunc = "custom" } })

		expect(lineHasColor(textObject, 1, customColor)).toBe(true)
	end)

	it("applies textObject font and size changes to the labels", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		textObject.TextSize = 24
		local resized = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[1]
			return lineLabel ~= nil and lineLabel.TextSize == 24
		end)
		expect(resized).toBe(true)

		local newFont = Font.fromEnum(Enum.Font.Code)
		textObject.FontFace = newFont
		local refonted = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[1]
			return lineLabel ~= nil and lineLabel.FontFace == newFont
		end)
		expect(refonted).toBe(true)
	end)

	it("recreates the label folder when it goes missing", function()
		local textObject = makeTextObject("local x = 1")
		local cleanup = Highlighter.highlight({ textObject = textObject })

		-- Destroying the folder takes every label with it, and destroyed
		-- instances can never be reparented, so the highlighter has to
		-- rebuild from scratch on the next update.
		local folder = textObject:FindFirstChild("SyntaxHighlights") :: Instance
		folder:Destroy()

		textObject.Text = "print(1)"

		local healed = waitUntil(function()
			return lineHasColor(textObject, 1, Highlighter.getTokenColor("builtin"))
		end)
		expect(healed).toBe(true)

		-- Cleanup removes the recreated folder rather than the stale original.
		cleanup()
		expect(textObject:FindFirstChild("SyntaxHighlights")).toBe(nil)
	end)

	it("heals a missing folder on a repeated highlight call", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		-- Nothing about the text changes here, so the repeated call has to
		-- notice the missing folder on its own rather than ride a text diff.
		local folder = textObject:FindFirstChild("SyntaxHighlights") :: Instance
		folder:Destroy()

		Highlighter.highlight({ textObject = textObject })

		expect(lineHasColor(textObject, 1, Highlighter.getTokenColor("keyword"))).toBe(true)
	end)

	it("renormalizes text that collapses to the cached source", function()
		local textObject = makeTextObject("a    b")
		Highlighter.highlight({ textObject = textObject })

		-- The tab normalizes back to the cached four spaces, but the raw
		-- text on the object still has to be rewritten or it renders a
		-- literal tab under labels built for spaces.
		textObject.Text = "a\tb"

		local renormalized = waitUntil(function()
			return textObject.Text == "a    b"
		end)
		expect(renormalized).toBe(true)
	end)

	it("recreates an individually destroyed line label", function()
		local textObject = makeTextObject("local a = 1\nprint(1)\nreturn a")
		Highlighter.highlight({ textObject = textObject })

		-- An edit on the destroyed label's own line rebuilds that line, and
		-- the rebuild has to notice the dead label instead of writing into
		-- it silently.
		local secondLabel = getLineLabels(textObject)[2] :: Instance
		secondLabel:Destroy()
		textObject.Text = "local a = 1\nprint(2)\nreturn a"

		local healed = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[2]
			return lineLabel ~= nil and string.find(lineLabel.Text, ">2<", 1, true) ~= nil
		end)
		expect(healed).toBe(true)

		-- Refresh emits every line, so it repairs a dead label even when no
		-- edit touches its line.
		local firstLabel = getLineLabels(textObject)[1] :: Instance
		firstLabel:Destroy()
		Highlighter.refresh()

		local repaired = waitUntil(function()
			return lineHasColor(textObject, 1, Highlighter.getTokenColor("keyword"))
		end)
		expect(repaired).toBe(true)
	end)

	it("starts an empty source with no labels and fills in once text arrives", function()
		local textObject = makeTextObject("")
		Highlighter.highlight({ textObject = textObject })

		expect(#getLineLabels(textObject)).toBe(0)

		textObject.Text = "local x = 1"
		local appeared = waitUntil(function()
			return getLineLabels(textObject)[1] ~= nil
		end)
		expect(appeared).toBe(true)
	end)
end)

describe("incremental rescans", function()
	local HighlighterPackage = Packages:WaitForChild("Highlighter")
	local LexerModule = require(HighlighterPackage:WaitForChild("lexer"))
	local RichTextModule = require(HighlighterPackage:WaitForChild("richtext"))

	--[[
		Wraps RichText.sanitize to record every token content the builder
		passes through it for the duration of a callback, returning the list.
		buildLines reads sanitize through the module table on every call,
		which is what makes the spy visible, and the pcall puts the real
		function back even when the callback fails.
	]]
	local function recordSanitizedContents(callback: () -> ()): { string }
		local realSanitize = RichTextModule.sanitize
		local sanitized: { string } = {}
		RichTextModule.sanitize = function(text: string): string
			table.insert(sanitized, text)
			return realSanitize(text)
		end
		local ok, err = pcall(callback)
		RichTextModule.sanitize = realSanitize
		if not ok then
			error(err)
		end
		return sanitized
	end

	--[[
		Highlights oldSource, edits it to newSource, and asserts the
		incremental rebuild's labels match a second object highlighted from
		newSource through a lexer with no navigator factory, which keeps the
		full-rescan path and makes it the ground truth.
	]]
	local function expectMatchesFullRescan(oldSource: string, newSource: string)
		local textObject = makeTextObject(oldSource)
		Highlighter.highlight({ textObject = textObject })
		textObject.Text = newSource

		local reference = makeTextObject(newSource)
		Highlighter.highlight({
			textObject = reference,
			lexer = { scan = LexerModule.scan, scanEach = LexerModule.scanEach },
		})
		local referenceLabels = getLineLabels(reference)

		local matched = waitUntil(function()
			local labels = getLineLabels(textObject)
			for lineNumber, referenceLabel in referenceLabels do
				local lineLabel = labels[lineNumber]
				if lineLabel == nil or lineLabel.Text ~= referenceLabel.Text then
					return false
				end
			end
			return true
		end)
		expect(matched).toBe(true)
	end

	it("resumes the scan mid source when text is edited at the end", function()
		local body = "local a = 1\nlocal b = 2\nlocal c = 3\n"
		local textObject = makeTextObject(body .. "print(1)")
		local spyLexer, scanStarts = Spies.lexerWithScanSpy()
		Highlighter.highlight({ textObject = textObject, lexer = spyLexer })

		expect(#scanStarts).toBe(1)
		expect(scanStarts[1]).toBe(1)

		textObject.Text = body .. "print(2)"

		-- The changed digit sits alone between its font tags, so ">2<" only
		-- appears once the last line rebuilds from the new source.
		local updated = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[4]
			return lineLabel ~= nil and string.find(lineLabel.Text, ">2<", 1, true) ~= nil
		end)
		expect(updated).toBe(true)

		expect(#scanStarts).toBe(2)
		expect(scanStarts[2] > 1).toBe(true)
	end)

	it("drains cached tokens with no rescan when only customLang changes", function()
		local textObject = makeTextObject("myFunc(1)")
		local spyLexer, scanStarts = Spies.lexerWithScanSpy()
		Highlighter.highlight({ textObject = textObject, lexer = spyLexer })

		expect(#scanStarts).toBe(1)

		Highlighter.highlight({
			textObject = textObject,
			lexer = spyLexer,
			customLang = { myFunc = "custom" },
		})

		expect(lineHasColor(textObject, 1, Highlighter.getTokenColor("custom"))).toBe(true)
		expect(#scanStarts).toBe(1)
	end)

	it("falls back to a full scan for a navigator missing the resume contract", function()
		-- This navigator mirrors the shape the library shipped before the
		-- resume contract existed: HotswapSource returns nothing and there
		-- is no SeekToByte. A custom lexer carrying one must render through
		-- the plain scanning path instead of crashing.
		local oldShapeNavigator = {
			SetSource = function() end,
			HotswapSource = function() end,
			Next = function() end,
			Peek = function() end,
			Destroy = function() end,
		}
		local oldShapeLexer = {
			scan = LexerModule.scan,
			scanEach = LexerModule.scanEach,
			navigator = function()
				return oldShapeNavigator
			end,
		}
		local textObject = makeTextObject("local a = 1\nprint(1)")
		Highlighter.highlight({ textObject = textObject, lexer = oldShapeLexer })

		expect(lineHasColor(textObject, 1, Highlighter.getTokenColor("keyword"))).toBe(true)

		textObject.Text = "local a = 1\nprint(2)"
		local updated = waitUntil(function()
			local lastLabel = getLineLabels(textObject)[2]
			return lastLabel ~= nil and string.find(lastLabel.Text, ">2<", 1, true) ~= nil
		end)
		expect(updated).toBe(true)
	end)

	it("skips rebuilding lines the edit provably left alone", function()
		local body = "local alpha = 1\nlocal beta = 2\nlocal gamma = 3\n"
		local textObject = makeTextObject(body .. "print(1)")
		Highlighter.highlight({ textObject = textObject })

		local updated = false
		local sanitized = recordSanitizedContents(function()
			textObject.Text = body .. "print(2)"
			updated = waitUntil(function()
				local lineLabel = getLineLabels(textObject)[4]
				return lineLabel ~= nil and string.find(lineLabel.Text, ">2<", 1, true) ~= nil
			end)
		end)
		expect(updated).toBe(true)

		-- The rebuild reaches back at most into the edited line, so the
		-- early lines' contents never pass through the builder again.
		local sawEarlyLine = false
		for _, text in sanitized do
			if string.find(text, "alpha", 1, true) or string.find(text, "beta", 1, true) then
				sawEarlyLine = true
			end
		end
		expect(sawEarlyLine).toBe(false)
	end)

	it("recolors every line on refresh after a skipped rebuild", function()
		local savedKeyword = Highlighter.getTokenColor("keyword")
		local textObject = makeTextObject("local a = 1\nprint(1)")
		Highlighter.highlight({ textObject = textObject })

		-- The tail edit rebuilds only the last line, and the theme change
		-- afterward has to reach the skipped first line anyway.
		textObject.Text = "local a = 1\nprint(2)"
		local edited = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[2]
			return lineLabel ~= nil and string.find(lineLabel.Text, ">2<", 1, true) ~= nil
		end)
		expect(edited).toBe(true)

		local newColor = Color3.fromRGB(210, 20, 20)
		Highlighter.setTokenColors({ keyword = newColor })
		local recolored = waitUntil(function()
			return lineHasColor(textObject, 1, newColor)
		end)
		Highlighter.setTokenColors({ keyword = savedKeyword })
		expect(recolored).toBe(true)
	end)

	it("rebuilds skipped lines into a healed folder", function()
		local textObject = makeTextObject("local a = 1\nprint(1)")
		Highlighter.highlight({ textObject = textObject })

		local folder = textObject:FindFirstChild("SyntaxHighlights") :: Instance
		folder:Destroy()

		-- The tail edit alone would leave line one untouched, but the folder
		-- loss means every label has to rebuild from scratch.
		textObject.Text = "local a = 1\nprint(2)"

		local healed = waitUntil(function()
			return lineHasColor(textObject, 1, Highlighter.getTokenColor("keyword"))
		end)
		expect(healed).toBe(true)
	end)

	it("refills lines blanked by an empty source", function()
		local textObject = makeTextObject("local a = 1\nprint(1)")
		Highlighter.highlight({ textObject = textObject })

		local firstLabel = getLineLabels(textObject)[1]
		textObject.Text = ""
		local blanked = waitUntil(function()
			return firstLabel.Text == ""
		end)
		expect(blanked).toBe(true)

		-- Text sharing a prefix with the pre blank source must not let the
		-- navigator's stale cache vouch for labels that are now empty.
		textObject.Text = "local a = 1\nprint(3)"
		local refilled = waitUntil(function()
			return firstLabel.Text ~= ""
		end)
		expect(refilled).toBe(true)
	end)

	it("matches a full rescan when the dirty line starts inside a token", function()
		-- The long string's token carries the following line's indentation,
		-- so the edited line starts partway through a kept token and the
		-- rebuild has to trim the head off it.
		local head = "do\n    local a = [[one\ntwo]]\n"
		expectMatchesFullRescan(head .. "    print(1)\nend", head .. "    print(2)\nend")
	end)

	it("produces the same labels as a full rescan after an end edit", function()
		local oldSource = "local a = 1\nprint(`{a} items`)\nreturn a"
		expectMatchesFullRescan(oldSource, oldSource .. " + 1")
	end)
end)

describe("cleanup", function()
	it("removes labels and stops updating", function()
		local textObject = makeTextObject("local x = 1")
		local cleanup = Highlighter.highlight({ textObject = textObject })

		cleanup()
		expect(textObject:FindFirstChild("SyntaxHighlights")).toBe(nil)

		textObject.Text = "print(1)"
		task.wait()
		expect(textObject:FindFirstChild("SyntaxHighlights")).toBe(nil)
	end)

	it("cleans up when the textObject leaves the tree", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		textObject.Parent = nil

		local cleaned = waitUntil(function()
			return textObject:FindFirstChild("SyntaxHighlights") == nil
		end)
		expect(cleaned).toBe(true)
	end)

	it("releases tracking when an ancestor is destroyed", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		local screenGui = textObject.Parent :: Instance
		screenGui:Destroy()
		task.wait()

		-- Property writes still work on destroyed instances, so a leaked
		-- entry would let refresh overwrite this text with the stored
		-- source, while a released one leaves it alone.
		textObject.Text = "tampered"
		Highlighter.refresh()
		task.wait()
		expect(textObject.Text).toBe("tampered")
	end)
end)

describe("redundant work", function()
	local RichTextModule = require(Packages:WaitForChild("Highlighter"):WaitForChild("richtext"))

	--[[
		Wraps RichText.normalize with a counter for the duration of a callback
		and returns how many times it ran. The labels module reads normalize
		through the module table on every call, which is what makes the spy
		visible to it.
	]]
	local function countNormalizeCalls(callback: () -> ()): number
		local realNormalize = RichTextModule.normalize
		local calls = 0
		RichTextModule.normalize = function(src: string): string
			calls += 1
			return realNormalize(src)
		end
		local ok, err = pcall(callback)
		RichTextModule.normalize = realNormalize
		if not ok then
			error(err)
		end
		return calls
	end

	it("does not renormalize the source when only geometry changes", function()
		local textObject = makeTextObject("local x = 1\nprint(2)")
		Highlighter.highlight({ textObject = textObject })

		local calls = countNormalizeCalls(function()
			textObject.Size = UDim2.fromOffset(500, 400)
			task.wait()
			task.wait()
		end)
		expect(calls).toBe(0)
	end)

	it("normalizes once per repeated highlight call", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		local calls = countNormalizeCalls(function()
			Highlighter.highlight({ textObject = textObject })
		end)
		expect(calls).toBe(1)
	end)
end)

describe("refresh", function()
	it("rebuilds every tracked label when called directly", function()
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		local lineLabel = getLineLabels(textObject)[1]
		lineLabel.Text = "tampered"

		Highlighter.refresh()

		local rebuilt = waitUntil(function()
			return lineHasColor(textObject, 1, Highlighter.getTokenColor("keyword"))
		end)
		expect(rebuilt).toBe(true)
	end)

	it("applies new background and base text colors to the textObject", function()
		local savedBackground = Highlighter.getTokenColor("background")
		local savedIden = Highlighter.getTokenColor("iden")
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		local newBackground = Color3.fromRGB(1, 2, 3)
		local newIden = Color3.fromRGB(4, 5, 6)
		Highlighter.setTokenColors({ background = newBackground, iden = newIden })

		expect(textObject.BackgroundColor3:ToHex()).toBe(newBackground:ToHex())
		expect(textObject.TextColor3:ToHex()).toBe(newIden:ToHex())

		Highlighter.setTokenColors({ background = savedBackground, iden = savedIden })
	end)

	it("applies a new iden color to the labels themselves", function()
		local savedIden = Highlighter.getTokenColor("iden")
		local textObject = makeTextObject("identifier")
		Highlighter.highlight({ textObject = textObject })

		-- Untagged text renders in the label's own color, so the theme
		-- change has to reach TextColor3 and not just the font tags.
		local newIden = Color3.fromRGB(7, 8, 9)
		Highlighter.setTokenColors({ iden = newIden })

		local lineLabel = getLineLabels(textObject)[1]
		local recolored = waitUntil(function()
			return lineLabel.TextColor3:ToHex() == newIden:ToHex()
		end)
		Highlighter.setTokenColors({ iden = savedIden })
		expect(recolored).toBe(true)
	end)

	it("applies new token colors to existing labels", function()
		local savedKeyword = Highlighter.getTokenColor("keyword")
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		local newColor = Color3.fromRGB(200, 10, 10)
		Highlighter.setTokenColors({ keyword = newColor })

		local recolored = waitUntil(function()
			return lineHasColor(textObject, 1, newColor)
		end)
		Highlighter.setTokenColors({ keyword = savedKeyword })

		expect(recolored).toBe(true)
	end)
end)
