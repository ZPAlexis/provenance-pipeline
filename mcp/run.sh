#!/usr/bin/env bash
# Starts the MCP server for a client on Windows, through WSL: `wsl.exe bash <repo>/mcp/run.sh`
# (Claude Desktop, Claude Code, or the MCP Inspector). Runs the code beside it, wherever the repo is.
# Nothing but the server may write to stdout: it carries the protocol.
cd "$(dirname "$0")/.." || exit 1
# Ruby comes from mise where it is installed that way; silenced, since stdout is the protocol's.
if [ -x "$HOME/.local/bin/mise" ]; then eval "$("$HOME/.local/bin/mise" activate bash)" >/dev/null 2>&1; fi
exec bundle exec ruby mcp/server.rb
