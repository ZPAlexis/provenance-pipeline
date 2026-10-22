# A smoke client for the MCP server, connecting over stdio as Claude Desktop does: lists the tools, then asks
# for one company's status. Usage: bundle exec ruby mcp/client.rb "<a company's name, domain, or a link on its site>"
require "mcp"

company = ARGV.fetch(0) { abort "Usage: bundle exec ruby mcp/client.rb <a company's name, domain, or a link on its site>" }
transport = MCP::Client::Stdio.new(command: "bundle", args: [ "exec", "ruby", File.expand_path("server.rb", __dir__) ])
client = MCP::Client.new(transport: transport)

begin
  client.connect(mode: :modern)
  client.tools.each { |tool| puts "#{tool.name}: #{tool.description}" }
  response = client.call_tool(name: "get_company_status", arguments: { company: company })
  puts "\n#{response.dig('result', 'content', 0, 'text')}"
ensure
  transport.close
end
