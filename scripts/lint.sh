#!/bin/sh
set -e

# The Roblox global type definitions are not checked in, so grab them from
# luau-lsp when missing. Analysis cannot resolve engine globals without them.
if [ ! -f ".vscode/globalTypes.PluginSecurity.d.luau" ]; then
    mkdir -p .vscode
    curl -fsSL -o .vscode/globalTypes.PluginSecurity.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.PluginSecurity.d.luau
fi

selene src
stylua --check src
luau-lsp analyze --sourcemap sourcemap.json --defs .vscode/globalTypes.PluginSecurity.d.luau --flag:LuauSolverV2=true src
luau-lsp analyze --sourcemap sourcemap.json --defs .vscode/globalTypes.PluginSecurity.d.luau src