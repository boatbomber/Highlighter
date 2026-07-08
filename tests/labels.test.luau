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
end)

describe("refresh", function()
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
