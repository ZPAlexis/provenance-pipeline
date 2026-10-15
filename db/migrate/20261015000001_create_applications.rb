class CreateApplications < ActiveRecord::Migration[8.1]
  def change
    # Stage 2a: the operator's applications, one per role on record. Only the
    # operator starts one or moves it between stages (no agent scope allows it),
    # and every change is audited: the history of stages is the audit log.
    create_table :applications, id: :uuid do |t|
      t.references :posting, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.references :company, type: :uuid, null: false, foreign_key: true
      t.string :stage, null: false
      t.date :stage_changed_on, null: false # when it reached its stage, as the operator says
      t.string :comp_expectation
      t.text :notes
      t.timestamps
    end
    add_index :applications, :stage

    # What happened along the way: an email, a call, an interview. Logged by the
    # operator for now; by an agent with its own scope from 2d.
    create_table :activities, id: :uuid do |t|
      t.references :application, type: :uuid, null: false, foreign_key: true
      t.string :kind, null: false
      t.date :occurred_on, null: false
      t.text :summary, null: false
      t.string :logged_by, null: false
      t.timestamps
    end
    add_index :activities, %i[application_id occurred_on]
  end
end
