# What changed since a point (1.4), read from the record alone (the audit log,
# the review queue, and the whole-list reads), nothing stored of its own.
#
# The points are the check-everything runs. By default it is everything since
# the check before the latest one ended: what the latest found, and any single
# check since. With one run so far, it is what that run found and since. Any
# earlier run can be picked instead.
class WhatChanged
  Point = Data.define(:key, :label, :at)

  VERDICTS = %w[not_found verified_live inaccessible pending].freeze

  attr_reader :from

  # The points to compare from, newest first: the latest run's start, then each earlier run's end.
  def self.points
    runs = CheckRun.where(kind: "all", status: %w[done failed]).where.not(finished_at: nil).order(started_at: :desc).to_a
    return [ Point.new(key: "week", label: "The last 7 days (no check of everything yet)", at: 7.days.ago) ] if runs.empty?

    latest, *earlier = runs
    [ Point.new(key: latest.id, label: "What the check of #{latest.started_at.to_date.to_fs(:long)} found, and since",
                at: latest.started_at),
      *earlier.map { |run| Point.new(key: run.id, label: "Since the check of #{run.started_at.to_date.to_fs(:long)} ended", at: run.finished_at) } ]
  end

  # The point asked for by its key, or the default: the check before the latest, else the latest.
  def self.point(key = nil)
    points.find { |point| point.key == key } || points.second || points.first
  end

  def initialize(from)
    @from = from
  end

  def events = AuditEvent.where(occurred_at: @from..).order(occurred_at: :desc).preload(:credential, :target)

  def role_events = AuditEvent.where(occurred_at: @from.., target_type: "Posting").order(occurred_at: :desc).preload(:credential, target: :company)

  # Verdicts that changed, by the answer they changed to.
  def verdicts
    @verdicts ||= role_events.where(action: "update").where("changes_made ? 'verification_state'").to_a
                        .group_by { |event| event.changes_made.dig("verification_state", 1) }
                        .sort_by { |state, _| VERDICTS.index(state) || VERDICTS.size }.to_h
  end

  def suggested = @suggested ||= role_events.where(action: "create", actor: Verifier::Suggestions::ACTOR).to_a

  def withdrawn = @withdrawn ||= role_events.where(action: "destroy", actor: Verifier::Suggestions::ACTOR).to_a

  # Careers pages found, moved, held for the operator, or lost.
  def careers_pages
    @careers_pages ||= events.where(target_type: "Company").where("changes_made ?| array['careers_page_url', 'resolution_status']").to_a
  end

  def boards = @boards ||= events.where(target_type: "Company").where("changes_made ? 'board_vendor'").to_a

  def lists = @lists ||= Verifier::ListChange.since(@from)

  # Descriptions that changed (a role edited or reposted): each new version of a role read before.
  def descriptions
    @descriptions ||= RoleDescription.where(first_read_at: @from..)
                                     .where("EXISTS (SELECT 1 FROM role_descriptions earlier WHERE earlier.posting_id = " \
                                            "role_descriptions.posting_id AND earlier.first_read_at < role_descriptions.first_read_at)")
                                     .order(first_read_at: :desc).preload(posting: :company).to_a
  end

  def questions = @questions ||= ReviewItem.where(created_at: @from..).order(created_at: :desc).preload(:company, :subject).to_a

  def refused = @refused ||= events.denied.to_a

  # Each part, with how many, in the order the page shows them.
  def counts
    {
      "No longer listed" => verdicts.fetch("not_found", []).size, "Listed" => verdicts.fetch("verified_live", []).size,
      "Couldn't confirm" => verdicts.fetch("inaccessible", []).size, "New suggestions" => suggested.size,
      "Suggestions withdrawn" => withdrawn.size, "Pages changed a lot" => lists.size, "Careers pages" => careers_pages.size,
      "Boards" => boards.size, "Descriptions changed" => descriptions.size, "New review questions" => questions.size,
      "Refused writes" => refused.size
    }
  end
end
