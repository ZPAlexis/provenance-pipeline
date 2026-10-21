#!/usr/bin/env bash
# Starts the MCP server for a client on Windows (the Inspector now, Claude Code in M5).
# Nothing but the server may write to stdout: it carries the protocol.
cd "$(dirname "$0")/.." || exit 1
eval "$(~/.local/bin/mise activate bash)" >/dev/null 2>&1
exec bundle exec ruby mcp/server.rb