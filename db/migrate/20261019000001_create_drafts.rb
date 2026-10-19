class CreateDrafts < ActiveRecord::Migration[8.1]
  def change
    # Stage 2c: a cover letter or an outreach note for an application, written by
    # the drafter from what is on record, then the operator's to edit and approve.
    # Nothing is ever sent. `written_*` keep what the drafter wrote, never changed;
    # `subject` and `body` are the text as it stands, the operator's edits included.
    # It keeps which resume and description versions it read (and their hashes,
    # which outlive a deleted resume) and the LLM call that wrote it. Audited by
    # size and hash, never its text: a draft is the resume paraphrased.
    create_table :drafts, id: :uuid do |t|
      t.references :application, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false # cover_letter, outreach
      t.string :status, null: false, default: "draft" # draft, approved
      t.string :language, null: false # as the drafter reports writing it
      t.string :asked_language # none: the language of the role's description
      t.text :guidance # the operator's: anything to stress
      t.string :subject
      t.text :body, null: false
      t.string :written_subject
      t.text :written_body, null: false
      t.jsonb :drew_on, null: false, default: [] # [{ line, text, used_for }]: the resume lines it rests on
      t.jsonb :gaps, null: false, default: [] # [{ asks, note }]: what the role asks that the resume doesn't show
      t.text :notes # the drafter's note to the operator
      t.integer :dropped_lines, null: false, default: 0 # lines it cited that the resume doesn't have
      t.references :resume, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :resume_hash, null: false
      t.references :role_description, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :description_hash, null: false
      t.references :llm_call, type: :uuid, foreign_key: true
      t.string :run_id, null: false
      t.datetime :edited_at
      t.datetime :approved_at
      t.timestamps
    end
    add_index :drafts, %i[application_id created_at]
  end
end
