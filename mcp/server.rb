# The MCP server (Stage 2d), over stdio: `bundle exec ruby mcp/server.rb`, or mcp/run.sh from a client on
# Windows. Its shared parts and rules are in provenance_mcp.rb; its tools, one per file, in mcp/tools/.

# stdout carries the protocol alone: the protocol keeps a handle of its own, and the process's stdout, which a worker
# the tools start (and anything it starts) inherits, goes to stderr (2f step 3: the client can start workers now).
protocol = $stdout.dup
$stdout.reopen($stderr)
$stdout = protocol

# Bundler and Bootsnap set up the load path first, in this thread: set up from the background boot while this
# thread is loading a file, the load path is caught half-built and a file that is there can't be found.
require_relative "../config/boot"
require_relative "provenance_mcp"

MCP.configure do |config|
  # stdout carries the protocol: what went wrong goes to stderr (the SDK's own reporter says nothing).
  config.exception_reporter = lambda do |exception, _server_context|
    warn "#{exception.class}: #{exception.message}#{" (#{exception.backtrace.first})" if exception.backtrace}"
  end
end

transport = MCP::Server::Transports::StdioTransport.new(ProvenanceMcp.server)
# Booting Rails from /mnt/m takes longer than a client's discovery probe waits: answer first, boot meanwhile.
ProvenanceMcp.boot_in_background(File.expand_path("../config/environment", __dir__))
transport.open
