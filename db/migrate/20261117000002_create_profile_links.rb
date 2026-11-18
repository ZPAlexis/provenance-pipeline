# The operator's own links (4d): their website, GitHub, or another portfolio, at most five, kept with the search profile
# (never LinkedIn). Each is read by the app, free and never by the LLM: its pages are kept version by version, as a
# role's description is (a page read again with the same text only says when it was seen).
class CreateProfileLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :profile_links, id: :uuid do |t|
      t.references :search_profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :label, null: false
      t.string :url, null: false
      t.integer :position, null: false, default: 0
      # The newest read: when, what came of it (ok, gone, blocked, inaccessible, error), why not, and pages left unread.
      t.datetime :read_at
      t.string :read_outcome
      t.string :read_reason
      t.integer :read_skipped, null: false, default: 0
      t.timestamps
    end
    add_index :profile_links, %i[search_profile_id url], unique: true

    create_table :link_pages, id: :uuid do |t|
      t.references :profile_link, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :url, null: false
      t.string :title
      t.text :text, null: false
      t.string :content_hash, null: false
      t.string :read_via, null: false
      t.string :run_id, null: false
      t.datetime :first_read_at, null: false
      t.datetime :last_read_at, null: false
      t.timestamps
    end
    add_index :link_pages, %i[profile_link_id url last_read_at]
  end
end
