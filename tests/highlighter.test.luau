local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Highlighter = require(Packages:WaitForChild("Highlighter"))
local ThemeModule = require(Packages:WaitForChild("Highlighter"):WaitForChild("theme"))

-- The theme owns the canonical token name list, so the tests iterate it
-- rather than maintaining a copy that could drift.
local ALL_TOKEN_KINDS = ThemeModule.tokenNames

--[[
	Grabs the hex string for a token color so tests can look for it inside
	built rich text.
]]
local function hexFor(tokenName: string): string
	return Highlighter.getTokenColor(tokenName):ToHex()
end

--[[
	Removes font tags and unescapes rich text entities, giving back the plain
	text that a rich text line renders.
]]
local function stripRichText(line: string): string
	local text = string.gsub(line, '<font color="#%x+">', "")
	text = string.gsub(text, "</font>", "")
	text = string.gsub(text, "&lt;", "<")
	text = string.gsub(text, "&gt;", ">")
	text = string.gsub(text, "&quot;", '"')
	text = string.gsub(text, "&apos;", "'")
	text = string.gsub(text, "&amp;", "&")
	return text
end

--[[
	Takes a snapshot of every token color so tests that change colors can put
	them back afterward.
]]
local function saveColors(): { [string]: Color3 }
	local saved = {}
	for _, kind in ALL_TOKEN_KINDS do
		saved[kind] = Highlighter.getTokenColor(kind)
	end
	return saved
end

-- Sources with no tabs or control characters, so the plain text recovered
-- from their rich text lines must match them exactly.
local RECONSTRUCTION_SOURCES = {
	"local x: number? = nil",
	'local s = "say \\"hi\\"" .. `sum {math.max(1, 2)} done`',
	"local s = [[\nraw text\n]]\nprint(s)",
	"--[[ multi\nline\ncomment ]]\nlocal done = true",
	"local html = \"<b>bold & 'quoted'</b>\"",
	")(*&^ garbage $$ ## !!",
	'local emoji = "🍕" .. `{"🎲"}`',
	"",
	"\n",
	"a\n\nb",
}

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
		expect(string.find(lines[1], hexFor("keyword"), 1, true) ~= nil).toBe(true)
	end)

	it("colors type annotations with the type token color", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local x: number = 1",
		})
		expect(string.find(lines[1], hexFor("type"), 1, true) ~= nil).toBe(true)
	end)

	it("wraps identifiers in the iden color", function()
		local lines = Highlighter.buildRichTextLines({
			src = "identifier",
		})
		expect(lines[1]).toBe(`<font color="#{hexFor("iden")}">identifier</font>`)
	end)

	it("returns a single empty line for an empty source", function()
		local lines = Highlighter.buildRichTextLines({
			src = "",
		})
		expect(#lines).toBe(1)
		expect(lines[1]).toBe("")
	end)

	it("keeps a trailing newline as a final empty line", function()
		local lines = Highlighter.buildRichTextLines({
			src = "print(1)\n",
		})
		expect(#lines).toBe(2)
		expect(lines[2]).toBe("")
	end)

	it("keeps blank interior lines empty", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local a = 1\n\nlocal b = 2",
		})
		expect(#lines).toBe(3)
		expect(lines[2]).toBe("")
	end)

	it("escapes rich text markup in source text", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local s = \"<b>&</b>\" .. 'x'",
		})
		expect(string.find(lines[1], "<b>", 1, true)).toBe(nil)
		expect(string.find(lines[1], "&lt;b&gt;", 1, true) ~= nil).toBe(true)
		expect(string.find(lines[1], "&amp;", 1, true) ~= nil).toBe(true)
		expect(string.find(lines[1], "&quot;", 1, true) ~= nil).toBe(true)
		expect(string.find(lines[1], "&apos;", 1, true) ~= nil).toBe(true)
	end)

	it("converts tabs to four spaces", function()
		local lines = Highlighter.buildRichTextLines({
			src = "\tprint(1)",
		})
		expect(string.find(lines[1], "\t", 1, true)).toBe(nil)
		expect(stripRichText(lines[1])).toBe("    print(1)")
	end)

	it("strips control characters", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local a\7 = 1",
		})
		expect(stripRichText(lines[1])).toBe("local a = 1")
	end)

	it("treats CRLF line endings like LF", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local a = 1\r\nlocal b = 2",
		})
		expect(#lines).toBe(2)
		expect(stripRichText(lines[1])).toBe("local a = 1")
		expect(stripRichText(lines[2])).toBe("local b = 2")
	end)

	it("reconstructs the plain text of every source", function()
		for _, source in RECONSTRUCTION_SOURCES do
			local lines = Highlighter.buildRichTextLines({
				src = source,
			})
			local rebuilt = table.create(#lines)
			for lineNumber, line in lines do
				rebuilt[lineNumber] = stripRichText(line)
			end
			expect(table.concat(rebuilt, "\n")).toBe(source)
		end
	end)

	it("emits balanced font tags on every line", function()
		for _, source in RECONSTRUCTION_SOURCES do
			local lines = Highlighter.buildRichTextLines({
				src = source,
			})
			for _, line in lines do
				local _, openCount = string.gsub(line, "<font", "")
				local _, closeCount = string.gsub(line, "</font>", "")
				expect(openCount).toBe(closeCount)
			end
		end
	end)

	it("tags each line of a multiline token separately", function()
		local lines = Highlighter.buildRichTextLines({
			src = "local s = [[\nraw\n]]",
		})
		expect(#lines).toBe(3)
		expect(lines[2]).toBe(`<font color="#{hexFor("string")}">raw</font>`)
	end)

	it("colors customLang words with the custom color", function()
		local lines = Highlighter.buildRichTextLines({
			src = "myFunc(1)",
			customLang = { myFunc = "custom" },
		})
		expect(string.find(lines[1], hexFor("custom"), 1, true) ~= nil).toBe(true)
	end)

	it("colors customLang words even when whitespace merges into their token", function()
		-- The lexer folds trailing whitespace into token contents, so the word
		-- arrives as "myFunc\n" on line one and "myFunc " on line two.
		local lines = Highlighter.buildRichTextLines({
			src = "myFunc\nmyFunc (1)",
			customLang = { myFunc = "custom" },
		})
		expect(string.find(lines[1], hexFor("custom"), 1, true) ~= nil).toBe(true)
		expect(string.find(lines[2], hexFor("custom"), 1, true) ~= nil).toBe(true)
	end)

	it("uses the provided lexer", function()
		local stubLexer = {
			scan = function(src: string)
				local emitted = false
				return function()
					if emitted then
						return nil, ""
					end
					emitted = true
					return "comment", src
				end
			end,
			navigator = function()
				return nil
			end,
		}
		local lines = Highlighter.buildRichTextLines({
			src = "local x = 1",
			lexer = stubLexer,
		})
		expect(lines[1]).toBe(`<font color="#{hexFor("comment")}">local x = 1</font>`)
	end)
end)

describe("token colors", function()
	it("exposes the canonical token name list with a color for each", function()
		expect(#ThemeModule.tokenNames).toBe(10)
		-- The color map reads directly because getTokenColor falls back to
		-- iden, which would hide a missing entry.
		for _, kind in ThemeModule.tokenNames do
			expect(ThemeModule.tokenColors[kind]).toEqual(expect.any("Color3"))
		end
	end)

	it("defines a color for every token kind", function()
		for _, kind in ALL_TOKEN_KINDS do
			expect(Highlighter.getTokenColor(kind)).toEqual(expect.any("Color3"))
		end
	end)

	it("falls back to the identifier color for unknown token names", function()
		-- Custom lexers can emit kinds outside the built in set, and their
		-- color reads land here through the same widened string cast the rich
		-- text builder uses.
		local color = Highlighter.getTokenColor("unknownKind" :: any)
		expect(color).toEqual(Highlighter.getTokenColor("iden"))
	end)

	it("returns colors assigned through setTokenColors", function()
		local saved = saveColors()
		local newKeyword = Color3.fromRGB(255, 0, 0)

		Highlighter.setTokenColors({ keyword = newKeyword })
		local applied = Highlighter.getTokenColor("keyword")
		Highlighter.setTokenColors(saved)

		expect(applied).toEqual(newKeyword)
	end)

	it("merges given colors without touching the rest", function()
		local saved = saveColors()

		Highlighter.setTokenColors({ keyword = Color3.fromRGB(255, 0, 0) })
		local untouched = Highlighter.getTokenColor("iden")
		Highlighter.setTokenColors(saved)

		expect(untouched).toEqual(saved.iden)
	end)

	it("applies updated colors to newly built lines", function()
		local saved = saveColors()
		local newKeyword = Color3.fromRGB(1, 2, 3)

		Highlighter.setTokenColors({ keyword = newKeyword })
		local lines = Highlighter.buildRichTextLines({
			src = "local x = 1",
		})
		Highlighter.setTokenColors(saved)

		expect(string.find(lines[1], newKeyword:ToHex(), 1, true) ~= nil).toBe(true)
	end)
end)

describe("matchStudioSettings", function()
	it("runs without error and tolerates repeated calls", function()
		local saved = saveColors()

		expect(function()
			Highlighter.matchStudioSettings()
			Highlighter.matchStudioSettings()
		end).never.toThrow()

		Highlighter.setTokenColors(saved)
	end)
end)
