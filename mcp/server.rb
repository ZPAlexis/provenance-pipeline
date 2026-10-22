require "mcp"

# Boot Rails in the background so the server answers the client at once; each tool call waits for it.
RAILS_BOOT = Thread.new { require_relative "../config/environment" }

MCP.configure do |config|
  config.exception_reporter = ->(exception, server_context) { warn "#{exception.class}: #{exception.message}" }
end

# Tool
class CompanyStatusTool < MCP::Tool
  tool_name "get_company_status"
  description "Given a company's exact name or domain (case-insensitive), this tool returns its resolution status and career page, its postings counted by verification state, and its most recent check time. Returns an error when nothing, or more than one company, matches."

  input_schema(
    properties: {company: { type: "string", description: "Company name or domain, e.g. acme.com" },},
    required: ["company"],
  )

  class << self
    def call(company:, server_context:)
      company_sql = <<~SQL
        SELECT id, name
        FROM companies
        WHERE LOWER(name) = LOWER($1)
        OR LOWER(domain) = LOWER($1)
      SQL

      status_sql = <<~SQL
        WITH posting_counts AS (
          SELECT c.id,
            COUNT(p.id) AS total_postings,
            COUNT(*) FILTER (WHERE p.verification_state = 'verified_live') AS total_verified_live,
            COUNT(*) FILTER (WHERE p.verification_state = 'not_found') AS total_not_found,
            COUNT(*) FILTER (WHERE p.verification_state = 'pending') AS total_pending,
            COUNT(*) FILTER (WHERE p.verification_state = 'inaccessible') AS total_inaccessible
          FROM companies c
          LEFT JOIN postings p
          ON c.id = p.company_id
          WHERE c.id = $1
          GROUP BY c.id
        ), last_check AS (
          SELECT company_id, checked_at
          FROM page_checks
          WHERE company_id = $1
          AND purpose = 'verification'
          ORDER BY checked_at DESC
          LIMIT 1
        )
        SELECT name,
          domain,
          resolution_status,
          resolution_method,
          resolution_confidence,
          COALESCE(careers_page_url, 'none') AS careers_page_url,
          total_postings,
          total_verified_live,
          total_not_found,
          total_pending,
          total_inaccessible,
          COALESCE(checked_at::text || ' UTC', 'never') AS last_checked
        FROM companies
        LEFT JOIN posting_counts
        ON posting_counts.id = companies.id
        LEFT JOIN last_check
        ON last_check.company_id = companies.id
        WHERE companies.id = $1
      SQL

      RAILS_BOOT.join

      ActiveRecord::Base.with_connection do |conn|
        conn.transaction do
          conn.execute("SET TRANSACTION READ ONLY")

          rows = conn.exec_query(company_sql, "matched_company", [company]).to_a

          if rows.empty?
            return MCP::Tool::Response.new([{ type: "text", text: "No company matches #{company.inspect}." }], error: true)
          end

          if rows.size > 1
            names = rows.map { |row| row["name"] }.join(", ")
            return MCP::Tool::Response.new([{ type: "text", text: "Several companies match: #{names}. Which one?" }], error: true)
          end

          company_id = rows.first["id"]

          company_row = conn.exec_query(status_sql, "company_status", [company_id]).to_a.first

          page_label = company_row["resolution_status"] == "resolved" ? "watched page" : "page on record (not watched)"

          MCP::Tool::Response.new([{
            type: "text",
            text: "Company status: #{company_row["resolution_status"]}, #{page_label}: #{company_row["careers_page_url"]}, postings: #{company_row["total_postings"]} (verified live: #{company_row["total_verified_live"]}, not found: #{company_row["total_not_found"]}, pending: #{company_row["total_pending"]}, inaccessible: #{company_row["total_inaccessible"]}), and most recent check time: #{company_row["last_checked"]}",
          }])
        end
      end
    end
  end
end

# Server
server = MCP::Server.new(
  name: "provenance_pipeline",
  version: "1.0.0",
  tools: [CompanyStatusTool],
)

# Transport
transport = MCP::Server::Transports::StdioTransport.new(server)
transport.open
