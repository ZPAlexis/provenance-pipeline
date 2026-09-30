class AddResolutionToCompanies < ActiveRecord::Migration[8.1]
  def change
    # A company's careers page is a watch target, polled for months, so how it
    # was found and how sure we are is part of the record. Resolution failures
    # are tracked here, apart from verification failures.
    add_column :companies, :resolution_status, :string # resolved | candidate | failed; nil = never attempted
    add_column :companies, :resolution_method, :string # imported | path_probe | homepage_link | page_link | ats_guess | llm_link | manual
    add_column :companies, :resolution_confidence, :string # high | medium | low | confirmed (by a human)
    # A low-confidence find waits here for a human, never in careers_page_url.
    add_column :companies, :resolution_candidate_url, :string
    add_column :companies, :resolution_failure, :string # no_domain | anonymised | not_found | blocked | inaccessible | rejected
    add_column :companies, :resolved_at, :datetime

    add_index :companies, :resolution_status
  end
end
