class AddAssistantWriting < ActiveRecord::Migration[8.1]
  def change
    # Stage 2d step 3: what the operator's own Claude client writes through MCP, saved back. A draft may now be a
    # tailored resume (its changes by line, beside its gaps), may revise an earlier draft (a polished version is a
    # new draft), and says who wrote it: the in-app drafter, or the client as agent:assistant, with the model the
    # client reports (unverified, so named as reported).
    change_table :drafts, bulk: true do |t|
      t.string :written_by, null: false, default: "agent:drafter"
      t.string :reported_model
      t.jsonb :tailoring, null: false, default: [] # a tailored resume's changes: [{ change, lines: [{ line, text }] }] (not "changes": Active Model's)
      t.references :revises, type: :uuid, foreign_key: { to_table: :drafts, on_delete: :nullify }
    end

    # A review of the resume against an application's role: advice for the operator, never sent, never claiming.
    # Its lines are kept with their text, as a draft's are; audited by its counts and hashes, never its text.
    create_table :resume_reviews, id: :uuid do |t|
      t.references :application, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :language, null: false
      t.jsonb :strengths, null: false, default: [] # [{ point, lines: [{ line, text }] }]
      t.jsonb :gaps, null: false, default: [] # [{ asks, note }]
      t.jsonb :suggestions, null: false, default: [] # [{ change, lines: [{ line, text }] }]
      t.text :note
      t.integer :dropped_lines, null: false, default: 0
      t.references :resume, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :resume_hash, null: false
      t.references :role_description, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :description_hash, null: false
      t.string :written_by, null: false
      t.string :reported_model
      t.references :llm_call, type: :uuid, foreign_key: true # the in-app review's call (2d step 4)
      t.string :run_id
      t.timestamps
    end
    add_index :resume_reviews, %i[application_id created_at]
  end
end
