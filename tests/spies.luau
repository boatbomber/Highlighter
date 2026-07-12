--[[
	Scan spies shared by the test suites. Each spy records the byte where
	every scan begins, which lets a test tell a resumed scan from a full
	rescan without reading the navigator's internals.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Lexer = require(Packages:WaitForChild("Highlighter"):WaitForChild("lexer"))
local Navigator = require(Packages:WaitForChild("Highlighter"):WaitForChild("lexer"):WaitForChild("navigator"))

local Spies = {}

--[[
	Builds one navigator that appends each scan's start byte onto the given
	list before handing the scan off to the real scanner.
]]
local function spyNavigator(scanStarts: { number }): any
	return Navigator.new(function(src: string, startIndex: number?, seed: any)
		table.insert(scanStarts, startIndex or 1)
		return Lexer.scanRestartable(src, startIndex, seed)
	end)
end

--[[
	Builds a navigator whose scans record their start bytes, for tests that
	drive the navigator directly.
]]
function Spies.navigatorWithScanSpy(): (any, { number })
	local scanStarts: { number } = {}
	return spyNavigator(scanStarts), scanStarts
end

--[[
	Builds a lexer whose navigators record scan start bytes the same way, for
	tests that hand the spy to Highlighter.highlight. Every navigator the
	lexer builds appends onto the one returned list.
]]
function Spies.lexerWithScanSpy(): (any, { number })
	local scanStarts: { number } = {}
	local spyLexer = {
		scan = Lexer.scan,
		scanEach = Lexer.scanEach,
		navigator = function()
			return spyNavigator(scanStarts)
		end,
	}
	return spyLexer, scanStarts
end

return Spies
