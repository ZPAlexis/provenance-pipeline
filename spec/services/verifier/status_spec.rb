require "rails_helper"

RSpec.describe Verifier::Status do
  let(:company) { create(:company, :resolved, name: "Acme Robotics", domain: "acme.example") }

  describe ".find" do
    it "finds a company by id, by exact name in any case, or by a fragment only one company has" do
      create(:company, name: "Acme Labs")

      expect(described_class.find(company.id)).to eq(company)
      expect(described_class.find("acme robotics")).to eq(company)
      expect(described_class.find("Robot")).to eq(company)
      expect(described_class.find("Acme")).to be_nil # two companies have it
      expect(described_class.find(" ")).to be_nil
    end
  end

  describe ".lines" do
    it "shows the resolution, the latest checks, the postings and their verdicts, and the latest writes" do
      create(:page_check, company: company, url: company.careers_page_url, listing_count: 25, stated_total: 393,
                          listings_incomplete: true)
      create(:posting, :verified_live, company: company, role_title: "RevOps Engineer",
                                       enrichment: { "raw_verification" => "not_found" })
      AuditEvent.record!(actor: "agent:verifier", action: "update", target: company,
                         changes_made: { "resolution_status" => [ nil, "resolved" ] }, reasoning: "Found by path_probe.")

      text = described_class.lines(company).join("\n")

      expect(text).to include("Acme Robotics (acme.example)", "resolution: resolved, path_probe, high",
                              "watched page: #{company.careers_page_url}")
      expect(text).to include("ok, 25 listed of 393 [partial]")
      expect(text).to include("RevOps Engineer: verified_live", "(Clay said not_found)")
      expect(text).to include("agent:verifier update resolution_status", "Found by path_probe.")
      expect(text).to include("verifier:set_page[#{company.id}]")
    end

    it "offers confirm and reject for a candidate" do
      candidate = create(:company, :resolution_candidate)

      expect(described_class.lines(candidate).last).to include("verifier:confirm[#{candidate.id}]", "verifier:reject")
    end
  end
end
