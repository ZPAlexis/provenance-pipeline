FactoryBot.define do
  factory :check_run do
    company
    kind { "company" }
    status { "queued" }
    requested_by { "human:operator" }

    trait :role do
      kind { "role" }
      posting { association(:posting, company: company) }
    end
  end
end
