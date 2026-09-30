FactoryBot.define do
  factory :page_check do
    company
    run_id { "20260930T100000Z-test" }
    purpose { "resolution" }
    step { "path_probe" }
    sequence(:url) { |n| "https://company#{n}.example/careers" }
    outcome { "ok" }
    read_via { "render+llm" }
    listing_count { 3 }
    listings { [ { "title" => "Revenue Operations Engineer", "url" => nil, "location" => nil, "work_mode" => "unknown" } ] }
    checked_at { Time.current }
  end
end
