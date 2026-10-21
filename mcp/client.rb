require "mcp"
require "json"

company = ARGV.fetch(0) { abort "Usage: bundle exec ruby mcp/client.rb <company name or domain>" }

server_script = File.expand_path("server.rb", __dir__)
transport = MCP::Client::Stdio.new(command: "bundle", args: ["exec", "ruby", server_script])
client = MCP::Client.new(transport: transport)

begin
  client.connect(mode: :modern)

  puts "=== Listing tools ==="
  tools = client.tools
  tools.each do |tool|
    puts "  Tool: #{tool.name} - #{tool.description}"
  end

  puts "\n=== Calling tool: get_company_status ==="
  tool = tools.find { |t| t.name == "get_company_status" }
  response = client.call_tool(tool: tool, arguments: { company: company })
  puts "  Response: #{JSON.pretty_generate(response.dig("result", "content"))}"
rescue => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
ensure
  transport.close
end