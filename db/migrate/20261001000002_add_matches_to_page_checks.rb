class AddMatchesToPageChecks < ActiveRecord::Migration[8.1]
  def change
    # A verification's outcome per posting, kept on the check that read the page:
    # the record of why a posting got its verdict, or why it got none.
    add_column :page_checks, :matches, :jsonb, null: false, default: []
  end
end
