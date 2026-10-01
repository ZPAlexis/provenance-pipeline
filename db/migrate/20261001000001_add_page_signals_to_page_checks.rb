class AddPageSignalsToPageChecks < ActiveRecord::Migration[8.1]
  def change
    # One job's own posting is never a careers page, nor a whole list (1.2c).
    add_column :page_checks, :single_job_posting, :boolean, null: false, default: false
    # Where the list continued, when the page linked to its next page.
    add_column :page_checks, :next_page_url, :string
  end
end
