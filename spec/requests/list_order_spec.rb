require "rails_helper"

# The lists' default order (4e step 5): what you are applying to first, the furthest along first; then what has no
# application; then what has a closed one; within each the best fit first (the Companies page: then the most roles
# tracked), then the most recently checked. The Roles table shows each role's application, and says when it was
# checked and where its own page is in a few characters.
RSpec.describe "The lists' default order", type: :request do
  let!(:profile) { SearchProfile.create!(titles: [ "Sales Engineer" ]) }
  let!(:resume) { Resumes.keep!(profile, text: "Jordan Sample\nSales engineer.") }

  def role(company, title, fit: nil, stage: nil, checked: 3.days.ago)
    posting = create(:posting, :verified_live, company: company, role_title: title, tracking: "tracked", last_checked_at: checked,
                                               job_url: "https://job-boards.greenhouse.io/#{company.name.downcase}/jobs/#{title.length}")
    if fit
      text = "#{title}: discovery."
      description = posting.role_descriptions.create!(text: text, content_hash: Resume.digest(text), read_via: "render", run_id: "r1",
                                                      url: posting.job_url, first_read_at: 1.day.ago, last_read_at: 1.day.ago)
      Authority.unchecked do
        posting.fit_scores.create!(score: fit, why: "Weighed.", resume: resume, resume_hash: resume.content_hash, role_description: description,
                                   description_hash: description.content_hash, written_by: "agent:assistant")
      end
    end
    create(:application, posting: posting, stage: stage) if stage
    posting
  end

  it "orders the roles by application, then fit, then last checked, and shows each one's application" do
    acme = create(:company, :resolved, name: "Acme", domain: "acme.example")
    role(acme, "No application, fit 90", fit: 90)
    role(acme, "Interviewing, fit 60", fit: 60, stage: "interviewing")
    role(acme, "Applied, fit 80", fit: 80, stage: "applied")
    role(acme, "Rejected, fit 95", fit: 95, stage: "rejected")
    role(acme, "No application, fit 70, checked now", fit: 70, checked: 1.hour.ago)
    role(acme, "No application, fit 70, checked before", fit: 70, checked: 9.days.ago)
    role(acme, "No application, not weighed")

    get roles_path

    titles = response.body.scan(/<a href="\/roles\/[^"]+">([^<]+)<\/a>/).flatten
    expect(titles).to eq([ "Interviewing, fit 60", "Applied, fit 80", "No application, fit 90", "No application, fit 70, checked now",
                           "No application, fit 70, checked before", "No application, not weighed", "Rejected, fit 95" ])
    expect(response.body).to include(">Interviewing</span></a>", ">9d</time>", "greenhouse.io ↗", "<th>Application</th>")

    get roles_path(sort: "name")
    expect(response.body.scan(/<a href="\/roles\/[^"]+">([^<]+)<\/a>/).flatten.first).to eq("Applied, fit 80")
  end

  it "orders the companies by application, then fit, then roles tracked, then last checked" do
    applying = create(:company, :resolved, name: "Contoso", domain: "contoso.example")
    role(applying, "Solutions Engineer", stage: "applied")
    best = create(:company, :resolved, name: "Fabrikam", domain: "fabrikam.example")
    create(:company_review, company: best, score: 88)
    two = create(:company, :resolved, name: "Litware", domain: "litware.example")
    create(:company_review, company: two, score: 70)
    2.times { |n| role(two, "Role #{n}") }
    one = create(:company, :resolved, name: "Northwind", domain: "northwind.example")
    create(:company_review, company: one, score: 70)
    role(one, "Role A")
    closed = create(:company, :resolved, name: "Adatum", domain: "adatum.example")
    role(closed, "Gone", stage: "withdrawn")

    get companies_path

    names = response.body.scan(/<a href="\/companies\/[^"]+">([^<]+)<\/a>/).flatten
    expect(names).to eq(%w[Contoso Fabrikam Litware Northwind Adatum])
  end
end
