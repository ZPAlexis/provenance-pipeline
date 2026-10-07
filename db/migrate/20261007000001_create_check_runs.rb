class CreateCheckRuns < ActiveRecord::Migration[8.1]
  def change
    # A check the operator asked for from the pages: one role (its own page first,
    # then its company's careers page) or one company (its whole careers page).
    # It runs in the background; the page polls this row for its answer. What a
    # check reads and writes is on the record as usual (page_checks, llm_calls,
    # audit_events, under run_id); this keeps who asked, what it could cost, and
    # what it found, for the dashboard now and 1.4's "what changed" later.
    create_table :check_runs, id: :uuid do |t|
      t.string :kind, null: false # role | company
      t.references :company, type: :uuid, null: false, foreign_key: true
      t.references :posting, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :status, null: false, default: "queued" # queued | running | done | failed
      t.string :requested_by, null: false
      t.decimal :ceiling_usd, precision: 10, scale: 6 # what it could cost, shown before it ran
      t.string :answer # a role's verdict; nil when it could not confirm, or for a company
      t.text :summary
      t.jsonb :tally, null: false, default: {} # verdicts written, unchanged, inconclusive
      t.decimal :cost_usd, precision: 10, scale: 6
      t.string :run_id # the worker run, as page_checks and llm_calls file it
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :check_runs, :status
    add_index :check_runs, :created_at
  end
end
