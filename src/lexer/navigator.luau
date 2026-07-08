--!strict

--[[
	A token navigator supporting non-sequential reads over a source, caching
	scanned tokens so earlier ones can be revisited. The lexer's scan function
	arrives through Navigator.new, which keeps this module from requiring its
	parent and forming a cycle. When the scan function reports restart
	snapshots, HotswapSource keeps every cached token the edit provably left
	untouched and resumes scanning from there instead of re-lexing everything.
]]

-- The scanner state a resumed scan needs beyond its start position. The
-- depth comes from a restart snapshot and the previous token fields come
-- back out of the token cache.
export type ScanSeed = {
	depth: number,
	previous1: string,
	previous2: string,
	previous3: string,
	previousKind: string,
}

type ScanFunction = (src: string, startIndex: number?, seed: ScanSeed?) -> () -> (string?, string, number?, number?)

-- How many bytes the common prefix measurement compares at a time before
-- falling back to single bytes inside the first chunk that differs.
local PREFIX_CHUNK = 256

local Navigator = {}

--[[
	Measures the longest shared byte prefix of two strings. Whole chunks
	compare first so large untouched heads go quickly, then the first chunk
	that differs walks byte by byte to the exact split point.
]]
local function commonPrefixLength(a: string, b: string): number
	local limit = math.min(#a, #b)
	local matched = 0
	while
		matched + PREFIX_CHUNK <= limit
		and string.sub(a, matched + 1, matched + PREFIX_CHUNK) == string.sub(b, matched + 1, matched + PREFIX_CHUNK)
	do
		matched += PREFIX_CHUNK
	end
	while matched < limit and string.byte(a, matched + 1) == string.byte(b, matched + 1) do
		matched += 1
	end
	return matched
end

--[[
	Builds a navigator that reads tokens through the given scan function.
]]
function Navigator.new(scan: ScanFunction)
	local nav = {
		Source = "",
		TokenCache = table.create(50) :: { { string } },

		realIndex = 0,
		userIndex = 0,
		scanThread = nil :: thread?,

		-- Restart bookkeeping, parallel to TokenCache. endOffsets holds each
		-- token's cumulative byte length, so endOffsets[k] + 1 is where the
		-- token after k starts. restartDepths holds the bracket depth right
		-- after a token when the scan can safely resume there and false when
		-- it cannot, and restartWatermarks holds the furthest byte the scan
		-- had read by that point, lookahead included.
		endOffsets = table.create(50) :: { number },
		restartDepths = table.create(50) :: { number | false },
		restartWatermarks = table.create(50) :: { number },
	}

	--[[
		Builds the coroutine that pulls tokens from a scan of the current
		source and appends them, with their restart bookkeeping, onto the
		cache. A scan function that never reports snapshots just fills the
		cache with no restart points, which makes hotswapping fall back to a
		full rescan.
	]]
	local function buildScanThread(startIndex: number?, seed: ScanSeed?): thread
		return coroutine.create(function()
			for token, content, restartDepth, watermark in scan(nav.Source, startIndex, seed) do
				local tokenIndex = nav.realIndex + 1
				nav.realIndex = tokenIndex
				nav.TokenCache[tokenIndex] = { token, content }
				nav.endOffsets[tokenIndex] = (nav.endOffsets[tokenIndex - 1] or 0) + #content
				if restartDepth ~= nil and watermark ~= nil then
					nav.restartDepths[tokenIndex] = restartDepth
					nav.restartWatermarks[tokenIndex] = watermark
				else
					nav.restartDepths[tokenIndex] = false
					nav.restartWatermarks[tokenIndex] = 0
				end
				coroutine.yield(token, content)
			end
		end)
	end

	function nav:Destroy()
		self.Source = nil
		self.realIndex = nil
		self.userIndex = nil
		self.TokenCache = nil
		self.scanThread = nil
		self.endOffsets = nil
		self.restartDepths = nil
		self.restartWatermarks = nil
	end

	-- Every method except Destroy closes over nav instead of reading through
	-- self because the new solver types self generically there, which blocks
	-- compound assignment, widens the token cache, and rejects internal calls
	-- between methods. The ignored parameter keeps them callable as methods
	-- alongside the rest.
	function nav.SetSource(_self: any, sourceString: string)
		nav.Source = sourceString

		nav.realIndex = 0
		nav.userIndex = 0
		table.clear(nav.TokenCache)
		table.clear(nav.endOffsets)
		table.clear(nav.restartDepths)
		table.clear(nav.restartWatermarks)

		nav.scanThread = buildScanThread(nil, nil)
	end

	function nav.HotswapSource(_self: any, sourceString: string)
		if sourceString == nav.Source then
			nav.userIndex = 0
			return
		end

		-- A cached token stays valid for the new source when everything the
		-- scanner read to produce it, lookahead included, lies inside the
		-- shared prefix. The scan resumes right after the latest such token
		-- that also carries a restart snapshot, since tokens without one
		-- ended somewhere the scanner state cannot be rebuilt, like inside
		-- a type context or an open interpolation hole.
		local sharedPrefix = commonPrefixLength(nav.Source, sourceString)
		local restartToken = 0
		local candidate = nav.realIndex
		while candidate > 0 do
			if nav.restartDepths[candidate] ~= false and nav.restartWatermarks[candidate] <= sharedPrefix then
				restartToken = candidate
				break
			end
			candidate -= 1
		end

		if restartToken == 0 then
			nav:SetSource(sourceString)
			return
		end

		for stale = nav.realIndex, restartToken + 1, -1 do
			nav.TokenCache[stale] = nil
			nav.endOffsets[stale] = nil
			nav.restartDepths[stale] = nil
			nav.restartWatermarks[stale] = nil
		end
		nav.realIndex = restartToken
		nav.userIndex = 0
		nav.Source = sourceString

		local cache = nav.TokenCache
		local restartEntry = cache[restartToken]
		local previousEntry = cache[restartToken - 1]
		local secondPreviousEntry = cache[restartToken - 2]
		local seed: ScanSeed = {
			depth = nav.restartDepths[restartToken] :: number,
			previousKind = restartEntry[1],
			previous1 = restartEntry[2],
			previous2 = if previousEntry ~= nil then previousEntry[2] else "",
			previous3 = if secondPreviousEntry ~= nil then secondPreviousEntry[2] else "",
		}
		nav.scanThread = buildScanThread(nav.endOffsets[restartToken] + 1, seed)
	end

	function nav.Next(_self: any): ...string?
		nav.userIndex += 1

		if nav.realIndex >= nav.userIndex then
			-- The entry indexes explicitly rather than unpacking so restart
			-- bookkeeping can never leak extra return values to callers.
			local entry = nav.TokenCache[nav.userIndex]
			return entry[1], entry[2]
		else
			local scanThread = nav.scanThread
			if scanThread == nil or coroutine.status(scanThread) == "dead" then
				return
			else
				local success, token, content = coroutine.resume(scanThread)
				if success and token then
					return token, content
				else
					return
				end
			end
		end
	end

	function nav.Peek(_self: any, peekAmount: number): ...string?
		local goalIndex = nav.userIndex + peekAmount

		if nav.realIndex >= goalIndex then
			if goalIndex > 0 then
				local entry = nav.TokenCache[goalIndex]
				return entry[1], entry[2]
			else
				return
			end
		else
			local scanThread = nav.scanThread
			if scanThread == nil or coroutine.status(scanThread) == "dead" then
				return
			else
				local iterationsAway = goalIndex - nav.realIndex

				local success: boolean?, token: string?, content: string? = nil, nil, nil

				for _ = 1, iterationsAway do
					success, token, content = coroutine.resume(scanThread)
					if not (success and token) then
						-- The scan is exhausted, or resume failed and put its
						-- error message in the token slot, so the peek misses.
						token = nil
						content = nil
						break
					end
				end

				return token, content
			end
		end
	end

	return nav
end

return Navigator
