require "rails_helper"

RSpec.describe "Adding a company, and deciding its careers page", type: :request do
  include ActiveJob::TestHelper

  describe "POST /companies" do
    it "adds it as the operator and starts finding and reading its careers page" do
      expect { post companies_path, params: { link: "https://acme.com/careers", name: "Acme" } }
        .to change(Company, :count).by(1).and have_enqueued_job(CheckNowJob)

      company = Company.find_by!(domain: "acme.com")
      expect(response).to redirect_to(company_path(company))
      expect(flash[:notice]).to eq("Acme added. Finding its careers page and reading its roles now.")
      expect(company.check_runs.sole).to have_attributes(kind: "company", status: "queued", requested_by: "human:operator")
    end

    it "only shows a company already watched" do
      company = create(:company, :resolved, domain: "acme.com")

      expect { post companies_path, params: { link: "acme.com" } }.not_to have_enqueued_job(CheckNowJob)
      expect(response).to redirect_to(company_path(company))
    end

    it "refuses a job board's link, and adds nothing" do
      expect { post companies_path, params: { link: "https://www.linkedin.com/company/acme" } }.not_to change(Company, :count)

      expect(flash[:alert]).to match(/linkedin\.com is a job board/)
    end
  end

  describe "PATCH /companies/:id/rename" do
    it "renames it as the operator" do
      company = create(:company, name: "Brasil")

      patch rename_company_path(company), params: { name: "ArcelorMittal Brasil" }

      expect(company.reload.name).to eq("ArcelorMittal Brasil")
      expect(AuditEvent.find_by!(target: company).changes_made).to eq("name" => [ "Brasil", "ArcelorMittal Brasil" ])
    end
  end

  describe "a careers page found at low confidence" do
    let(:company) { create(:company, :resolution_candidate, domain: "acme.com") }

    it "shows it with the operator's choices" do
      get company_path(company)

      expect(response.body).to include("Is this its careers page?", "Confirm it", "Reject it", "Set its careers page by hand")
    end

    it "is confirmed by the operator, audited as theirs" do
      patch confirm_page_company_path(company)

      expect(company.reload).to have_attributes(resolution_status: "resolved", careers_page_url: "https://acme.com/join")
      expect(AuditEvent.where(target: company).last.actor).to eq("human:operator")
      expect(flash[:notice]).to eq("Its careers page is watched: check it now to read its roles.")
    end

    it "is rejected by the operator" do
      patch reject_page_company_path(company)

      expect(company.reload).to have_attributes(resolution_status: "failed", resolution_failure: "rejected")
    end

    it "is replaced by the page the operator sets, with how they know" do
      patch set_page_company_path(company), params: { url: "https://acme.com/careers", note: "Linked from its homepage." }
      expect(company.reload).to have_attributes(careers_page_url: "https://acme.com/careers", resolution_method: "manual")

      patch set_page_company_path(company), params: { url: "https://acme.com/other", note: "" }
      expect(flash[:alert]).to match(/say how you know/i)
    end
  end
end

RSpec.describe "Adding a role", type: :request do
  include ActiveJob::TestHelper

  it "tracks it as the operator's choice and starts checking it, its own page first" do
    expect { post roles_path, params: { link: "https://jobs.lever.co/acme/0f1e2d3c", title: "Sales Engineer", source: "" } }
      .to change(Posting, :count).by(1).and have_enqueued_job(CheckNowJob)

    role = Posting.sole
    expect(response).to redirect_to(role_path(role))
    expect(flash[:notice]).to eq("Acme added. Sales Engineer tracked. Checking it now: its own page first.")
    expect(role.check_runs.sole).to have_attributes(kind: "role", status: "queued")
  end

  it "keeps a job board's link only as where it was found, and says so" do
    post roles_path, params: { link: "https://www.linkedin.com/jobs/view/4099887766", title: "Sales Engineer" }

    expect(response).to redirect_to(roles_path(add: 1))
    expect(flash[:alert]).to match(/linkedin\.com is a job board/)
    expect(Posting.count).to eq(0)
  end

  it "offers the form on the roles page" do
    get roles_path

    expect(response.body).to include("Add a role", "Where you found it", "Add and check")
  end
end
