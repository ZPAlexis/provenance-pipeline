require "rails_helper"

# How the search is going (3.3): the pipeline from the audit log, as the operator dated each stage.
RSpec.describe Analytics do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let(:day) { ->(n) { Date.current - 30 + n } } # day 30 is today

  # Eight made-up applications, through the service that writes them, so their audit events are as the app writes
  # them: a same-day move carries no date, and a stage re-dated in place carries a date and no stage.
  def applications
    apply = lambda do |title, *moves|
      start, on = moves.shift
      role = create(:posting, company: company, role_title: title)
      application = later { Pipeline.start!(role, stage: start, on: day.(on)) }
      moves.each { |stage, at| later { Pipeline.move!(application, stage, on: day.(at)) } }
      application
    end
    apply.("Won", [ "interested", 0 ], [ "preparing", 2 ], [ "applied", 9 ], [ "interviewing", 14 ], [ "offer", 24 ], [ "accepted", 26 ])
    apply.("Rejected after applying", [ "interested", 0 ], [ "preparing", 1 ], [ "applied", 8 ], [ "rejected", 11 ])
    apply.("Rejected while preparing", [ "preparing", 4 ], [ "rejected", 19 ])
    apply.("Preparing the same day", [ "interested", 5 ], [ "preparing", 5 ], [ "no_response", 25 ])
    apply.("Withdrawn", [ "interested", 9 ], [ "withdrawn", 10 ])
    interviewing = apply.("Interviewing", [ "preparing", 11 ], [ "applied", 13 ], [ "interviewing", 19 ])
    apply.("Interested", [ "interested", 19 ])
    redated = apply.("Re-dated", [ "preparing", 14 ], [ "applied", 17 ])
    later { Pipeline.move!(redated, "applied", on: day.(16)) } # applied a day earlier than first said
    later { Pipeline.note!(interviewing, notes: "Panel next week.", comp_expectation: nil) } # not a stage: ignored
  end

  it "counts how far applications get, each counted at every stage up to its furthest, and the rate from the stage before" do
    applications

    steps = described_class.pipeline.steps

    expect(steps.map { |step| [ step.stage, step.reached, step.before ] })
      .to eq([ [ "interested", 8, nil ], [ "preparing", 6, 8 ], [ "applied", 4, 6 ], [ "interviewing", 2, 4 ], [ "offer", 1, 2 ], [ "accepted", 1, 1 ] ])
    expect(steps.map(&:rate)).to eq([ nil, 75, 67, nil, nil, nil ]) # below 5 at the stage before, too few to say
  end

  it "measures the days in each open stage, as dated: a same-day move carried forward, a stage re-dated, one still there so far" do
    applications

    stays = described_class.pipeline.stays.to_h { |stay| [ stay.stage, stay.to_h.except(:stage) ] }

    expect(stays).to eq(
      "interested" => { times: 5, still: 1, median: 1.0, longest: 11 },
      "preparing" => { times: 6, still: 0, median: 7.0, longest: 20 },
      "applied" => { times: 4, still: 1, median: 5.5, longest: 14 },
      "interviewing" => { times: 2, still: 1, median: 10.5, longest: 11 },
      "offer" => { times: 1, still: 0, median: 2.0, longest: 2 }
    )
  end

  it "says how applications end: accepted of those closed, and an offer of those applied, once there are enough" do
    applications

    outcome = described_class.pipeline.outcome

    expect(outcome.to_h).to eq(closed: 5, accepted: 1, applied: 4, offers: 1)
    expect([ outcome.accepted_rate, outcome.offer_rate ]).to eq([ 20, nil ]) # 4 applied to: too few to say
    expect(described_class::Outcome.new(closed: 5, accepted: 1, applied: 6, offers: 1).offer_rate).to eq(17)
    expect(described_class::Outcome.new(closed: 4, accepted: 1, applied: 4, offers: 1).accepted_rate).to be_nil
  end

  it "shows what is open now by stage, and the tracked roles still listed with no application" do
    applications
    create(:posting, :verified_live, company: company, role_title: "Still listed", tracking: "tracked")
    create(:posting, :verified_live, company: company, role_title: "Suggested", tracking: "suggested")
    Posting.find_by!(role_title: "Won").update!(verification_state: "verified_live", last_checked_at: Time.current) # applied to: not counted

    report = described_class.pipeline

    expect(report.open.map(&:to_h)).to eq([ { stage: "interested", applications: 1, median: 11.0, longest: 11 },
                                            { stage: "applied", applications: 1, median: 14.0, longest: 14 },
                                            { stage: "interviewing", applications: 1, median: 11.0, longest: 11 } ])
    expect(report.unapplied).to eq(1)
  end

  it "takes the applications started since a day, and has nothing to say with none" do
    applications

    report = described_class.pipeline(since: day.(9))

    expect(report.applications).to eq(4)
    expect(report.steps.first(3).map(&:reached)).to eq([ 4, 2, 2 ])
    expect(described_class.pipeline(since: Date.tomorrow)).to have_attributes(applications: 0, stays: [], outcome: have_attributes(closed: 0))
  end
end
