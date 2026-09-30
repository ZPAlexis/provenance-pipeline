class CreateLlmCalls < ActiveRecord::Migration[8.1]
  def change
    # One row per API call. The record answers "what did this cost, and what
    # produced it" without the run directory still existing. Usage lives here,
    # not in audit events: checks that change nothing write no audit event,
    # and they are most of the spend.
    create_table :llm_calls, id: :uuid do |t|
      t.references :page_check, null: false, foreign_key: true, type: :uuid
      t.string :run_id, null: false
      t.string :purpose, null: false # extract | resolve | match

      # The model the API reports having served, which is not always the
      # alias requested, and the request settings (e.g. effort) it ran with.
      t.string :model, null: false
      t.jsonb :settings, null: false, default: {}

      # A hash over everything that shapes what the model sees and returns:
      # system prompt, output schema, truncation limits. "Behavior changed last
      # Tuesday" becomes answerable.
      t.string :prompt_version, null: false

      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      # An estimate from published per-token prices; the tokens are the truth.
      t.decimal :cost_usd, precision: 10, scale: 6, null: false, default: 0

      t.datetime :called_at, null: false

      t.timestamps
    end

    add_index :llm_calls, :run_id
    add_index :llm_calls, [ :model, :called_at ]
  end
end
