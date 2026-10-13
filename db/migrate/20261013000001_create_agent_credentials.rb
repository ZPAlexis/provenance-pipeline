class CreateAgentCredentials < ActiveRecord::Migration[8.1]
  def change
    # Scoped writes (1.3): what an agent run may write, issued for that run and
    # presented for every write it makes. Only a digest of the token is kept.
    # A credential row is never deleted: the audit events it made point at it.
    create_table :agent_credentials, id: :uuid do |t|
      t.string :actor, null: false # the agent it was issued to, e.g. agent:verifier
      t.string :scopes, array: true, null: false, default: []
      t.string :token_digest, null: false # SHA-256 of the token, which is shown once and never stored
      t.string :purpose, null: false # the run it was issued for
      t.string :issued_by, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :agent_credentials, :token_digest, unique: true
    add_index :agent_credentials, %i[actor created_at]

    # The credential behind each agent write, and behind each write refused.
    add_reference :audit_events, :credential, type: :uuid, foreign_key: { to_table: :agent_credentials }
  end
end
