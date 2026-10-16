class CreateRoleDescriptions < ActiveRecord::Migration[8.1]
  def change
    # Stage 2b: a role's description, as its own page states it, read without the
    # LLM. One row per distinct text: a read that finds the same text only says it
    # was seen again (last_read_at); a changed text is a new version. Evidence of
    # what the page said, like a page check: the drafting and scoring agents read
    # it. A withdrawn suggestion's descriptions go with it.
    create_table :role_descriptions, id: :uuid do |t|
      t.references :posting, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :text, null: false
      t.string :content_hash, null: false
      t.string :read_via, null: false # ats_api:greenhouse (lever, ashby, workday, oracle), or render
      t.string :url, null: false
      t.string :run_id, null: false
      t.datetime :first_read_at, null: false
      t.datetime :last_read_at, null: false
      t.timestamps
    end
    add_index :role_descriptions, %i[posting_id first_read_at]
  end
end
