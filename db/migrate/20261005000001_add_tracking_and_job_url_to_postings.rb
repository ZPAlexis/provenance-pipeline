class AddTrackingAndJobUrlToPostings < ActiveRecord::Migration[8.1]
  def change
    # Whether the operator watches the role: suggested (proposed by the agent from a
    # search profile), tracked (chosen by the operator), or dismissed (declined for
    # good: never checked or suggested again). Only the operator tracks or dismisses.
    # Every posting until now came from the target list the operator chose.
    add_column :postings, :tracking, :string, null: false, default: "tracked"
    add_index :postings, :tracking

    # The role's own page at the employer, learned from the listing it matched.
    # posting_url stays where the role was found (often LinkedIn, never fetched).
    add_column :postings, :job_url, :string
  end
end
