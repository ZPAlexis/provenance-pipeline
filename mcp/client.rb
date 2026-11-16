# A smoke client for the MCP server, connecting over stdio as Claude Desktop does: lists the tools, then asks
# for one company's status. Usage: bundle exec ruby mcp/client.rb "<a company's name, domain, or a link on its site>"
require "mcp"

company = ARGV.fetch(0) { abort "Usage: bundle exec ruby mcp/client.rb <a company's name, domain, or a link on its site>" }
# The SDK starts the server with a clean environment (PATH, HOME, the gem paths): the environment and the database's
# address are handed over where set.
transport = MCP::Client::Stdio.new(command: "bundle", args: [ "exec", "ruby", File.expand_path("server.rb", __dir__) ],
                                   env: ENV.slice("RAILS_ENV", "DATABASE_URL"))
client = MCP::Client.new(transport: transport)

begin
  client.connect(mode: :modern)
  client.tools.each { |tool| puts "#{tool.name}: #{tool.description}" }
  response = client.call_tool(name: "get_company_status", arguments: { company: company })
  puts "\n#{response.dig('result', 'content', 0, 'text')}"
ensure
  transport.close
end
