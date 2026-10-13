FactoryBot.define do
  # History as it was written: an agent's past events are seeded past the guard.
  factory :audit_event do
    to_create { |event| Authority.unchecked { event.save! } }
    actor { "agent:test" }
    action { "create" }
    association :target, factory: :company

    trait :by_human do
      actor { "human:operator" }
    end

    trait :without_target do
      target { nil }
    end
  end
end
