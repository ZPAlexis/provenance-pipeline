FactoryBot.define do
  factory :company do
    sequence(:name) { |n| "Company #{n}" }
    sequence(:domain) { |n| "company#{n}.example" }

    # ~1% of real rows arrive without a domain; the dedup key then falls back
    # to the company name.
    trait :without_domain do
      domain { nil }
    end

    trait :with_careers_page do
      careers_page_url { "https://#{domain || 'careers.example'}/careers" }
    end

    trait :resolved do
      with_careers_page
      resolution_status { "resolved" }
      resolution_method { "path_probe" }
      resolution_confidence { "high" }
      resolved_at { Time.current }
    end

    # A low-confidence find, held for a human to confirm.
    trait :resolution_candidate do
      resolution_status { "candidate" }
      resolution_method { "llm_link" }
      resolution_confidence { "low" }
      resolution_candidate_url { "https://#{domain || 'careers.example'}/join" }
    end
  end
end
