class AddKindToCompanies < ActiveRecord::Migration[8.1]
  def change
    # What kind of company it is: employer | recruiter | aggregator; nil = unknown.
    # A recruiter's own board lists its clients' roles, and those are its openings;
    # an aggregator's lists other companies' own postings. Set by the operator.
    add_column :companies, :kind, :string
    # What the pages resolution read suggest (recruiter | aggregator), held for the
    # operator to confirm, with the evidence for it.
    add_column :companies, :kind_suggestion, :string
    add_column :companies, :kind_evidence, :text
  end
end
