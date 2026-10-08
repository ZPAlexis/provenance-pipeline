class AddFitToPostings < ActiveRecord::Migration[8.1]
  def change
    # Why the suggester proposed a role: how it fits the search profile, as last
    # weighed (the profile title it holds, the place it is open to, its level, what
    # it does not state, and the reasoning). Nil for a role the operator brought.
    # Agents to come (a fit scorer, a cover letter drafter) read it from here.
    add_column :postings, :fit, :jsonb
  end
end
