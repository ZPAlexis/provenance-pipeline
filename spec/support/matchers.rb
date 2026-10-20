# Lets `change` compose with `.and`: expect { }.to not_change(A, :count).and not_change(B, :count)
RSpec::Matchers.define_negated_matcher :not_change, :change
# And `include`: expect(page).to include("Approved").and not_include("Save and approve")
RSpec::Matchers.define_negated_matcher :not_include, :include
