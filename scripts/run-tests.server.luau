-- run-in-roblox output does not render ANSI colors, so tell Jest's reporter
-- to print plain text.
-- selene: allow(global_usage)
_G.NOCOLOR = true

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local Jest = require(DevPackages:WaitForChild("Jest"))

local runCLIOptions = {
	verbose = true,
	ci = false,
}

local projects = {
	Packages:WaitForChild("Highlighter"),
}

Jest.runCLI(script, runCLIOptions, projects):await()

-- run-in-roblox can drop log output that is still queued when the place
-- closes, so give it a moment to drain before returning.
task.wait(2)

return nil
