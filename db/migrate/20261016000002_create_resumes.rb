class CreateResumes < ActiveRecord::Migration[8.1]
  def change
    # Stage 2b: the operator's resume, held with the search profile, version by
    # version, in this database only: never in the repo, its fixtures, or its
    # seeds. Pasted as text. Its audit events record each version's size and
    # hash, never its text, so the log never copies it.
    create_table :resumes, id: :uuid do |t|
      t.references :search_profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :text, null: false
      t.string :content_hash, null: false
      t.timestamps
    end
    add_index :resumes, %i[search_profile_id created_at]
  end
end
