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

		local keywordHex = Highlighter.getTokenColor("keyword"):ToHex()
		local lineLabel = getLineLabels(textObject)[1]
		expect(string.find(lineLabel.Text, keywordHex, 1, true) ~= nil).toBe(true)
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

		local builtinHex = Highlighter.getTokenColor("builtin"):ToHex()
		local lineLabel = getLineLabels(textObject)[1]
		expect(string.find(lineLabel.Text, builtinHex, 1, true) ~= nil).toBe(true)
	end)

	it("highlights TextBoxes", function()
		local textObject = makeTextObject("local x = 1", "TextBox")
		Highlighter.highlight({ textObject = textObject })

		local keywordHex = Highlighter.getTokenColor("keyword"):ToHex()
		local lineLabel = getLineLabels(textObject)[1]
		expect(string.find(lineLabel.Text, keywordHex, 1, true) ~= nil).toBe(true)
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

		local builtinHex = Highlighter.getTokenColor("builtin"):ToHex()
		local updated = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[1]
			return lineLabel ~= nil and string.find(lineLabel.Text, builtinHex, 1, true) ~= nil
		end)
		expect(updated).toBe(true)
	end)

	it("recolors unchanged lines when an earlier edit changes their context", function()
		local textObject = makeTextObject("local a = 1\nprint(2)")
		Highlighter.highlight({ textObject = textObject })

		-- Opening a block comment on line 1 leaves line 2's text identical
		-- while changing every token on it.
		textObject.Text = "--[[ a = 1\nprint(2)"

		local commentHex = Highlighter.getTokenColor("comment"):ToHex()
		local updated = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[2]
			return lineLabel ~= nil and string.find(lineLabel.Text, commentHex, 1, true) ~= nil
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

		local builtinHex = Highlighter.getTokenColor("builtin"):ToHex()
		local updated = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[1]
			return lineLabel ~= nil and string.find(lineLabel.Text, builtinHex, 1, true) ~= nil
		end)
		expect(updated).toBe(true)
	end)

	it("applies a new customLang on a repeated highlight call", function()
		local textObject = makeTextObject("myFunc(1)")
		Highlighter.highlight({ textObject = textObject })

		local customHex = Highlighter.getTokenColor("custom"):ToHex()
		expect(string.find(getLineLabels(textObject)[1].Text, customHex, 1, true)).toBe(nil)

		Highlighter.highlight({ textObject = textObject, customLang = { myFunc = "custom" } })

		expect(string.find(getLineLabels(textObject)[1].Text, customHex, 1, true) ~= nil).toBe(true)
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

		local builtinHex = Highlighter.getTokenColor("builtin"):ToHex()
		local healed = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[1]
			return lineLabel ~= nil and string.find(lineLabel.Text, builtinHex, 1, true) ~= nil
		end)
		expect(healed).toBe(true)

		-- Cleanup removes the recreated folder rather than the stale original.
		cleanup()
		expect(textObject:FindFirstChild("SyntaxHighlights")).toBe(nil)
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

		local keywordHex = Highlighter.getTokenColor("keyword"):ToHex()
		local rebuilt = waitUntil(function()
			return string.find(lineLabel.Text, keywordHex, 1, true) ~= nil
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

	it("applies new token colors to existing labels", function()
		local savedKeyword = Highlighter.getTokenColor("keyword")
		local textObject = makeTextObject("local x = 1")
		Highlighter.highlight({ textObject = textObject })

		local newColor = Color3.fromRGB(200, 10, 10)
		Highlighter.setTokenColors({ keyword = newColor })

		local recolored = waitUntil(function()
			local lineLabel = getLineLabels(textObject)[1]
			return lineLabel ~= nil and string.find(lineLabel.Text, newColor:ToHex(), 1, true) ~= nil
		end)
		Highlighter.setTokenColors({ keyword = savedKeyword })

		expect(recolored).toBe(true)
	end)
end)
