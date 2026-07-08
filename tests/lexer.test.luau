local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local lexer = require(Packages:WaitForChild("Highlighter"):WaitForChild("lexer"))

--[[
	Finds the "@@" caret marker in a snippet, removes it, scans the remaining
	source, and returns the kind and whitespace-trimmed text of the token that
	covers the marked character.
]]
local function tokenAt(snippet: string): (string?, string?)
	local markerStart = string.find(snippet, "@@", 1, true)
	assert(markerStart, "snippet has no @@ marker")
	local source = string.sub(snippet, 1, markerStart - 1) .. string.sub(snippet, markerStart + 2)
	local index = 1
	for kind, content in lexer.scan(source) do
		local finish = index + #content - 1
		if markerStart <= finish then
			return kind, string.match(content, "^%s*(.-)%s*$")
		end
		index = finish + 1
	end
	return nil, nil
end

--[[
	Grabs just the kind of the token that covers the "@@" marker.
]]
local function kindAt(snippet: string): string?
	local kind = tokenAt(snippet)
	return kind
end

--[[
	Rebuilds a source from its scanned token contents. Consumers position text
	by walking token lengths, so every character must be covered exactly once
	and in order.
]]
local function rebuild(source: string): string
	local parts = {}
	for _, content in lexer.scan(source) do
		table.insert(parts, content)
	end
	return table.concat(parts)
end

describe("keywords, identifiers, and builtins", function()
	it("classifies keywords", function()
		expect(kindAt("@@local x = 1")).toBe("keyword")
		expect(kindAt("while true do @@continue end")).toBe("keyword")
		expect(kindAt("@@export type T = number")).toBe("keyword")
		expect(kindAt("local t = @@typeof(x)")).toBe("keyword")
		expect(kindAt("function Foo:bar() return @@self end")).toBe("keyword")
	end)

	it("classifies identifiers", function()
		expect(kindAt("local @@x = 1")).toBe("iden")
	end)

	it("treats keyword prefixes as plain identifiers", function()
		expect(kindAt("@@localizer = 1")).toBe("iden")
		expect(kindAt("local @@truthy = 1")).toBe("iden")
		expect(kindAt("local @@ending = 1")).toBe("iden")
	end)

	it("classifies builtins", function()
		expect(kindAt("@@print(1)")).toBe("builtin")
		expect(kindAt("local ok = @@pcall(f)")).toBe("builtin")
		expect(kindAt("@@math.floor(1)")).toBe("builtin")
		expect(kindAt("math.@@floor(1)")).toBe("builtin")
	end)

	it("only counts library members indexed directly off their library", function()
		expect(kindAt("foo.@@floor(1)")).toBe("iden")
		expect(kindAt("a.b.@@max(1)")).toBe("iden")
		expect(kindAt("foo.math.@@floor(1)")).toBe("iden")
	end)

	it("knows the buffer and vector libraries", function()
		expect(kindAt("@@buffer.create(4)")).toBe("builtin")
		expect(kindAt("buffer.@@create(4)")).toBe("builtin")
		expect(kindAt("vector.@@create(1, 2, 3)")).toBe("builtin")
	end)
end)

describe("numbers", function()
	it("lexes every notation as a whole token", function()
		local cases = {
			"42",
			"3.14",
			".5",
			"1e-5",
			"1_000_000",
			"0xFF_AA",
			"0b1010",
		}
		for _, literal in cases do
			local kind, text = tokenAt("local n = @@" .. literal)
			expect(kind).toBe("number")
			expect(text).toBe(literal)
		end
	end)

	it("keeps a marker in the middle of a literal on the same token", function()
		expect(kindAt("local n = 3@@.14")).toBe("number")
	end)
end)

describe("quoted strings", function()
	it("keeps escaped quotes inside the string", function()
		local kind, text = tokenAt('local s = @@"say \\"hi\\"" .. x')
		expect(kind).toBe("string")
		expect(text).toBe('"say \\"hi\\""')

		kind, text = tokenAt("local s = @@'it\\'s fine'")
		expect(kind).toBe("string")
		expect(text).toBe("'it\\'s fine'")
	end)

	it("closes on an escaped backslash before the quote", function()
		expect(kindAt('local path = "C:\\\\" @@print(1)')).toBe("builtin")
	end)

	it("lexes the empty string", function()
		local kind, text = tokenAt('local s = @@"" .. x')
		expect(kind).toBe("string")
		expect(text).toBe('""')
	end)

	it("keeps comment lookalikes inside strings", function()
		expect(kindAt('local s = "a @@-- b"')).toBe("string")
	end)

	it("ends unfinished strings at their line so code resumes below", function()
		expect(kindAt('local s = @@"oops')).toBe("string")
		expect(kindAt('local s = "oops\n@@print(1)')).toBe("builtin")
	end)

	it("continues a literal across an escaped line break", function()
		expect(kindAt('local s = "line one\\\n@@still string"')).toBe("string")
	end)
end)

describe("multiline strings and comments", function()
	it("tracks bracket levels", function()
		local kind, text = tokenAt("local s = @@[[raw]]")
		expect(kind).toBe("string")
		expect(text).toBe("[[raw]]")

		expect(kindAt("local s = [=[ @@contains ]] still ]=]")).toBe("string")
		expect(kindAt("local s = [=[ x ]] y ]=] @@z = 1")).toBe("iden")
		expect(kindAt("local s = [=[ never closed\n@@code here")).toBe("string")
	end)

	it("lexes comments in every form", function()
		expect(kindAt("local x = 1 @@--[[ note ]]")).toBe("comment")
		expect(kindAt("--[==[ big\ncomment ]==] @@print(2)")).toBe("builtin")
		expect(kindAt("--[[ open\n@@anything")).toBe("comment")
		expect(kindAt("@@-- do the thing\nprint(1)")).toBe("comment")
		expect(kindAt("-- x\n@@print(1)")).toBe("builtin")
		expect(kindAt("@@--!strict\nlocal x = 1")).toBe("comment")
	end)
end)

describe("interpolated strings", function()
	it("lexes text as string and holes as code", function()
		expect(kindAt("local m = @@`plain`")).toBe("string")
		expect(kindAt("local m = `@@hi {name} bye`")).toBe("string")
		expect(kindAt("local m = `hi {@@name} bye`")).toBe("iden")
		expect(kindAt("local m = `hi {name} @@bye`")).toBe("string")
		expect(kindAt("local m = `sum {math.@@max(1, 2)}`")).toBe("builtin")
	end)

	it("balances nested braces inside holes", function()
		expect(kindAt("local m = `braces { {@@1, 2} } done`")).toBe("number")
		expect(kindAt("local m = `braces { {1, 2} } @@done`")).toBe("string")
	end)

	it("ignores quoted braces inside holes", function()
		expect(kindAt('local m = `x {("}")} @@y`')).toBe("string")
	end)

	it("treats escaped braces and backticks as text", function()
		expect(kindAt("local m = `no \\{@@hole} here`")).toBe("string")
		expect(kindAt("local m = `esc \\` @@tick`")).toBe("string")
	end)

	it("handles unfinished interpolated strings while typing", function()
		expect(kindAt("local m = @@`unfinished")).toBe("string")
		expect(kindAt("local m = `hi {@@count")).toBe("iden")
	end)
end)

describe("Luau type operators", function()
	it("lexes type syntax as operators", function()
		expect(kindAt("local x: number@@? = nil")).toBe("operator")
		expect(kindAt("local u: string @@| number")).toBe("operator")
		expect(kindAt("local i: A @@& B")).toBe("operator")
		expect(kindAt("local f: (number) @@-> string")).toBe("operator")
		expect(kindAt("local n = x @@:: number")).toBe("operator")
	end)

	it("lexes varargs and compound assignments as operators", function()
		expect(kindAt("local function f(@@...) end")).toBe("operator")
		expect(kindAt("count @@+= 1")).toBe("operator")
		expect(kindAt('s @@..= "x"')).toBe("operator")
		expect(kindAt("n @@//= 2")).toBe("operator")
		expect(kindAt("local q = a @@// b")).toBe("operator")
	end)

	it("lexes attributes as operators", function()
		-- The first @@ is the marker, leaving the attribute's @ marked.
		expect(kindAt("@@@native\nlocal function f() end")).toBe("operator")
	end)
end)

describe("type positions", function()
	it("lexes annotations as type tokens", function()
		expect(kindAt("local x: @@number = 1")).toBe("type")
		expect(kindAt('local s: @@string = ""')).toBe("type")
		expect(kindAt("local x: @@number? = nil")).toBe("type")
		expect(kindAt("local u: @@string | number")).toBe("type")
		expect(kindAt("local u: string | @@number")).toBe("type")
		expect(kindAt("local function f(a: @@number, b: string) end")).toBe("type")
		expect(kindAt("local function f(a: number, b: @@string) end")).toBe("type")
		expect(kindAt("local function f(): @@boolean end")).toBe("type")
		expect(kindAt("for i: @@number = 1, 3 do end")).toBe("type")
	end)

	it("stays in type context through generics, paths, and table types", function()
		expect(kindAt("local a: @@Array<number>")).toBe("type")
		expect(kindAt("local a: Array<@@number>")).toBe("type")
		expect(kindAt("local e: @@Enum.KeyCode")).toBe("type")
		expect(kindAt("local e: Enum.@@KeyCode")).toBe("type")
		expect(kindAt("local t: { x: @@number, y: string }")).toBe("type")
		expect(kindAt("local t: { x: number, y: @@string }")).toBe("type")
		expect(kindAt("local d: { [@@string]: number }")).toBe("type")
		expect(kindAt("local f: (@@number) -> string")).toBe("type")
		expect(kindAt("local f: (number) -> @@string")).toBe("type")
	end)

	it("treats casts and alias statements as type contexts", function()
		expect(kindAt("local n = x :: @@number")).toBe("type")
		expect(kindAt("type @@Vec = { x: number }")).toBe("type")
		expect(kindAt("type Vec = { x: @@number }")).toBe("type")
		expect(kindAt("export type @@Id = number")).toBe("type")
	end)

	it("suspends type context inside typeof", function()
		expect(kindAt("type T = @@typeof(game)")).toBe("keyword")
		expect(kindAt("type T = typeof(@@game)")).toBe("builtin")
	end)

	it("continues a union past a line break", function()
		expect(kindAt("local x: number |\n@@string")).toBe("type")
	end)
end)

describe("value positions", function()
	it("never types method accesses", function()
		expect(kindAt("obj:@@method(1)")).toBe("iden")
		expect(kindAt('obj:@@method "x"')).toBe("iden")
		expect(kindAt("obj:@@method {}")).toBe("iden")
		expect(kindAt("function Foo:@@bar() end")).toBe("iden")
		expect(kindAt("local t = { x = obj:@@m() }")).toBe("iden")
	end)

	it("never types comparisons", function()
		expect(kindAt("local ok = a < @@b")).toBe("iden")
	end)

	it("exits type context at the right boundaries", function()
		expect(kindAt("local x: number = @@foo")).toBe("iden")
		expect(kindAt("local z = (x :: any) + @@y")).toBe("iden")
		expect(kindAt("if b :: boolean then @@print(1) end")).toBe("builtin")
		expect(kindAt("local x: Foo\n@@print(1)")).toBe("builtin")
		expect(kindAt('local y: number = 1\nlocal z = @@string.rep("a", 2)')).toBe("builtin")
	end)
end)

describe("token stream coverage", function()
	it("reassembles every source exactly", function()
		local sources = {
			"local x: number? = nil",
			"local u: { [string]: number } | nil = {}",
			'local s = "say \\"hi\\"" .. "C:\\\\" .. `sum {math.max(1, 2)} done`',
			'local m = `braces { {1, 2} } and {("}")} tricky`',
			"local m = `unfinished {count",
			'local s = "oops\nprint(1)',
			"local s = [=[ never closed\ncode here",
			"--[[ open\nanything",
			"@native\nlocal function f<T>(a: {T}, ...: number): (T, ...string)\n\treturn a[1], ...\nend",
			"local café = 1 -- naïve comment 🚀",
			'local emoji = "🍕" .. `{"🎲"}`',
			")(*&^ garbage $$ ## !!",
			"type Point = { x: number, y: number }\nexport type Points = { Point }\nlocal p = point :: Point\nlocal d: { [string]: (Point) -> number } = {}",
		}
		for _, source in sources do
			expect(rebuild(source)).toBe(source)
		end
	end)
end)

describe("scan from a start index", function()
	it("covers the source from the given byte onward", function()
		local source = "local x = 1\nprint(x)"
		local startIndex = string.find(source, "print", 1, true)
		assert(startIndex, "sample lost its print call")

		local parts = {}
		for _, content in lexer.scan(source, startIndex) do
			table.insert(parts, content)
		end
		expect(table.concat(parts)).toBe(string.sub(source, startIndex))
	end)

	it("yields nothing when the start index is past the end", function()
		local kind, content = lexer.scan("abc", 10)()
		expect(kind).toBe(nil)
		expect(content).toBe("")
	end)
end)

describe("iterator contract", function()
	it("returns nil and an empty string once exhausted", function()
		local iterator = lexer.scan("local x = 1")
		local kind, content = iterator()
		while kind ~= nil do
			kind, content = iterator()
		end
		expect(content).toBe("")

		local kindAgain, contentAgain = iterator()
		expect(kindAgain).toBe(nil)
		expect(contentAgain).toBe("")
	end)

	it("returns nil and an empty string for an empty source", function()
		local kind, content = lexer.scan("")()
		expect(kind).toBe(nil)
		expect(content).toBe("")
	end)
end)

describe("navigator", function()
	it("iterates tokens with Next and Peek", function()
		local nav = lexer.navigator()
		nav:SetSource("local x = 1")

		local kind, content = nav:Next()
		expect(kind).toBe("keyword")
		expect(content).toBe("local ")

		local peekedKind = nav:Peek(1)
		expect(peekedKind).toBe("iden")

		kind, content = nav:Next()
		expect(kind).toBe("iden")
		expect(content).toBe("x ")
	end)

	it("peeks without advancing", function()
		local nav = lexer.navigator()
		nav:SetSource("local x = 1")

		local firstPeekKind, firstPeekContent = nav:Peek(1)
		local secondPeekKind, secondPeekContent = nav:Peek(1)
		expect(secondPeekKind).toBe(firstPeekKind)
		expect(secondPeekContent).toBe(firstPeekContent)

		local kind, content = nav:Next()
		expect(kind).toBe(firstPeekKind)
		expect(content).toBe(firstPeekContent)
	end)

	it("peeks multiple tokens ahead", function()
		local nav = lexer.navigator()
		nav:SetSource("local x = 1")

		local kind, content = nav:Peek(3)
		expect(kind).toBe("operator")
		expect(content).toBe("= ")
	end)

	it("peeks backward into already read tokens", function()
		local nav = lexer.navigator()
		nav:SetSource("local x = 1")
		nav:Next()
		nav:Next()

		local kind, content = nav:Peek(-1)
		expect(kind).toBe("keyword")
		expect(content).toBe("local ")
	end)

	it("returns nil when reading or peeking past the end", function()
		local nav = lexer.navigator()
		nav:SetSource("x")

		expect(nav:Peek(5)).toBe(nil)

		local kind = nav:Next()
		expect(kind).toBe("iden")
		expect(nav:Next()).toBe(nil)
		expect(nav:Next()).toBe(nil)
	end)

	it("resets its position when the source changes", function()
		local nav = lexer.navigator()
		nav:SetSource("local x = 1")
		while nav:Next() ~= nil do
		end

		nav:SetSource("print(1)")
		local kind, content = nav:Next()
		expect(kind).toBe("builtin")
		expect(content).toBe("print")
	end)

	it("destroys without error", function()
		local nav = lexer.navigator()
		nav:SetSource("local x = 1")
		nav:Next()

		expect(function()
			nav:Destroy()
		end).never.toThrow()
	end)

	it("hotswaps to a new source", function()
		local nav = lexer.navigator()
		nav:SetSource("local x = 1")
		nav:Next()
		nav:Next()

		nav:HotswapSource("local x = 2 -- changed")

		local parts = {}
		local kind, content = nav:Next()
		while kind ~= nil do
			table.insert(parts, content)
			kind, content = nav:Next()
		end
		expect(table.concat(parts)).toBe("local x = 2 -- changed")
	end)
end)

describe("language tables", function()
	it("exposes keywords, builtins, and libraries", function()
		expect(lexer.language).toBeDefined()
		expect(lexer.language.keyword["local"]).toBe("keyword")
		expect(lexer.language.builtin["print"]).toBe("function")
		expect(lexer.language.builtin["buffer"]).toBe("table")
		expect(lexer.language.builtin["vector"]).toBe("table")
		expect(lexer.language.libraries.math.floor).toBe("function")
		expect(lexer.language.libraries.string.rep).toBe("function")
		expect(lexer.language.libraries.vector.create).toBe("function")
	end)
end)
