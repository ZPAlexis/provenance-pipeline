require "rails_helper"

RSpec.describe Verifier::Targets do
  let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let(:page) { company.careers_page_url }

  def read(url: page, at: 2.days.ago, **attributes)
    create(:page_check, company: company, purpose: "verification", step: nil, url: url, checked_at: at, **attributes)
  end

  def adopt_board(confirmed_at: 1.day.ago)
    company.update!(board_vendor: "greenhouse", board_token: "acme", board_overlap: 0.98,
                    board_evidence: "greenhouse/acme lists 98% of the roles.", board_confirmed_at: confirmed_at)
  end

  describe ".verify" do
    it "sends the watched page, its postings, and the latest read of each page to reuse" do
      posting = create(:posting, company: company, role_title: "RevOps Engineer")
      read(at: 5.days.ago, content_hash: "sha256:old")
      latest = read(at: 2.days.ago, content_hash: "sha256:new", next_page_url: "#{page}?page=2")
      second = read(url: "#{page}?page=2", at: 2.days.ago)

      target = described_class.verify(company)

      expect(target).to include(id: company.id, url: page, board: nil,
                                postings: [ { id: posting.id, title: "RevOps Engineer", location: nil } ])
      expect(target[:previous].pluck(:page_check_id)).to contain_exactly(latest.id, second.id)
      expect(target[:previous].find { |r| r[:page_check_id] == latest.id })
        .to include(content_hash: "sha256:new", next_page_url: "#{page}?page=2", listings: latest.listings)
    end

    it "sends only reads whose listings the LLM read, or that reused such a read" do
      read(read_via: "ats_api:greenhouse")
      read(outcome: "inaccessible", read_via: nil, listing_count: nil)
      reused = read(read_via: "reused", listings_read_at: 10.days.ago, at: 1.day.ago)

      previous = described_class.verify(company)[:previous]

      expect(previous.pluck(:page_check_id)).to eq([ reused.id ])
      # The 14-day valve runs on when the listings were last actually read, not on the reuse.
      expect(previous.first[:listings_read_at]).to eq(reused.listings_read_at.utc.iso8601)
    end

    it "takes a read made before reuse existed as read when it was checked" do
      legacy = read(at: Time.utc(2026, 10, 1, 12))

      expect(described_class.verify(company)[:previous].first[:listings_read_at]).to eq(legacy.checked_at.utc.iso8601)
    end

    it "sends the company's board while its finding is fresh, and none after" do
      adopt_board
      expect(described_class.verify(company)[:board]).to eq(vendor: "greenhouse", board: "acme")

      company.update!(board_confirmed_at: 31.days.ago)
      expect(described_class.verify(company)[:board]).to be_nil
    end
  end

  describe ".board" do
    it "sends the distinct roles every page of the latest LLM read showed" do
      read(at: 9.days.ago, run_id: "old", listings: [ { "title" => "Gone Role" } ])
      read(run_id: "latest", listings: [ { "title" => "Account Executive" }, { "title" => "Data Engineer" } ])
      read(url: "#{page}?page=2", run_id: "latest", listings: [ { "title" => "Data Engineer" }, { "title" => "Recruiter" } ])

      expect(described_class.board(company)).to eq(
        id: company.id, name: "Acme", domain: "acme.example", titles: [ "Account Executive", "Data Engineer", "Recruiter" ]
      )
    end

    it "skips a company whose page is read through an ATS API, free already" do
      read(read_via: "ats_api:lever")

      expect(described_class.board(company)).to be_nil
    end

    it "skips a company whose board was confirmed after its latest read, and looks again once the page is read since" do
      read(at: 2.days.ago)
      adopt_board(confirmed_at: 1.day.ago)
      expect(described_class.board(company)).to be_nil

      read(at: 1.hour.ago)
      expect(described_class.board(company)).to include(id: company.id)
    end

    it "skips a company never verified" do
      expect(described_class.board(company)).to be_nil
    end
  end
end
