require "rails_helper"

RSpec.describe Posting do
  describe "validations" do
    it "requires a role title" do
      expect(build(:posting, role_title: nil)).not_to be_valid
    end

    it "defaults to pending verification" do
      expect(described_class.new.verification_state).to eq("pending")
    end

    it "rejects an unknown verification state" do
      expect(build(:posting, verification_state: "probably_live")).not_to be_valid
    end

    it "accepts a known work mode or none" do
      expect(build(:posting, work_mode: "hybrid")).to be_valid
      expect(build(:posting, work_mode: nil)).to be_valid
    end

    it "rejects an unknown work mode" do
      expect(build(:posting, work_mode: "sometimes")).not_to be_valid
    end

    it "rejects a duplicate posting URL" do
      create(:posting, posting_url: "https://jobs.example/postings/1")
      expect(build(:posting, posting_url: "https://jobs.example/postings/1")).not_to be_valid
    end

    # A check date means a usable verdict, and a usable verdict means a check
    # date: nil last_checked_at has exactly one meaning, "never checked".
    it "requires a check date on a verdict" do
      %w[verified_live not_found inaccessible].each do |state|
        expect(build(:posting, verification_state: state, last_checked_at: nil)).not_to be_valid, state
      end
    end

    it "rejects a check date without a verdict" do
      expect(build(:posting, verification_state: "pending", last_checked_at: Time.current)).not_to be_valid
    end

    it "allows many postings without a URL" do
      create(:posting, posting_url: nil)
      expect(build(:posting, posting_url: nil)).to be_valid
    end

    # roles_listed_count means "roles seen on the page" and nothing else. Unknown
    # is nil, never a sentinel — a negative would slip past both negative-verdict
    # scopes and silently disable the parse-failure check.
    it "accepts zero, a positive count, or an unknown count" do
      expect(build(:posting, roles_listed_count: 0)).to be_valid
      expect(build(:posting, roles_listed_count: 112)).to be_valid
      expect(build(:posting, roles_listed_count: nil)).to be_valid
    end

    it "rejects a negative roles count" do
      expect(build(:posting, roles_listed_count: -1)).not_to be_valid
    end
  end

  describe "filter scopes" do
    it "selects by verification state, work mode, and source slice" do
      pending_one = create(:posting)
      live_remote = create(:posting, :verified_live, source_slice: "brazil")
      live_onsite = create(:posting, :verified_live, work_mode: "onsite")

      expect(described_class.pending).to contain_exactly(pending_one)
      expect(described_class.live).to contain_exactly(live_remote, live_onsite)
      expect(described_class.remote).to contain_exactly(live_remote)
      expect(described_class.from_slice("brazil")).to contain_exactly(live_remote)
    end
  end

  # The corroborating-observable pattern: a `not_found` verdict is only
  # credible if the agent could see other roles on the same page.
  describe "negative verdicts" do
    let!(:credible) { create(:posting, :credible_negative) }
    let!(:suspect_zero) { create(:posting, :suspect_negative) }
    let!(:suspect_uncounted) { create(:posting, :suspect_negative, roles_listed_count: nil) }
    let!(:live_with_zero) { create(:posting, :verified_live, roles_listed_count: 0) }

    it "treats not_found with zero or unknown roles listed as suspect" do
      expect(described_class.suspect_negatives).to contain_exactly(suspect_zero, suspect_uncounted)
    end

    it "treats not_found with roles listed as credible" do
      expect(described_class.credible_negatives).to contain_exactly(credible)
    end

    it "never classifies a live posting as a negative" do
      expect(described_class.suspect_negatives).not_to include(live_with_zero)
      expect(described_class.credible_negatives).not_to include(live_with_zero)
    end

    it "keeps #suspect_negative? in agreement with the scope" do
      described_class.find_each do |posting|
        expect(posting.suspect_negative?).to eq(described_class.suspect_negatives.include?(posting)),
          "disagreement on state=#{posting.verification_state} count=#{posting.roles_listed_count.inspect}"
      end
    end
  end
  describe "tracking" do
    it "is tracked unless said otherwise, and is one of suggested, tracked, or dismissed" do
      expect(described_class.new.tracking).to eq("tracked")
      expect(build(:posting, tracking: "suggested")).to be_valid
      expect(build(:posting, tracking: "watched")).not_to be_valid
    end

    it "leaves dismissed postings out of the ones checked" do
      tracked = create(:posting)
      suggested = create(:posting, tracking: "suggested")
      create(:posting, tracking: "dismissed")

      expect(described_class.not_dismissed).to contain_exactly(tracked, suggested)
      expect(described_class.tracked).to contain_exactly(tracked)
    end
  end
end
