--!strict

--[[
	A token navigator supporting non-sequential reads over a source, caching
	scanned tokens so earlier ones can be revisited. The lexer's scan function
	arrives through Navigator.new, which keeps this module from requiring its
	parent and forming a cycle.
]]

type ScanFunction = (src: string, startIndex: number?) -> () -> (string?, string)

local Navigator = {}

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
	}

	function nav:Destroy()
		self.Source = nil
		self.realIndex = nil
		self.userIndex = nil
		self.TokenCache = nil
		self.scanThread = nil
	end

	function nav:SetSource(sourceString)
		self.Source = sourceString

		self.realIndex = 0
		self.userIndex = 0
		table.clear(self.TokenCache)

		self.scanThread = coroutine.create(function()
			for token, content in scan(self.Source) do
				self.realIndex += 1
				self.TokenCache[self.realIndex] = { token, content }
				coroutine.yield(token, content)
			end
		end)
	end

	function nav:HotswapSource(sourceString)
		-- The scanner carries context across tokens (type mode, interpolation
		-- holes), so restarting mid-source could misclassify what follows.
		-- Hotswapping therefore re-lexes from the start. Tokens are only
		-- scanned as they are pulled, so the cost stays lazy.
		self:SetSource(sourceString)
	end

	-- Next and Peek close over nav instead of reading through self because
	-- the new solver types self generically there, which blocks the compound
	-- assignment and widens the token cache. The ignored parameter keeps them
	-- callable as methods alongside the rest.
	function nav.Next(_self: any)
		nav.userIndex += 1

		if nav.realIndex >= nav.userIndex then
			return table.unpack(nav.TokenCache[nav.userIndex])
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
				return table.unpack(nav.TokenCache[goalIndex])
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
					if not (success or token) then
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
