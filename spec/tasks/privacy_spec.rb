require "rails_helper"

# The name guard's command, as local CI runs it, over made-up texts in place of the repo.
RSpec.describe "privacy: commands" do
  let(:allowed) { Pathname.new(Dir.mktmpdir).join("names_allowed.yml") }

  before { stub_const("NameGuard::ALLOWED_FILE", allowed) }

  def repo(texts) = allow(NameGuard).to receive(:repo_texts).and_return(texts)

  it "fails naming each place a company on the record is named, and passes once none is or it is allowed there" do
    create(:company, name: "Initech", domain: "initech.com")
    repo("spec/a_spec.rb" => "# Found with Initech.\n", "commit abc1234" => "Fixed for initech.com\n")

    failed = run_task("privacy:names")
    expect(failed.out).to eq("commit abc1234:1: Initech, initech.com\nspec/a_spec.rb:1: Initech\n")
    expect(failed.aborted).to start_with("2 places name a company on the record: the target list is private.")

    allowed.write({ "allowed" => { "Initech" => [ "spec/**", "commit *" ], "initech.com" => [ "*" ] } }.to_yaml)
    expect(run_task("privacy:names").out).to eq("No company on the record is named in the repo: 1 files and 1 unpushed commit checked.\n")
  end

  it "has nothing to check against without a record" do
    expect(run_task("privacy:names").out).to eq("No company on record: nothing to check the repo against.\n")
  end
end
