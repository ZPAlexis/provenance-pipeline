FactoryBot.define do
  factory :audit_event do
    actor { "agent:test" }
    action { "create" }
    association :target, factory: :company

    trait :by_human do
      actor { "human:alexis" }
    end

    trait :without_target do
      target { nil }
    end
  end
end
