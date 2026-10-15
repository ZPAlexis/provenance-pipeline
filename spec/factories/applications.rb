FactoryBot.define do
  factory :application do
    posting
    company { posting.company }
    stage { "applied" }
    stage_changed_on { Date.current }
  end

  factory :activity do
    application
    kind { "email" }
    occurred_on { Date.current }
    summary { "Wrote to the recruiter." }
    logged_by { "human:operator" }
  end
end
