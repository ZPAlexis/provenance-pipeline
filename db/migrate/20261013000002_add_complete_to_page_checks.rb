class AddCompleteToPageChecks < ActiveRecord::Migration[8.1]
  def change
    # The worker's own answer to "was the whole list read?" (1.4), kept on each
    # verification result's first check, where its matches sit. Null before 1.4
    # and on every other check. What changed and Test B's replays read it.
    add_column :page_checks, :complete, :boolean
  end
end
