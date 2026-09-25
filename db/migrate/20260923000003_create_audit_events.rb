class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_events, id: :uuid do |t|
      # Namespaced actor identity, e.g. "human:alexis", "agent:clay_importer",
      # "agent:verifier". Every write to the system names who made it.
      t.string :actor, null: false
      t.string :action, null: false

      t.references :target, polymorphic: true, type: :uuid

      # NOT named `changes` — that collides with ActiveModel::Dirty#changes
      # and produces confusing runtime failures.
      t.jsonb :changes_made, null: false, default: {}

      t.string :model_version

      # Prose reasoning behind the write. Prototyping showed the structured
      # verdict alone was not trustworthy: the free-text evidence was read
      # every time to interpret it. A structured field is a lossy compression
      # of a judgment — this is where the fidelity lives.
      t.text :reasoning

      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :audit_events, :actor
    add_index :audit_events, :occurred_at
  end
end
