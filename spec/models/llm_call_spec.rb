require "rails_helper"

# One row per API call: what the database needs to answer "what did this cost,
# and what produced it" after the run directory is gone.
RSpec.describe LlmCall do
  it "records a call against the page check it served" do
    expect(build(:llm_call)).to be_valid
  end

  it "requires the served model, the prompt version, and when it happened" do
    %i[run_id model prompt_version called_at].each do |field|
      expect(build(:llm_call, field => nil)).not_to be_valid, field.to_s
    end
  end

  it "accepts only known purposes" do
    expect(build(:llm_call, purpose: "chat")).not_to be_valid
  end

  it "rejects negative tokens or cost" do
    expect(build(:llm_call, input_tokens: -1)).not_to be_valid
    expect(build(:llm_call, cost_usd: -0.01)).not_to be_valid
  end
end
