require "rails_helper"

RSpec.describe "Adding a company, and deciding its careers page", type: :request do
  include ActiveJob::TestHelper

  describe "POST /companies" do
    # 4a: adding reads nothing unless asked.
    it "adds it as the operator, reading nothing, and says it isn't watched until its careers page is found" do
      expect { post companies_path, params: { link: "https://acme.com/careers", name: "Acme" } }
        .to change(Company, :count).by(1).and not_have_enqueued_job(CheckNowJob)

      company = Company.find_by!(domain: "acme.com")
      expect(response).to redirect_to(company_path(company))
      expect(flash[:notice]).to eq("Acme added. Not watched until its careers page is found: check it now, or set it by hand, below.")
      expect(company.check_runs).to be_empty
    end

    it "finds and reads its careers page when asked to (Add and read)" do
      expect { post companies_path, params: { link: "https://acme.com/careers", name: "Acme", read: "1" } }
        .to have_enqueued_job(CheckNowJob)

      company = Company.find_by!(domain: "acme.com")
      expect(flash[:notice]).to eq("Acme added. Finding its careers page and reading its roles now.")
      expect(company.check_runs.sole).to have_attributes(kind: "company", status: "queued", requested_by: "human:operator")
    end

    it "watches it at the careers page given, with no read, and offers both buttons" do
      get companies_path
      expect(response.body).to include("Careers page", "watched as given", %(value="Add"), "Add and read")

      expect { post companies_path, params: { link: "acme.com", careers_page: "acme.com/careers" } }.not_to have_enqueued_job(CheckNowJob)

      company = Company.find_by!(domain: "acme.com")
      expect(company).to have_attributes(careers_page_url: "https://acme.com/careers", resolution_status: "resolved")
      expect(Company.watched).to include(company)
      expect(flash[:notice]).to eq("Acme added. Watched at https://acme.com/careers, as given.")
    end

    it "only shows a company already watched" do
      company = create(:company, :resolved, domain: "acme.com")

      expect { post companies_path, params: { link: "acme.com" } }.not_to have_enqueued_job(CheckNowJob)
      expect(response).to redirect_to(company_path(company))
    end

    it "refuses a job board's link, and adds nothing" do
      expect { post companies_path, params: { link: "https://www.linkedin.com/company/acme" } }.not_to change(Company, :count)

      expect(flash[:alert]).to match(/on linkedin\.com, a job board/)
    end
  end

  describe "PATCH /companies/:id/rename" do
    it "renames it as the operator" do
      company = create(:company, name: "Brasil")

      patch rename_company_path(company), params: { name: "Fabrikam Brasil" }

      expect(company.reload.name).to eq("Fabrikam Brasil")
      expect(AuditEvent.find_by!(target: company).changes_made).to eq("name" => [ "Brasil", "Fabrikam Brasil" ])
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
      expect(AuditEvent.where(target: company).sole.actor).to eq("human:operator")
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

  it "tracks it as the operator's choice and, asked to (Add and check), starts checking it, its own page first" do
    expect { post roles_path, params: { link: "https://jobs.lever.co/acme/0f1e2d3c", title: "Sales Engineer", source: "", check: "1" } }
      .to change(Posting, :count).by(1).and have_enqueued_job(CheckNowJob)

    role = Posting.sole
    expect(response).to redirect_to(role_path(role))
    expect(flash[:notice]).to eq("Acme added. Sales Engineer tracked. Checking it now: its own page first.")
    expect(role.check_runs.sole).to have_attributes(kind: "role", status: "queued")
  end

  it "keeps a job board's link only as where it was found, and says so" do
    post roles_path, params: { link: "https://www.linkedin.com/jobs/view/4099887766", title: "Sales Engineer" }

    expect(response).to redirect_to(roles_path(add: 1))
    expect(flash[:alert]).to match(/on linkedin\.com, a job board/)
    expect(Posting.count).to eq(0)
  end

  it "offers the form on the roles page" do
    get roles_path

    expect(response.body).to include("Add a role", "Where you found it", %(value="Add"), "Add and check")
  end

  # 4a: adding reads nothing unless asked, so without a check the title is needed.
  it "tracks it without a check, reading nothing, and needs its title then" do
    expect { post roles_path, params: { link: "https://jobs.lever.co/acme/0f1e2d3c", title: "Sales Engineer" } }
      .to change(Posting, :count).by(1).and not_have_enqueued_job(CheckNowJob)
    expect(response).to redirect_to(role_path(Posting.sole))
    expect(flash[:notice]).to eq("Acme added. Sales Engineer tracked.")

    expect { post roles_path, params: { link: "https://jobs.lever.co/acme/9a8b7c", title: "" } }.not_to change(Posting, :count)
    expect(response).to redirect_to(roles_path(add: 1))
    expect(flash[:alert]).to eq("Give its title: added without a check, nothing reads one from its page.")
  end

  describe "from a company's page" do
    let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.com") }

    it "adds it there and stays on the company's page; checked, it opens the role's page" do
      get company_path(company)
      expect(response.body).to include("Add a role here", %(name="company_id"), "Add and check").and(not_include("Company <span"))

      post roles_path, params: { link: "https://acme.com/careers/jobs/1", title: "Sales Engineer", company_id: company.id }
      expect(response).to redirect_to(company_path(company))
      expect(company.postings.sole).to have_attributes(role_title: "Sales Engineer", tracking: "tracked")

      post roles_path, params: { link: "https://acme.com/careers/jobs/2", company_id: company.id, check: "1" }
      expect(response).to redirect_to(role_path(company.postings.find_by!(job_url: "https://acme.com/careers/jobs/2")))
    end

    it "is offered only while the company is tracked, and refused at an archived one" do
      Verifier::Tracking.dismiss_company!(company, note: "Pausing.")

      get company_path(company)
      expect(response.body).to include("Track it again to add a role here.").and(not_include("Add a role here"))

      post roles_path, params: { link: "https://acme.com/careers/jobs/1", title: "Sales Engineer", company_id: company.id }
      expect(response).to redirect_to(company_path(company, add_role: 1))
      expect(flash[:alert]).to eq("Acme is archived: track it again before adding a role there.")
    end
  end
end

# 4a: the role's own page at the employer, changed from the role's page.
RSpec.describe "A role's own page", type: :request do
  let(:role) { create(:posting, company: create(:company, :resolved, name: "Acme", domain: "acme.com"), job_url: "https://acme.com/jobs/1") }

  it "is changed from the role's page as the operator, never to a job board's link" do
    get role_path(role)
    expect(response.body).to include("Change its own page", own_page_role_path(role), "set on <a")

    patch own_page_role_path(role), params: { link: "https://acme.com/careers/jobs/1", note: "The old link moved." }
    expect(response).to redirect_to(role_path(role))
    expect(flash[:notice]).to eq("Its own page is now https://acme.com/careers/jobs/1.")
    expect(role.audit_events.sole.reasoning).to eq("Its own page set by hand. The old link moved.")

    patch own_page_role_path(role), params: { link: "https://www.linkedin.com/jobs/view/4099887766" }
    expect(response).to redirect_to(role_path(role, own_page: 1))
    expect(flash[:alert]).to start_with("That link is on linkedin.com, a job board").and end_with("instead.")
    expect(role.reload.job_url).to eq("https://acme.com/careers/jobs/1")
  end
end
