FactoryBot.define do
  # A company review (4b) as the operator's own client saves one through CompanyReviews: read against the company
  # preferences as they are, or a made-up digest when there are none. Specs that test saving one go through the service.
  factory :company_review do
    company
    score { 72 }
    why { "It sells to revenue teams and hires in Brazil; its funding is unknown." }
    business_model { "b2b" }
    points do
      [ { "about" => "wants", "preference" => "Products for revenue teams.", "verdict" => "match", "evidence" => "Its product page.",
          "sources" => [ "https://#{company.domain || 'company.example'}/product" ] },
        { "about" => "stage", "preference" => "Series A or B", "verdict" => "unknown" } ]
    end
    sources { [ "https://#{company.domain || 'company.example'}/about" ] }
    preferences_digest { SearchProfile.current&.company_preferences_digest || "sha256:made-up" }
    written_by { "agent:assistant" }
  end
end
