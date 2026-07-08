#!/bin/sh
set -e

# If DevPackages aren't installed, install them.
if [ ! -d "DevPackages" ]; then
    wally install
fi
rojo build test.project.json --output HighlighterTest.rbxl
run-in-roblox --place HighlighterTest.rbxl --script scripts/run-benchmarks.server.luau
