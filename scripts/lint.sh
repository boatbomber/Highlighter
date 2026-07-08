#!/bin/sh
set -e

selene src
stylua --check src
luau-lsp analyze --sourcemap sourcemap.json --defs .vscode/globalTypes.PluginSecurity.d.luau --flag:LuauSolverV2=true src
luau-lsp analyze --sourcemap sourcemap.json --defs .vscode/globalTypes.PluginSecurity.d.luau src