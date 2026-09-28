FactoryBot.define do
  factory :posting do
    company
    sequence(:role_title) { |n| "Revenue Operations Engineer #{n}" }
    sequence(:posting_url) { |n| "https://jobs.example/postings/#{n}" }
    source_slice { "testland" }
    verification_state { "pending" }

    trait :verified_live do
      verification_state { "verified_live" }
      roles_listed_count { 12 }
      work_mode { "remote" }
      last_checked_at { Time.current }
    end

    # The two shapes of `not_found` the corroborating observable separates:
    # roles were visible on the page (credible), or none were (the agent reached
    # the page but could not read it — almost certainly a parse failure).
    trait :credible_negative do
      verification_state { "not_found" }
      roles_listed_count { 23 }
      last_checked_at { Time.current }
    end

    trait :suspect_negative do
      verification_state { "not_found" }
      roles_listed_count { 0 }
      last_checked_at { Time.current }
    end
  end
end
