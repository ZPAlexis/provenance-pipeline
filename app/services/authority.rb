# The permission model (1.3), as code: who may write what, checked at every save.
#
# Every create, update and destroy passes `check!` (ApplicationRecord's
# callbacks). While an agent acts, it does so under a credential issued for its
# run (`run`) with exactly the scopes that run needs, and each write must be one
# a scope's rules allow: that model, that action, those attributes, in that
# state. The review queue's bookkeeping acts under a grant fixed in code
# (`as_system`). A write no rule allows is refused, and the refusal is recorded
# as a "denied" audit event that outlives the rollback of the write it stopped.
#
# Nobody acting means the operator: their writes are unchecked until a login
# exists (1.4). What no scope grants is theirs alone (HUMAN_ONLY). The audit log
# is append-only for everyone, and an event in an agent's name needs that
# agent's credential.
module Authority
  class Denied < ActiveRecord::ActiveRecordError; end

  # One kind of write a scope allows: to a model, by action, of these attributes
  # (any, less `except`), when `only_if` holds for the record as it would be saved.
  Rule = Data.define(:model, :actions, :attributes, :except, :only_if) do
    def initialize(model:, actions:, attributes: :all, except: [], only_if: nil)
      super(model: model, actions: actions, attributes: attributes, except: except, only_if: only_if)
    end

    def allows?(record, action, changed)
      model == record.class.name && actions.include?(action) && !changed.intersect?(except) &&
        (attributes == :all || (changed - attributes).empty?) && (only_if.nil? || only_if.call(record))
    end
  end

  COMPANY_ENRICHMENT = %w[careers_page_url ats_type resolution_status resolution_method resolution_confidence
                          resolution_candidate_url resolution_failure resolved_at kind_suggestion kind_evidence
                          board_vendor board_token board_overlap board_evidence board_confirmed_at].freeze
  VERDICT = %w[verification_state roles_listed_count work_mode last_checked_at job_url].freeze
  # A suggestion, and one still: a new record's stored value is its column default, so it is not asked.
  SUGGESTED = ->(posting) { posting.tracking == "suggested" && (posting.new_record? || posting.tracking_in_database == "suggested") }

  # What each scope lets its holder write. Reads are not scoped here: 2.3's MCP server scopes them.
  SCOPES = {
    "companies:enrich" => {
      about: "A company's careers page and how it was found, its free board, and a suggested kind; never its name, " \
             "domain, or kind.",
      rules: [ Rule.new(model: "Company", actions: %i[update], attributes: COMPANY_ENRICHMENT) ]
    },
    "postings:verify" => {
      about: "A role's verdict, what its check observed, and its own page at the employer; its title and location " \
             "only while its title is pending. Never its tracking.",
      rules: [
        Rule.new(model: "Posting", actions: %i[update], attributes: VERDICT),
        Rule.new(model: "Posting", actions: %i[update], attributes: VERDICT + %w[role_title location],
                 only_if: ->(posting) { posting.role_title_in_database == Posting::TITLE_PENDING })
      ]
    },
    "evidence:write" => {
      about: "Page checks and LLM calls: what was read, how, and what it cost.",
      rules: [
        Rule.new(model: "PageCheck", actions: %i[create]),
        Rule.new(model: "PageCheck", actions: %i[update], attributes: %w[matches complete]),
        Rule.new(model: "LlmCall", actions: %i[create])
      ]
    },
    "postings:suggest" => {
      about: "Propose a role, bring its reasons up to date, or withdraw it, only while it is a suggestion the operator " \
             "hasn't acted on.",
      rules: [
        Rule.new(model: "Posting", actions: %i[create], only_if: SUGGESTED),
        Rule.new(model: "Posting", actions: %i[update], attributes: %w[fit], only_if: SUGGESTED),
        Rule.new(model: "Posting", actions: %i[destroy], only_if: ->(posting) { posting.tracking_in_database == "suggested" })
      ]
    },
    "companies:import" => {
      about: "Companies from a Clay export: created, and their research added; never their name, domain, or kind once on record.",
      rules: [
        Rule.new(model: "Company", actions: %i[create]),
        Rule.new(model: "Company", actions: %i[update], except: %w[name domain kind])
      ]
    },
    "postings:import" => {
      about: "Roles from a Clay export, with their research; never their tracking.",
      rules: [
        Rule.new(model: "Posting", actions: %i[create], except: %w[tracking]),
        Rule.new(model: "Posting", actions: %i[update], except: %w[tracking company_id])
      ]
    },
    "review:keep" => {
      about: "Review items kept in step with the record: raised, restated, and closed when what was seen resolves. " \
             "Never decided.",
      rules: [
        Rule.new(model: "ReviewItem", actions: %i[create], only_if: ->(item) { item.status == "open" && item.decision.nil? }),
        Rule.new(model: "ReviewItem", actions: %i[update], attributes: %w[evidence], only_if: ->(item) { item.status == "open" }),
        Rule.new(model: "ReviewItem", actions: %i[update], attributes: %w[status decision decided_by decided_at note],
                 only_if: ->(item) { item.status_in_database == "open" && item.status == "done" && item.decision == "resolved" })
      ]
    }
  }.freeze

  # The agents, and the most any of their runs' credentials may hold.
  AGENTS = {
    "agent:verifier" => { about: "Finds each watched company's careers page, reads it in full, and records whether each role " \
                                 "on record is still listed.", scopes: %w[companies:enrich postings:verify evidence:write] },
    "agent:suggester" => { about: "Proposes the roles on watched pages that fit the search profile.", scopes: %w[postings:suggest] },
    "agent:clay_importer" => { about: "Imports Clay CSV exports, the seed data.", scopes: %w[companies:import postings:import] }
  }.freeze

  # Bookkeeping worked out from the record, not an agent's judgment: a grant fixed in code, never a token.
  Grant = Data.define(:actor, :scopes, :about) do
    def credential = nil
    def refusal = nil
  end
  SYSTEM = {
    "system:review_queue" => Grant.new(actor: "system:review_queue", scopes: %w[review:keep],
                                       about: "Keeps the review queue in step with the record.")
  }.freeze

  # What no scope grants: the operator's alone, whatever an agent holds.
  HUMAN_ONLY = [
    "Start an application, or move one between stages", "Track or dismiss a role", "Decide a review item",
    "Edit the search profile", "Ask for a check", "Name a company or set its kind", "Issue or revoke a credential"
  ].freeze

  BATCH = 4.hours # a run over many companies
  ONE = 1.hour # a run over one role or company
  IGNORED = %w[id created_at updated_at].freeze

  module_function

  # Issues `actor` a credential with `scopes` for one run, presents it for the
  # block, and revokes it when the run ends. Only the operator issues one.
  def run(actor, scopes:, purpose:, ttl: ONE, issued_by: AuditEvent::OPERATOR, &block)
    deny!(Current.principal, "an agent can't issue a credential") if Current.principal
    credential, token = AgentCredential.issue!(actor: actor, scopes: scopes, purpose: purpose, ttl: ttl, issued_by: issued_by)
    presenting(token, &block)
  ensure
    credential&.revoke!
  end

  # Acts for the block as whoever the token was issued to, if it can be used now.
  def presenting(token)
    credential = AgentCredential.authenticate(token)
    why = credential ? credential.refusal : "no credential was issued with that token"
    deny!(credential, why, actor: credential&.actor || "unknown") if why
    Current.set(principal: credential) { yield credential }
  end

  # Acts for the block under a system grant, whoever acts around it.
  def as_system(actor, &block) = Current.set(principal: SYSTEM.fetch(actor), &block)

  # An agent service's first line: it writes only under its own agent's credential.
  def require_agent!(actor)
    principal = Current.principal
    return principal if principal.is_a?(AgentCredential) && principal.actor == actor

    deny!(principal, "its writes need its own credential, #{principal ? "not #{principal.actor}'s" : 'and none was presented'}",
          actor: actor)
  end

  # The credential behind the writes being made now, if an agent is making them.
  def credential = Current.principal&.credential

  # Seeds history the guard would refuse (an agent's past events) in specs; never in the app.
  def unchecked(&block)
    raise ArgumentError, "Authority.unchecked seeds history in tests only" unless Rails.env.test?

    Current.set(unchecked: true, &block)
  end

  # The guard every write passes (ApplicationRecord). Raises Denied for a write no rule allows.
  def check!(record, action)
    return if Current.unchecked

    principal = Current.principal
    return check_event!(record, action, principal) if record.is_a?(AuditEvent)
    return if principal.nil? # the operator: unchecked until a login exists (1.4)

    changed = action == :destroy ? [] : record.changes_to_save.keys - IGNORED
    why = principal.refusal || refusal(principal, record, action, changed)
    deny!(principal, why, target: record, attempted: attempted(record, action, changed)) if why
  end

  def refusal(principal, record, action, changed)
    rules = principal.scopes.flat_map { |scope| SCOPES.fetch(scope)[:rules] }
    return if rules.any? { |rule| rule.allows?(record, action, changed) }

    what = record.class.model_name.human.downcase
    what = "#{what.match?(/\A[aeiou]/) ? 'an' : 'a'} #{what}"
    "may not #{action} #{what}#{" (#{changed.sort.join(', ')})" if changed.any?} with #{principal.scopes.join(', ')}"
  end

  # The log is append-only, and an event in an agent's (or the queue's) name needs its credential (or grant).
  def check_event!(event, action, principal)
    if action != :create
      deny!(principal, "the audit log is append-only: an event is never changed or deleted", target: event.target)
    elsif principal.nil? ? !event.actor.to_s.start_with?("human:") : event.actor != principal.actor
      deny!(principal, "an event in #{event.actor}'s name needs #{event.actor}'s credential" \
                       "#{principal ? ", not #{principal.actor}'s" : ', and none was presented'}",
            target: event.target, attempted: { "action" => event.action })
    elsif (why = principal&.refusal)
      deny!(principal, why, target: event.target)
    end
  end

  # What a refused write tried, short: long text cut, structured values named by size.
  def attempted(record, action, changed)
    return { "destroy" => record.class.name } if action == :destroy

    changed.index_with do |attribute|
      record.changes_to_save[attribute].map do |value|
        case value
        when String then value.truncate(200)
        when Hash, Array then "(#{value.size} #{value.is_a?(Hash) ? 'keys' : 'items'})"
        else value
        end
      end
    end
  end

  # Records the refusal, then raises it. The record is written once the write's
  # transaction is over, committed or rolled back, so the rollback of the write
  # it stopped never takes the refusal with it.
  def deny!(principal, reason, actor: nil, target: nil, attempted: {})
    actor ||= principal&.actor || AuditEvent::OPERATOR
    keep(actor: actor, action: "denied", target: (target if target&.persisted?), changes_made: attempted,
         reasoning: "Denied: #{reason}.", credential_id: principal&.credential&.id)
    raise Denied, "#{actor}: #{reason}"
  end

  def keep(event)
    done = false
    write = lambda do
      next if done

      if app_transaction?
        defer(write) # an outer transaction is still open: wait for it too
      else
        done = true
        Current.set(unchecked: true) { AuditEvent.create!(**event, occurred_at: Time.current) }
      end
    end
    app_transaction? ? defer(write) : write.call
  end

  def defer(write)
    transaction = ApplicationRecord.current_transaction
    transaction.after_commit(&write)
    transaction.after_rollback(&write)
  end

  # Inside a transaction the app opened (a test's own wrapping transaction never joins).
  def app_transaction? = ApplicationRecord.with_connection { |connection| connection.current_transaction.joinable? }

  private_class_method :refusal, :check_event!, :attempted, :deny!, :keep, :defer, :app_transaction?
end
