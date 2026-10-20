class AddRequestToCheckRuns < ActiveRecord::Migration[8.1]
  def change
    # Stage 2c: what a run was asked to do beyond its target. A draft run keeps
    # the kind of draft, the language asked and anything to stress, until the
    # job writes it.
    add_column :check_runs, :request, :jsonb, null: false, default: {}
  end
end
