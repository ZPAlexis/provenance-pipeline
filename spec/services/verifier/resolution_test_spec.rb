require "rails_helper"

RSpec.describe Verifier::ResolutionTest do
  let(:company) { create(:company, name: "Acme", domain: "acme.example", careers_page_url: "https://acme.example/careers") }

  def found(url, outcome: "resolved", confidence: "high", titles: [], **extra)
    check = { "url" => url, "final_url" => url, "outcome" => "ok", "listing_count" => titles.size,
              "listings" => titles.map { |title| { "title" => title } } }
    { "target_id" => company.id, "outcome" => outcome, "careers_page_url" => url, "method" => "path_probe",
      "confidence" => confidence, "checks" => [ check ] }.merge(extra.stringify_keys)
  end

  def known(titles, **extra)
    { "target_id" => company.id, "outcome" => "ok", "listing_count" => titles.size,
      "listings" => titles.map { |title| { "title" => title } } }.merge(extra.stringify_keys)
  end

  def case_for(resolution, known_check = nil)
    test = described_class.new([ company ])
    test.evaluate([ resolution ], [ known_check ].compact).cases.sole
  end

  it "hides the known page from resolution" do
    expect(described_class.new([ company ]).targets).to eq([
      { id: company.id, label: "Acme", domain: "acme.example", name: "Acme", known_url: nil }
    ])
  end

  it "counts the same page as correct, however it is written" do
    expect(case_for(found("http://www.acme.example/careers/?utm=x"))).to be_correct
  end

  it "checks the known page only when resolution answered with a different one" do
    test = described_class.new([ company ])

    expect(test.known_page_targets([ found("https://acme.example/careers") ])).to be_empty
    expect(test.known_page_targets([ found("https://jobs.lever.co/acme") ]).sole).to include(url: "https://acme.example/careers")
  end

  it "counts the same ATS board as correct" do
    board = { "vendor" => "greenhouse", "board" => "acme" }

    expect(case_for(found("https://job-boards.greenhouse.io/acme", ats: board), known([ "A" ], ats: board))).to be_correct
  end

  it "counts a page listing most of the known page's titles as correct" do
    titles = [ "RevOps Engineer", "GTM Analyst", "Solutions Engineer" ]

    expect(case_for(found("https://acme.example/jobs", titles: titles), known(titles + [ "Designer" ]))).to be_correct
    expect(case_for(found("https://acme.example/jobs", titles: titles.first(2)), known(titles + [ "Designer" ]))).not_to be_correct
  end

  # A wrong watched page is the costly failure: nobody looks at it again.
  it "fails on any wrong answer at high or medium confidence" do
    test = described_class.new([ company ])
    report = test.evaluate([ found("https://acme.example/blog", titles: [ "Post" ]) ], [ known([ "RevOps Engineer" ]) ])

    expect(report.wrong.size).to eq(1)
    expect(report).not_to be_passed
  end

  it "counts a wrong candidate as a miss, not a wrong answer" do
    kase = case_for(found("https://acme.example/life", outcome: "candidate", confidence: "low"), known([ "RevOps Engineer" ]))

    expect(kase).to be_measured
    expect(kase).not_to be_correct
    expect(kase).not_to be_wrong
  end

  it "does not measure a company without a domain, one robots.txt keeps out, or a known page it could not read" do
    expect(case_for({ "target_id" => company.id, "outcome" => "failed", "failure" => "no_domain", "checks" => [] })).not_to be_measured
    expect(case_for({ "target_id" => company.id, "outcome" => "failed", "failure" => "blocked", "checks" => [] })).not_to be_measured
    expect(case_for(found("https://acme.example/jobs"), known([], outcome: "inaccessible"))).not_to be_measured
  end

  it "passes at 80% correct with nothing wrong" do
    others = create_list(:company, 4, :with_careers_page)
    test = described_class.new([ company, *others ])
    answers = others.map { |other| { "target_id" => other.id, "outcome" => "resolved", "careers_page_url" => other.careers_page_url, "confidence" => "high", "checks" => [] } }
    miss = { "target_id" => company.id, "outcome" => "failed", "failure" => "not_found", "checks" => [] }

    report = test.evaluate(answers + [ miss ])

    expect([ report.correct, report.measured.size ]).to eq([ 4, 5 ])
    expect(report).to be_passed
  end

  it "adds up what the resolution and the known-page checks cost" do
    resolution = found("https://jobs.lever.co/acme")
    resolution["checks"].first["llm"] = { "cost_usd" => 0.01, "input_tokens" => 900, "output_tokens" => 100 }

    report = described_class.new([ company ]).evaluate(
      [ resolution ], [ known([ "A" ], llm: { "cost_usd" => 0.02, "input_tokens" => 1_000, "output_tokens" => 0 }) ]
    )

    expect([ report.cost_usd, report.tokens ]).to eq([ 0.03, 2_000 ])
  end

  # Label shapes found in the 71-company run (2026-09-30).
  describe "a label that points at one job" do
    let(:company) do
      create(:company, name: "Acme", domain: "acme.example",
                       careers_page_url: "https://careers.acme.example/vacancies/7413976-gtm-engineer")
    end

    it "is matched by an answer on the same careers site" do
      kase = case_for(found("https://careers.acme.example/jobs", titles: [ "Designer" ]), known([ "GTM Engineer" ]))

      expect(kase).to be_correct
      expect(kase.correct_because).to eq("same careers site as the one-job label")
    end

    it "is matched on a shared job-board host only under the same company's path" do
      shared = "https://jobs.boards.example/Acme/744000145601274-gtm-engineer"
      company.update!(careers_page_url: shared)

      expect(case_for(found("https://careers.boards.example/Acme", titles: [ "A" ]), known([ "GTM Engineer" ]))).to be_correct
      expect(case_for(found("https://jobs.boards.example/Other", titles: [ "A" ]), known([ "GTM Engineer" ]))).not_to be_correct
    end

    it "is not matched by another company's board" do
      kase = case_for(found("https://job-boards.greenhouse.io/acmeco", titles: [ "A" ]), known([ "GTM Engineer" ]))

      expect(kase).not_to be_correct
    end
  end

  it "compares a partial answer by the share of its own titles on the known page" do
    answer = found("https://acme.example/careers/jobs", titles: [ "RevOps Engineer", "GTM Analyst" ])
    answer["checks"].first.merge!("stated_total" => 398)

    kase = case_for(answer, known([ "RevOps Engineer", "GTM Analyst", "Designer", "Recruiter", "Counsel" ]))

    expect(kase).to be_correct
    expect(kase.correct_because).to eq("100% titles (a partial list)")
  end

  it "still counts a partial answer that shows the known page's titles" do
    answer = found("https://acme.example/careers", titles: [ "GTM Engineer", "Designer", "Recruiter", "Counsel" ])
    answer["checks"].first.merge!("listings_incomplete" => true)

    expect(case_for(answer, known([ "GTM Engineer" ]))).to be_correct
  end

  it "matches titles worded differently when one contains the other" do
    titles = [ "Founding Engineer", "Founding Creative Director", "Founding Sales" ]
    known_titles = [ "Founding Engineer", "Founding Creative", "Founding Operations" ]

    expect(case_for(found("https://acme.example/jobs", titles: titles), known(known_titles)).title_overlap).to eq(2.0 / 3)
    expect(described_class.titles_match?("engineer", "founding engineer")).to be(false)
  end

  it "recognizes a job's own address by the id in it" do
    expect(described_class.single_job_url?("https://job-boards.greenhouse.io/acme/jobs/8054669")).to be(true)
    expect(described_class.single_job_url?("https://job-boards.greenhouse.io/acme")).to be(false)
  end
end
