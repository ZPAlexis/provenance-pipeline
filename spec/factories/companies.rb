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
  end
end
