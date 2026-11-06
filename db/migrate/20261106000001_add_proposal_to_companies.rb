class AddProposalToCompanies < ActiveRecord::Migration[8.1]
  def change
    # 4b: a company the operator's own Claude client proposed ("suggested", a third tracking value, needs no column of
    # its own) keeps why: who proposed it, why it may fit, where it was found, and what the app's own free read of its
    # board saw. As postings.fit holds a suggested role's.
    add_column :companies, :proposal, :jsonb
  end
end
