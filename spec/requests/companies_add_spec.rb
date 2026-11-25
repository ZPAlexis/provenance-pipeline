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

  # A record with reads to price a check by: a whole list read by the AI ($0.03), and a careers page found ($0.02).
  def priced
    create(:llm_call, page_check: create(:page_check, purpose: "verification", step: nil), cost_usd: 0.03)
    create(:llm_call, cost_usd: 0.02)
  end

  # 4e, add by link: the link alone; its board watched at once, the role checked right after when that is free.
  it "tracks it as the operator's choice, its board watched at once, and checks it right after when that is free" do
    priced
    expect { post roles_path, params: { link: "https://jobs.lever.co/acme/0f1e2d3c", source: "" } }
      .to change(Posting, :count).by(1).and have_enqueued_job(CheckNowJob).exactly(2).times

    role = Posting.find_by!(job_url: "https://jobs.lever.co/acme/0f1e2d3c")
    expect(response).to redirect_to(role_path(role))
    expect(flash[:notice]).to eq("Acme added. Role tracked: its title is read from its own page. Its board, https://jobs.lever.co/acme, " \
                                 "is watched: read free. Checking it now, free: its company's list first, then its own page.")
    expect(role.company).to have_attributes(resolution_status: "resolved", careers_page_url: "https://jobs.lever.co/acme")
    expect(CheckRun.where(company: role.company).pluck(:kind)).to contain_exactly("company", "role")

    create(:page_check, company: role.company, purpose: "verification", step: nil, read_via: "ats_api") # its list read since
    post roles_path, params: { link: "https://jobs.lever.co/acme/9a8b7c", title: "Solutions Engineer" }
    expect(flash[:notice]).to eq("Solutions Engineer tracked. Checking it now, free.")
  end

  it "leaves a check that could spend to Check now, on its page, which asks first; its title read then" do
    priced

    expect { post roles_path, params: { link: "https://careers.acme.example/jobs/1" } }
      .to change(Posting, :count).by(1).and not_have_enqueued_job(CheckNowJob)

    role = Posting.find_by!(job_url: "https://careers.acme.example/jobs/1")
    expect(response).to redirect_to(role_path(role))
    # Finding its careers page ($0.02), reading it ($0.03), and one AI read to name it from its own page ($0.025).
    expect(flash[:notice]).to eq("Acme added. Role tracked: its title is read from its own page. Not checked: checking it could " \
                                 "cost about $0.075; Check now, on its page, asks first.")
    expect(role).to have_attributes(title_pending?: true, verification_state: "pending")
  end

  it "keeps a job board's link only as where it was found, and keeps the link in the form to correct it" do
    post roles_path, params: { link: "https://www.linkedin.com/jobs/view/4099887766", title: "Sales Engineer" }

    expect(response).to redirect_to(roles_path)
    expect(flash[:alert]).to match(/on linkedin\.com, a job board/)
    expect(Posting.count).to eq(0)
    follow_redirect!
    expect(response.body).to include(%(value="https://www.linkedin.com/jobs/view/4099887766")).and(not_include(%(class="flash link")))
  end

  it "offers the form in the roles page's toolbar, the link first and the rest under More" do
    get roles_path

    expect(response.body).to include("Paste a role&#39;s link", %(value="Add by link"), "More", "Where you found it", "Company website")
      .and(not_include("Add and check"))
  end

  # 4e: an ATS link doesn't name the company's domain; the website given does, and finds the company on record by it.
  it "names a new company by the website given, and finds one on record by it" do
    post roles_path, params: { link: "https://job-boards.greenhouse.io/acmeinc/jobs/4012345", website: "https://www.acme.example/" }
    expect(Company.sole).to have_attributes(name: "Acme", domain: "acme.example", careers_page_url: "https://job-boards.greenhouse.io/acmeinc")

    post roles_path, params: { link: "https://job-boards.greenhouse.io/acmeinc/jobs/4012399", website: "acme.example" }
    expect(Company.count).to eq(1)
    expect(Company.sole.postings.count).to eq(2)
  end

  describe "from a company's page" do
    let(:company) { create(:company, :resolved, name: "Acme", domain: "acme.com") }

    it "adds it there and stays on the company's page, checked right after when that is free" do
      get company_path(company)
      expect(response.body).to include("Its page at Acme, or its ATS posting", %(name="company_id"), %(value="Add"))
        .and(not_include("Company website"))

      post roles_path, params: { link: "https://acme.com/careers/jobs/1", title: "Sales Engineer", company_id: company.id }
      expect(response).to redirect_to(company_path(company))
      expect(company.postings.sole).to have_attributes(role_title: "Sales Engineer", tracking: "tracked")
      expect(flash[:notice]).to start_with("Sales Engineer tracked. Not checked: checking it could cost")
    end

    it "is offered only while the company is tracked, and refused at an archived one" do
      Verifier::Tracking.dismiss_company!(company, note: "Pausing.")

      get company_path(company)
      expect(response.body).to include("Track it again to add a role here.").and(not_include(%(name="company_id")))

      post roles_path, params: { link: "https://acme.com/careers/jobs/1", title: "Sales Engineer", company_id: company.id }
      expect(response).to redirect_to(company_path(company))
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
