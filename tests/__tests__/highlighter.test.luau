local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Highlighter = require(Packages:WaitForChild("Highlighter"))

describe("buildRichTextLines", function()
	it("produces one rich text line per source line", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local x = 1\nprint(x)\n-- done",
		})
		expect(#lines).toBe(3)
	end)

	it("wraps keywords in font tags", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local x = 1",
		})
		local keywordHex = Highlighter.getTokenColor("keyword"):ToHex()
		expect(string.find(lines[1], keywordHex, 1, true) ~= nil).toBe(true)
	end)

	it("colors type annotations with the type token color", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local x: number = 1",
		})
		local typeHex = Highlighter.getTokenColor("type"):ToHex()
		expect(string.find(lines[1], typeHex, 1, true) ~= nil).toBe(true)
	end)

	it("wraps identifiers in the iden color", function()
		local lines = Highlighter.buildRichTextLines({
			src = "identifier",
		})
		local idenHex = Highlighter.getTokenColor("iden"):ToHex()
		expect(lines[1]).toBe(`<font color="#{idenHex}">identifier</font>`)
	end)
end)

describe("token colors", function()
	it("defines a color for every token kind", function()
		local tokenKinds = { "iden", "keyword", "builtin", "type", "string", "number", "comment", "operator" }
		for _, kind in tokenKinds do
			expect(Highlighter.getTokenColor(kind)).toEqual(expect.any("Color3"))
		end
	end)
end)
