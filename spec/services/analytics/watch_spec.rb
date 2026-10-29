require "rails_helper"

# The watch (3.3 step 2): how long roles stay listed, how often answers change, and how fresh they are.
RSpec.describe Analytics::Watch do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let(:now) { Time.utc(2026, 10, 28, 12) }
  let(:day) { ->(n) { Time.utc(2026, 9, 28, 12) + n.days } } # day 0 is a Monday

  def role(title, state, checked = day.(0)) = create(:posting, company: company, role_title: title, verification_state: state,
                                                               last_checked_at: (checked unless state == "pending"))

  # An answer given: when the event carries the check's own time, that is when the role was seen so.
  def answer(posting, before, after, on:, seen: on, actor: "agent:verifier")
    changes = { "verification_state" => [ before, after ] }
    changes["last_checked_at"] = [ nil, day.(seen).iso8601(3) ] if seen
    create(:audit_event, actor: actor, target: posting, action: before ? "update" : "create", changes_made: changes, occurred_at: day.(on))
  end

  # Six roles: closed after 10, 20, 2 and 7 days (one reposted after, one closed by the operator's own check, which
  # carries no check time), one listed still since day 3, and one never seen listed.
  def history
    imported = role("Imported", "not_found")
    answer(imported, nil, "verified_live", on: 0)
    answer(imported, "verified_live", "not_found", on: 10)
    later = role("Listed later", "not_found")
    answer(later, nil, "pending", on: 0, seen: nil)
    answer(later, "pending", "verified_live", on: 5)
    answer(later, "verified_live", "not_found", on: 25)
    still = role("Still listed", "verified_live")
    answer(still, nil, "verified_live", on: 3)
    reposted = role("Reposted", "verified_live")
    answer(reposted, nil, "verified_live", on: 2)
    answer(reposted, "verified_live", "not_found", on: 4)
    answer(reposted, "not_found", "verified_live", on: 6)
    by_hand = role("By hand", "not_found")
    answer(by_hand, nil, "verified_live", on: 1)
    answer(by_hand, "verified_live", "not_found", on: 8, seen: nil, actor: AuditEvent::OPERATOR)
    never = role("Never listed", "not_found")
    answer(never, nil, "pending", on: 0, seen: nil)
    answer(never, "pending", "not_found", on: 12)
  end

  it "measures how long roles stayed listed, by the checks' own days, and how long those listed still have so far" do
    history

    lasting = described_class.report(now: now).lasting

    expect(lasting.to_h).to eq(closed: 4, closed_median: 8.5, closed_longest: 20, listed: 1, listed_median: 27.0, listed_longest: 27)
    expect(described_class.report(since: day.(4).to_date, now: now).lasting.to_h)
      .to include(closed: 1, closed_median: 20.0, listed: 0) # only the role first seen listed on day 5
  end

  it "counts week by week the roles the reads matched and the answers that changed, to what, and how many were yours" do
    history
    create(:page_check, company: company, purpose: "verification", checked_at: day.(1),
                        matches: [ { "posting_id" => "a" }, { "posting_id" => "b" }, { "posting_id" => "c" } ])
    create(:page_check, company: company, purpose: "verification", checked_at: day.(15), matches: [ { "posting_id" => "a" }, { "posting_id" => "b" } ])
    create(:page_check, company: company, purpose: "resolution", checked_at: day.(15), matches: [ { "posting_id" => "a" } ]) # not a verification

    weeks = described_class.report(now: now).weeks

    expect(weeks.map(&:to_h)).to eq([
      { week: Date.new(2026, 10, 19), checked: 0, changed: 1, gone: 1, listed: 0, other: 0, by_operator: 0 },
      { week: Date.new(2026, 10, 12), checked: 2, changed: 0, gone: 0, listed: 0, other: 0, by_operator: 0 },
      { week: Date.new(2026, 10, 5), checked: 0, changed: 3, gone: 3, listed: 0, other: 0, by_operator: 1 },
      { week: Date.new(2026, 9, 28), checked: 3, changed: 3, gone: 1, listed: 2, other: 0, by_operator: 0 }
    ])
    expect(described_class.report(since: day.(14).to_date, now: now).weeks.map(&:week)).to eq([ Date.new(2026, 10, 19), Date.new(2026, 10, 12) ])
  end

  it "says how fresh the tracked roles' answers are now" do
    role("Fresh", "verified_live", now - 2.days)
    role("Stale", "not_found", now - 20.days)
    role("Never", "pending")
    create(:posting, :verified_live, company: company, role_title: "Suggested", tracking: "suggested") # not tracked

    expect(described_class.report(now: now).freshness.to_h).to eq(tracked: 3, fresh: 1, stale: 1, never: 1, oldest: 20)
  end
end
