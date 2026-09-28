require "rails_helper"

# Every factory and trait must build a valid record. Catches a factory drifting
# out of step with a new validation before it surfaces as a confusing failure
# in some unrelated spec.
RSpec.describe "Factories" do
  it "builds valid records for every factory and trait" do
    expect { FactoryBot.lint(traits: true) }.not_to raise_error
  end
end
