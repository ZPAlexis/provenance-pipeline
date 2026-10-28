# The audit log, searchable (3.1): every event on record, newest first, narrowed by who wrote it, the kind of
# record, the action, a date range, one record or the credential behind it, and an attribute it changed.
# Read-only: the Audit log page reads it, and (step 2) `audit:list` and the `query_audit_log` MCP tool.
class AuditLog
  PER_PAGE = 50
  FILTERS = %i[who kind action attribute from to record credential].freeze
  ACTIONS = { "create" => "created", "update" => "changed", "destroy" => "deleted", "denied" => "refused" }.freeze
  # A kind of record by the name the app gives it, where that isn't its model's.
  KIND_NAMES = { "Posting" => "role", "AgentCredential" => "credential", "ApplicationContact" => "contact_link" }.freeze
  # What a page of events shows of each subject, loaded with the page rather than row by row.
  SUBJECTS = {
    "Posting" => :company, "Application" => :posting, "Activity" => { application: :posting }, "Draft" => { application: :posting },
    "ResumeReview" => { application: :posting }, "ApplicationContact" => { application: :posting },
    "FitScore" => :posting, "Contact" => :company
  }.freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  attr_reader(*FILTERS)

  # Every filter is optional; each one given narrows the log. A filter the log can't apply is refused, saying why.
  def initialize(who: nil, kind: nil, action: nil, attribute: nil, from: nil, to: nil, record: nil, credential: nil)
    @who = self.class.who(who.presence)
    @kind = self.class.kind(kind.presence)
    @action = action!(action.presence)
    @attribute = attribute!(attribute.presence)
    @from = day!(:from, from.presence)
    @to = day!(:to, to.presence)
    @record = id!(:record, record.presence)
    @credential = id!(:credential, credential.presence)
    raise ArgumentError, "from #{@from} is after to #{@to}" if @from && @to && @from > @to
  end

  # The operator (any human, including rows from before the operator was named that), every agent, or one actor,
  # named in full or by its short name ("verifier" for agent:verifier).
  def self.who(name)
    return if name.nil?
    return "operator" if name == "operator" || name.start_with?("human:")
    return "agents" if name == "agents"

    actor = actors.find { |known| known == name || known.split(":", 2).last == name }
    actor or raise ArgumentError, "unknown actor #{name.inspect}: operator, agents, or one of " \
                                  "#{actors.map { |known| known.split(':', 2).last }.join(', ')}"
  end

  # A kind of record on the log, by its name ("role", "review_item") or its model's ("Posting").
  def self.kind(name)
    return if name.nil?

    kind = kinds.find { |kind_name, type| name == kind_name || name == type }
    kind&.last or raise ArgumentError, "no event on record is about a #{name.inspect}: the kinds on record are " \
                                       "#{kinds.map(&:first).join(', ')}"
  end

  # Every agent and system grant that can write, and any other actor on record (the Clay importer's history).
  def self.actors
    (Authority::AGENTS.keys + Authority::SYSTEM.keys + AuditEvent.distinct.pluck(:actor)).uniq
      .reject { |actor| actor.start_with?("human:") }.sort
  end

  # The kinds of record on the log, as [name, model], by name.
  def self.kinds = AuditEvent.distinct.pluck(:target_type).compact.map { |type| [ kind_name(type), type ] }.sort

  def self.kind_name(type) = KIND_NAMES.fetch(type, type.underscore)

  def self.kind_label(type) = kind_name(type).humanize

  # The attributes the log's events changed, for one kind of record or every kind.
  def self.attributes(kind = nil)
    events = kind ? AuditEvent.where(target_type: kind) : AuditEvent.all
    events.distinct.pluck(Arel.sql("jsonb_object_keys(changes_made)")).sort
  end

  def events = narrowed(AuditEvent.all).order(occurred_at: :desc, id: :desc)

  def count = @count ||= narrowed(AuditEvent.all).count

  def pages = [ (count + PER_PAGE - 1) / PER_PAGE, 1 ].max

  # One page of events, newest first, with what each is about loaded alongside.
  def page(number = 1)
    events = self.events.offset((number - 1) * PER_PAGE).limit(PER_PAGE).preload(:credential, :target).to_a
    events.map(&:target).compact.group_by { |target| target.class.name }.each do |type, targets|
      ActiveRecord::Associations::Preloader.new(records: targets, associations: SUBJECTS[type]).call if SUBJECTS[type]
    end
    events
  end

  # How many events each actor wrote under the other filters, the operator's together, most first.
  def by_who
    narrowed(AuditEvent.all, except: :who).group(:actor).count
      .group_by { |actor, _| actor.start_with?("human:") ? "operator" : actor }
      .transform_values { |counts| counts.sum(&:last) }.sort_by { |actor, count| [ -count, actor ] }
  end

  # The filters given, as a page's or a command's parameters.
  def to_params = FILTERS.to_h { |filter| [ filter, param(filter) ] }.compact

  def filtered? = to_params.any?

  # The latest event about the record filtered on: what the page names it by, even once it is deleted.
  def record_event = (AuditEvent.where(target_id: record).order(occurred_at: :desc).preload(:target).first if record)

  def credential_record = (AgentCredential.find_by(id: credential) if credential)

  private

  def narrowed(scope, except: nil)
    scope = scope.where(actor_condition) if who && except != :who
    scope = scope.where(target_type: kind) if kind
    scope = scope.where(action: action) if action
    scope = scope.where("changes_made ? :attribute", attribute: attribute) if attribute
    scope = scope.where(occurred_at: from.beginning_of_day..) if from
    scope = scope.where(occurred_at: ...(to + 1).beginning_of_day) if to
    scope = scope.where(target_id: record) if record
    scope = scope.where(credential_id: credential) if credential
    scope
  end

  def actor_condition
    case who
    when "operator" then AuditEvent.arel_table[:actor].matches("human:%")
    when "agents" then AuditEvent.arel_table[:actor].matches("agent:%")
    else { actor: who }
    end
  end

  def param(filter)
    value = public_send(filter)
    filter == :kind && value ? self.class.kind_name(value) : value&.to_s
  end

  def action!(action)
    return if action.nil?
    return action if ACTIONS.key?(action)

    ACTIONS.key(action) or raise ArgumentError, "unknown action #{action.inspect}: one of #{ACTIONS.keys.join(', ')}"
  end

  def attribute!(attribute)
    return if attribute.nil?
    return attribute if attribute.match?(/\A[a-z][a-z0-9_]*\z/)

    raise ArgumentError, "an attribute is named as its column is (verification_state, stage), not #{attribute.inspect}"
  end

  def day!(name, value)
    return if value.nil?
    return value if value.is_a?(Date)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise ArgumentError, "#{name} is a day as YYYY-MM-DD, not #{value.to_s.inspect}"
  end

  def id!(name, value)
    return if value.nil?
    return value if value.to_s.match?(UUID)

    raise ArgumentError, "#{name} is an id (a uuid), not #{value.to_s.inspect}"
  end
end
