# A careers page rendered for the operator's own AI assistant to read (4f): a page a free check left unread, opened by
# the worker (never read by the AI here), its text and numbered links kept as the extractor would have seen them, so
# what the assistant saves of the page can be checked against the page itself. Evidence, written by the verifier.
class CreatePageRenders < ActiveRecord::Migration[8.1]
  def change
    create_table :page_renders, id: :uuid do |t|
      t.references :company, type: :uuid, null: false, foreign_key: true
      # The check that left the page unread (needs_reading), which the assistant was asked to read.
      t.references :page_check, type: :uuid, foreign_key: true, index: false # the index below leads with it
      t.string :run_id, null: false
      t.string :url, null: false
      t.string :final_url
      t.integer :http_status
      t.string :title
      t.text :text, null: false
      t.boolean :text_truncated, null: false, default: false
      # [[link text, absolute URL], ...] in the page's order: link n is the nth, as the extractor numbers them.
      t.jsonb :links, null: false, default: []
      t.boolean :links_truncated, null: false, default: false
      t.string :content_hash, null: false
      t.datetime :rendered_at, null: false
      t.timestamps
    end
    add_index :page_renders, %i[page_check_id rendered_at]
  end
end
