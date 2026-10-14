class AllowCheckRunsOverEverything < ActiveRecord::Migration[8.1]
  def change
    # "Check everything" (1.4) is a check run over every watched company: it has
    # no one company, and it says how many it reads so its progress can show.
    change_column_null :check_runs, :company_id, true
    add_column :check_runs, :total, :integer
  end
end
