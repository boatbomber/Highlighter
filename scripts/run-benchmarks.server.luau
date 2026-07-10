--[[
	Performance benchmarks for the highlighter, run through run-in-roblox by
	scripts/bench.sh against the same place the tests build. Each benchmark
	times a whole operation with os.clock across several runs and prints the
	best and mean, since the best run is the one least disturbed by the
	garbage collector and the scheduler.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local HighlighterModule = Packages:WaitForChild("Highlighter")
local Highlighter = require(HighlighterModule)
local RichText = require(HighlighterModule:WaitForChild("richtext"))
local Lexer = Highlighter.defaultLexer

local RUNS = 10

-- The sample chunk exercises a bit of everything the scanner handles, so a
-- source built from repeated copies of it approximates real module code.
local SAMPLE_CHUNK = [==[
--!strict
-- A sample chunk with strings, types, numbers, comments, and interpolation.
local Players = game:GetService("Players")

export type Entry = {
	name: string,
	score: number?,
	tags: { string },
}

local function scoreFor(entry: Entry): number
	local base = entry.score or 0
	local bonus = math.floor(base * 1.5) + 0xFF - 1_000
	return math.max(base, bonus)
end

local greeting = "hello \"world\"" .. 'and \'more\''
local message = `greeting {greeting} at {os.clock()}`
local block = [[raw
text]]
--[[ a long
comment ]]
local caster = (scoreFor :: any) :: (Entry) -> number
]==]

--[[
	Builds a benchmark source by repeating the sample chunk.
]]
local function buildSource(chunkCount: number): string
	return table.concat(table.create(chunkCount, SAMPLE_CHUNK), "\n")
end

--[[
	Drains a scan of the given source and returns how many tokens it produced.
]]
local function drainScan(source: string): number
	local count = 0
	for _ in Lexer.scan(source) do
		count += 1
	end
	return count
end

--[[
	Drains a navigator with Next and returns how many tokens it produced.
]]
local function drainNavigator(nav): number
	local count = 0
	while nav:Next() ~= nil do
		count += 1
	end
	return count
end

--[[
	Runs work RUNS times after two untimed warmups and returns the elapsed
	seconds of each run, sorted fastest first. The setup callback runs before
	every attempt outside the timed window, and whatever it returns is handed
	to work, which is how the hotswap benchmarks get a freshly scanned
	navigator without paying for it inside the measurement.
]]
local function measure(setup: () -> any, work: (any) -> ()): { number }
	for _ = 1, 2 do
		work(setup())
	end
	local times = table.create(RUNS)
	for runIndex = 1, RUNS do
		local state = setup()
		local startTime = os.clock()
		work(state)
		times[runIndex] = os.clock() - startTime
	end
	table.sort(times)
	return times
end

--[[
	Prints one benchmark's timings and returns the best run in seconds so
	callers can derive throughput and speedup figures from it.
]]
local function summarize(label: string, times: { number }): number
	local total = 0
	for _, elapsed in times do
		total += elapsed
	end
	local best = times[1]
	print(
		string.format(
			"%s: best %.2f ms, mean %.2f ms over %d runs",
			label,
			best * 1000,
			(total / #times) * 1000,
			#times
		)
	)
	return best
end

--[[
	Returns a setup callback producing a navigator that has fully scanned the
	given source, ready to be hotswapped.
]]
local function scannedNavigator(source: string): () -> any
	return function()
		local nav = Lexer.navigator()
		nav:SetSource(source)
		drainNavigator(nav)
		return nav
	end
end

--[[
	Stands in for a benchmark that needs nothing built before each run.
]]
local function noSetup(): any
	return nil
end

local source = buildSource(400)
local lineCount = select(2, string.gsub(source, "\n", "\n")) + 1
local tokenCount = drainScan(source)
print(string.format("Source under test: %d lines, %.1f KB, %d tokens", lineCount, #source / 1024, tokenCount))
print("")

local scanBest = summarize(
	"Lexer.scan full drain",
	measure(noSetup, function()
		drainScan(source)
	end)
)
print(
	string.format(
		"  reads %.1f MB per second, %.2f million tokens per second",
		#source / 1048576 / scanBest,
		tokenCount / scanBest / 1e6
	)
)

local scanEachBest = summarize(
	"Lexer.scanEach full walk",
	measure(noSetup, function()
		local count = 0
		Lexer.scanEach(source, function()
			count += 1
		end)
	end)
)
print(string.format("  %.1fx faster than draining the iterator", scanBest / scanEachBest))

summarize(
	"buildRichTextLines",
	measure(noSetup, function()
		Highlighter.buildRichTextLines({ src = source })
	end)
)

local tailOld = source .. "\nlocal tail = 1\n"
local tailNew = source .. "\nlocal tail = 2\n"

local fullRescanBest = summarize(
	"Navigator full rescan",
	measure(function()
		return Lexer.navigator()
	end, function(nav)
		nav:SetSource(tailNew)
		drainNavigator(nav)
	end)
)

local hotswapBest = summarize(
	"Navigator hotswap, tail edit",
	measure(scannedNavigator(tailOld), function(nav)
		nav:HotswapSource(tailNew)
		drainNavigator(nav)
	end)
)

-- One untimed probe shows how much of the cache the tail edit kept.
local probe = Lexer.navigator()
probe:SetSource(tailOld)
drainNavigator(probe)
local cachedTokens = probe.realIndex
probe:HotswapSource(tailNew)
print(string.format("  reused %d of %d cached tokens", probe.realIndex, cachedTokens))
print(string.format("  %.1fx faster than the full rescan", fullRescanBest / hotswapBest))

local headOld = "local head = 1\n" .. source
local headNew = "local head = 2\n" .. source

summarize(
	"Navigator hotswap, head edit",
	measure(scannedNavigator(headOld), function(nav)
		nav:HotswapSource(headNew)
		drainNavigator(nav)
	end)
)
print("  the edit lands before every restart point, so this measures the full rescan fallback")

--[[
	Discards built lines so the line building benchmarks measure only the
	token and string work.
]]
local function discardLine() end

local rescanBuildBest = summarize(
	"buildLines with a full rescan, tail edit",
	measure(noSetup, function()
		RichText.buildLines({
			src = tailNew,
			lexer = Lexer,
			alwaysTagText = false,
			onLine = discardLine,
		})
	end)
)

local hotswapBuildBest = summarize(
	"buildLines over a hotswapped navigator, tail edit",
	measure(scannedNavigator(tailOld), function(nav)
		nav:HotswapSource(tailNew)
		RichText.buildLines({
			src = tailNew,
			lexer = Lexer,
			tokens = function()
				return nav:Next()
			end,
			alwaysTagText = false,
			onLine = discardLine,
		})
	end)
)
print(string.format("  %.1fx faster than the full rescan build", rescanBuildBest / hotswapBuildBest))

local skipBuildBest = summarize(
	"buildLines skipping lines the hotswap kept, tail edit",
	measure(scannedNavigator(tailOld), function(nav)
		-- This mirrors label population's keystroke path, walking the
		-- newlines inside the reused bytes to find the first dirty line and
		-- building only from there.
		local reusedBytes = nav:HotswapSource(tailNew)
		local startLine = 1
		local buildFromByte = 1
		local newlineAt = string.find(tailNew, "\n", 1, true)
		while newlineAt ~= nil and newlineAt <= reusedBytes do
			startLine += 1
			buildFromByte = newlineAt + 1
			newlineAt = string.find(tailNew, "\n", newlineAt + 1, true)
		end
		local trimHead = nav:SeekToByte(buildFromByte)
		RichText.buildLines({
			src = tailNew,
			lexer = Lexer,
			tokens = function()
				local kind, content = nav:Next()
				if trimHead > 0 and kind ~= nil then
					content = string.sub(content, trimHead + 1)
					trimHead = 0
				end
				return kind, content
			end,
			startLine = startLine,
			alwaysTagText = false,
			onLine = discardLine,
		})
	end)
)
print(
	string.format(
		"  this is label population's per keystroke path, %.1fx faster than the full rescan build",
		rescanBuildBest / skipBuildBest
	)
)

-- run-in-roblox can drop log output that is still queued when the place
-- closes, so give it a moment to drain before returning.
task.wait(2)

return nil
