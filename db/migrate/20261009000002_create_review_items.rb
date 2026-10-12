class CreateReviewItems < ActiveRecord::Migration[8.1]
  def change
    # The operator's review queue (1.5e): what an agent saw that needs a person's
    # judgment, one item per question about one company or role. Raised by the
    # agent that saw it, closed by the operator's decision or when the evidence
    # resolves; every write audited. An item the operator left is raised again
    # only when the evidence changes (evidence_key). From 1.3 a review agent
    # writes its recommendation on an item; it never decides one.
    create_table :review_items, id: :uuid do |t|
      t.string :kind, null: false
      t.references :company, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :subject_type, null: false # Company, or Posting for a question about one role
      t.uuid :subject_id, null: false
      t.string :status, null: false, default: "open" # open | done | left
      t.text :evidence, null: false # what was seen, in a sentence or two
      t.string :evidence_key, null: false # what was seen, as a fingerprint
      t.string :proposal # the action proposed: confirm, set_kind:recruiter, find_again, set_page, hand_check, check_again
      t.string :raised_by, null: false
      t.string :decided_by
      t.string :decision # the action taken, "left", or "resolved" (the evidence changed)
      t.text :note
      t.datetime :decided_at
      t.jsonb :recommendation, null: false, default: {} # a review agent's, from 1.3 on
      t.timestamps
    end
    add_index :review_items, %i[subject_type subject_id]
    add_index :review_items, :status
    add_index :review_items, %i[kind subject_type subject_id], unique: true, where: "status = 'open'",
                                                               name: "index_review_items_one_open_per_question"
  end
end
