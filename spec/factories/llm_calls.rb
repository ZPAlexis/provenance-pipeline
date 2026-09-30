FactoryBot.define do
  factory :llm_call do
    page_check
    run_id { "20260930T100000Z-test" }
    purpose { "extract" }
    model { "claude-haiku-4-5-20251001" }
    settings { {} }
    prompt_version { "abc123def456" }
    input_tokens { 10_000 }
    output_tokens { 2_000 }
    cost_usd { 0.02 }
    called_at { Time.current }
  end
end
