-- run-in-roblox output does not render ANSI colors, so tell Jest's reporter
-- to print plain text.
-- selene: allow(global_usage)
_G.NOCOLOR = true

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local Jest = require(DevPackages:WaitForChild("Jest"))

local runCLIOptions = {
	verbose = true,
	ci = false,
}

local projects = {
	ReplicatedStorage:WaitForChild("TestProject"),
}

local status, result = Jest.runCLI(script, runCLIOptions, projects):awaitStatus()

-- run-in-roblox can drop log output that is still queued when the place
-- closes, so give it a moment to drain before returning.
task.wait(2)

-- Jest resolves whether or not the tests passed, so failure has to be read
-- out of the run results. Erroring here is what makes run-in-roblox hand a
-- nonzero exit code back to scripts/test.sh.
if status ~= "Resolved" then
	error(`Jest did not complete: {tostring(result)}`)
end

local runResults = result.results
if runResults.numFailedTestSuites > 0 or runResults.numFailedTests > 0 then
	error(`{runResults.numFailedTests} failed tests across {runResults.numFailedTestSuites} failed suites`)
end

return nil
