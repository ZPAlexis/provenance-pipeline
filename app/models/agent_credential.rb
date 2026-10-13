# What one agent run may write (1.3): issued to the agent for that run, with
# exactly the scopes it needs, presented for every write it makes, and revoked
# when it ends. Only the token's digest is stored; the token is handed to the
# run once. A credential is never deleted: its audit events point at it.
class AgentCredential < ApplicationRecord
  TOKEN_PREFIX = "ppa_".freeze

  has_many :audit_events, foreign_key: :credential_id, inverse_of: :credential, dependent: nil

  validates :actor, inclusion: { in: ->(_) { Authority::AGENTS.keys } }
  validates :purpose, :issued_by, :expires_at, :token_digest, presence: true
  validate :scopes_granted_to_actor

  scope :newest_first, -> { order(created_at: :desc) }
  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  # Returns the credential and its token, which is never stored or shown again.
  def self.issue!(actor:, scopes:, purpose:, ttl:, issued_by:)
    token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    credential = create!(actor: actor, scopes: scopes.uniq, purpose: purpose, issued_by: issued_by,
                         expires_at: ttl.from_now, token_digest: digest(token))
    [ credential, token ]
  end

  def self.digest(token) = OpenSSL::Digest::SHA256.hexdigest(token.to_s)

  # The credential a token was issued as, whatever its state; nil for a token never issued.
  def self.authenticate(token)
    find_by(token_digest: digest(token)) if token.to_s.start_with?(TOKEN_PREFIX)
  end

  def credential = self

  # Revoked when its run ends (not audited: the run's own end).
  def revoke!
    update!(revoked_at: Time.current) unless revoked_at
  end

  # Revoked by a person while it can still be used: audited as theirs. Its run's next write is refused.
  def revoke_by!(actor, note: nil)
    raise ArgumentError, "it is already #{status}" unless status == "active"

    transaction do
      revoke!
      AuditEvent.record_write!(self, actor: actor, reasoning: [ "Revoked by hand: its run's next write is refused.", note.presence ].compact.join(" "))
    end
  end

  # Why it can't be used now, from the database (a revocation made elsewhere
  # counts at once); nil while it can.
  def refusal(at: Time.current)
    revoked, expires = self.class.where(id: id).pick(:revoked_at, :expires_at)
    if revoked then "its credential was revoked #{revoked.utc.iso8601}"
    elsif expires.nil? || expires <= at then "its credential expired #{expires&.utc&.iso8601}"
    end
  end

  def status(at: Time.current)
    if revoked_at then "revoked"
    elsif expires_at <= at then "expired"
    else "active"
    end
  end

  private

  def scopes_granted_to_actor
    beyond = scopes - Authority::AGENTS.fetch(actor, {}).fetch(:scopes, [])
    errors.add(:scopes, "beyond what #{actor} may hold: #{beyond.join(', ')}") if beyond.any?
    errors.add(:scopes, "can't be empty") if scopes.empty?
  end
end
