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
-- depth comes from a restart snapshot and the previous token contents come
-- back out of the token cache.
export type ScanSeed = {
	depth: number,
	previous1: string,
	previous2: string,
	previous3: string,
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
	Every method except Destroy closes over nav instead of reading through
	self because the new solver types self generically there, which blocks
	compound assignment, widens the token cache, and rejects internal calls
	between methods. The ignored parameter keeps them callable as methods
	alongside the rest.
]]
function Navigator.new(scan: ScanFunction)
	local nav = {
		source = "",

		realIndex = 0,
		userIndex = 0,
		scanThread = nil :: thread?,

		-- Token storage and restart bookkeeping live in parallel flat
		-- arrays so appending a token allocates no per token table and the
		-- cache stays cheap for the garbage collector to trace. tokenKinds
		-- and tokenContents hold each token's two halves. endOffsets holds
		-- each token's cumulative byte length, so endOffsets[k] + 1 is
		-- where the token after k starts. restartDepths holds the bracket
		-- depth right after a token and restartWatermarks the furthest byte
		-- the scan had read by that point, lookahead included. Tokens the
		-- scan cannot resume after store zero in both, and since a real
		-- watermark always covers at least the first token plus its peek
		-- slack, a zero watermark alone marks the absent snapshot.
		tokenKinds = table.create(50) :: { string },
		tokenContents = table.create(50) :: { string },
		endOffsets = table.create(50) :: { number },
		restartDepths = table.create(50) :: { number },
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
			for token, content, restartDepth, watermark in scan(nav.source, startIndex, seed) do
				local tokenIndex = nav.realIndex + 1
				nav.realIndex = tokenIndex
				nav.tokenKinds[tokenIndex] = token
				nav.tokenContents[tokenIndex] = content
				nav.endOffsets[tokenIndex] = (nav.endOffsets[tokenIndex - 1] or 0) + #content
				if restartDepth ~= nil and watermark ~= nil then
					nav.restartDepths[tokenIndex] = restartDepth
					nav.restartWatermarks[tokenIndex] = watermark
				else
					nav.restartDepths[tokenIndex] = 0
					nav.restartWatermarks[tokenIndex] = 0
				end
				coroutine.yield(token, content)
			end
		end)
	end

	--[[
		Resumes the scan until the cache reaches goalIndex or the scan runs
		out of tokens. A failed resume carries the scan's error, and it
		propagates rather than masquerading as a clean end of the stream and
		silently truncating whatever the caller is building.
	]]
	local function fillTo(goalIndex: number)
		local scanThread = nav.scanThread
		if scanThread == nil then
			return
		end
		while nav.realIndex < goalIndex and coroutine.status(scanThread) ~= "dead" do
			local success, message = coroutine.resume(scanThread)
			if not success then
				error(message, 0)
			end
		end
	end

	--[[
		Clears every field so a discarded navigator keeps nothing alive.
	]]
	function nav:Destroy()
		self.source = nil
		self.realIndex = nil
		self.userIndex = nil
		self.scanThread = nil
		self.tokenKinds = nil
		self.tokenContents = nil
		self.endOffsets = nil
		self.restartDepths = nil
		self.restartWatermarks = nil
	end

	--[[
		Points the navigator at a new source, dropping every cached token
		and starting a fresh scan from the beginning.
	]]
	function nav.SetSource(_self: any, sourceString: string)
		nav.source = sourceString

		nav.realIndex = 0
		nav.userIndex = 0
		table.clear(nav.tokenKinds)
		table.clear(nav.tokenContents)
		table.clear(nav.endOffsets)
		table.clear(nav.restartDepths)
		table.clear(nav.restartWatermarks)

		nav.scanThread = buildScanThread(nil, nil)
	end

	--[[
		Swaps in an edited source while keeping every cached token the edit
		provably left untouched, resuming the scan from the latest restart
		snapshot inside the shared prefix. Returns how many leading bytes of
		the new source the kept tokens cover, which is the prefix whose
		tokenization provably matches the previous source. An identical swap
		reports the whole source and the full rescan fallback reports zero.
	]]
	function nav.HotswapSource(_self: any, sourceString: string): number
		if sourceString == nav.source then
			nav.userIndex = 0
			return #sourceString
		end

		-- A cached token stays valid for the new source when everything the
		-- scanner read to produce it, lookahead included, lies inside the
		-- shared prefix. The scan resumes right after the latest such token
		-- that also carries a restart snapshot, since tokens without one
		-- ended somewhere the scanner state cannot be rebuilt, like inside
		-- a type context or an open interpolation hole.
		local sharedPrefix = commonPrefixLength(nav.source, sourceString)

		-- A token's watermark always reaches past its own bytes, so every
		-- token ending beyond the shared prefix is guaranteed to fail the
		-- check below. Binary searching the end offsets for the last token
		-- ending inside the prefix bounds the walk to candidates that can
		-- actually qualify, which keeps a head edit from walking the whole
		-- cache one token at a time.
		local low, high = 1, nav.realIndex
		local candidate = 0
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if nav.endOffsets[mid] <= sharedPrefix then
				candidate = mid
				low = mid + 1
			else
				high = mid - 1
			end
		end

		local restartToken = 0
		while candidate > 0 do
			-- A zero watermark marks a token with no snapshot, and it needs
			-- its own check because zero always sits inside the prefix.
			local watermark = nav.restartWatermarks[candidate]
			if watermark ~= 0 and watermark <= sharedPrefix then
				restartToken = candidate
				break
			end
			candidate -= 1
		end

		if restartToken == 0 then
			nav:SetSource(sourceString)
			return 0
		end

		for stale = nav.realIndex, restartToken + 1, -1 do
			nav.tokenKinds[stale] = nil
			nav.tokenContents[stale] = nil
			nav.endOffsets[stale] = nil
			nav.restartDepths[stale] = nil
			nav.restartWatermarks[stale] = nil
		end
		nav.realIndex = restartToken
		nav.userIndex = 0
		nav.source = sourceString

		local contents = nav.tokenContents
		local seed: ScanSeed = {
			depth = nav.restartDepths[restartToken],
			previous1 = contents[restartToken],
			previous2 = contents[restartToken - 1] or "",
			previous3 = contents[restartToken - 2] or "",
		}
		nav.scanThread = buildScanThread(nav.endOffsets[restartToken] + 1, seed)
		return nav.endOffsets[restartToken]
	end

	--[[
		Moves the read position so the next Next returns the token containing
		the given byte, and returns how many bytes of that token sit before
		the byte so the caller can trim them off the first read. The position
		must lie inside the scanned bytes or exactly one past them, where the
		next read simply resumes the scan. Peeks keep returning whole tokens,
		since the trim is the caller's to apply.
	]]
	function nav.SeekToByte(_self: any, position: number): number
		-- A binary search over the cumulative end offsets finds the last
		-- token that ends before the position.
		local low, high = 1, nav.realIndex
		local before = 0
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if nav.endOffsets[mid] < position then
				before = mid
				low = mid + 1
			else
				high = mid - 1
			end
		end
		nav.userIndex = before
		return position - 1 - (nav.endOffsets[before] or 0)
	end

	--[[
		Advances to the next token and returns it, reading from the cache
		when the position sits behind the scan.
	]]
	function nav.Next(_self: any): ...string?
		-- The position only advances when a token actually comes back, so
		-- reads past the end never drift where relative Peeks resolve.
		local goalIndex = nav.userIndex + 1
		if nav.realIndex < goalIndex then
			fillTo(goalIndex)
		end
		if nav.realIndex >= goalIndex then
			nav.userIndex = goalIndex
			return nav.tokenKinds[goalIndex], nav.tokenContents[goalIndex]
		end
		return
	end

	--[[
		Returns the token peekAmount away from the current position without
		moving it, scanning forward on demand. Peeks landing outside the
		token range return nothing.
	]]
	function nav.Peek(_self: any, peekAmount: number): ...string?
		local goalIndex = nav.userIndex + peekAmount
		if goalIndex <= 0 then
			return
		end
		if nav.realIndex < goalIndex then
			fillTo(goalIndex)
		end
		if nav.realIndex >= goalIndex then
			return nav.tokenKinds[goalIndex], nav.tokenContents[goalIndex]
		end
		return
	end

	return nav
end

return Navigator
