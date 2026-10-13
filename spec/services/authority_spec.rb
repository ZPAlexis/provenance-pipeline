require "rails_helper"

RSpec.describe Authority do
  let!(:company) { create(:company, :resolved, name: "Acme", domain: "acme.example") }
  let!(:role) { create(:posting, company: company, role_title: "Sales Engineer", tracking: "tracked") }

  def verifier(scopes: %w[postings:verify evidence:write], &block) = as_agent("agent:verifier", scopes: scopes, &block)
  def suggester(&block) = as_agent("agent:suggester", &block)
  def denial = AuditEvent.denied.sole

  describe "a run's credential" do
    it "is issued with exactly the run's scopes, keeps only a digest of its token, and is revoked when the run ends" do
      issued = nil
      token_seen = nil
      described_class.run("agent:verifier", scopes: %w[postings:verify], purpose: "verifier:verify") do |credential|
        issued = credential
        token_seen = AgentCredential.authenticate("ppa_not-a-token")
      end

      expect(issued.reload).to have_attributes(actor: "agent:verifier", scopes: %w[postings:verify], purpose: "verifier:verify",
                                        issued_by: "human:operator", status: "revoked")
      expect(issued.token_digest).to match(/\A\h{64}\z/)
      expect(token_seen).to be_nil
      expect(issued.expires_at).to be_within(1.minute).of(1.hour.from_now)
    end

    it "never holds a scope its agent may not" do
      expect { described_class.run("agent:suggester", scopes: %w[postings:verify], purpose: "x") { nil } }
        .to raise_error(ActiveRecord::RecordInvalid, /beyond what agent:suggester may hold: postings:verify/)
    end

    it "is refused once expired or revoked, and the refusal is on the record" do
      credential, token = AgentCredential.issue!(actor: "agent:verifier", scopes: %w[postings:verify], purpose: "x",
                                                 ttl: 1.hour, issued_by: "human:operator")

      travel 2.hours do
        expect { described_class.presenting(token) { nil } }.to raise_error(described_class::Denied, /expired/)
      end
      expect(denial).to have_attributes(actor: "agent:verifier", credential: credential, reasoning: /Denied: its credential expired/)

      credential.revoke!
      expect { described_class.presenting(token) { nil } }.to raise_error(described_class::Denied, /revoked/)
    end

    it "stops a run's writes the moment it is revoked, wherever from" do
      expect do
        verifier do |credential|
          AgentCredential.where(id: credential.id).update_all(revoked_at: Time.current) # the Agents page, say
          role.update!(verification_state: "verified_live", last_checked_at: Time.current)
        end
      end.to raise_error(described_class::Denied, /credential was revoked/)
      expect(role.reload.verification_state).to eq("pending")
    end

    it "can't be issued by an agent" do
      expect { verifier { described_class.run("agent:suggester", scopes: %w[postings:suggest], purpose: "x") { nil } } }
        .to raise_error(described_class::Denied, /an agent can't issue a credential/)
      expect(AgentCredential.where(actor: "agent:suggester")).to be_empty
    end
  end

  describe "the verifier" do
    it "writes a verdict under its credential, which every event it writes names" do
      verifier do |credential|
        role.update!(verification_state: "not_found", last_checked_at: Time.current, roles_listed_count: 12)
        AuditEvent.record_write!(role, actor: "agent:verifier", reasoning: "Not among the 12 roles listed.")
        expect(AuditEvent.find_by!(target: role, action: "update").credential).to eq(credential)
      end
    end

    it "never tracks or dismisses a role: refused, and the refusal kept though its transaction rolled back" do
      expect do
        verifier { ApplicationRecord.transaction { role.update!(tracking: "dismissed", work_mode: "remote") } }
      end.to raise_error(described_class::Denied, /may not update a posting \(tracking, work_mode\) with postings:verify/)

      expect(role.reload).to have_attributes(tracking: "tracked", work_mode: nil)
      expect(denial).to have_attributes(actor: "agent:verifier", target: role, credential: AgentCredential.sole,
                                        changes_made: { "tracking" => %w[tracked dismissed], "work_mode" => [ nil, "remote" ] })
    end

    it "writes only what its run was issued for: a run finding careers pages writes no verdict" do
      expect { verifier(scopes: %w[companies:enrich evidence:write]) { role.update!(verification_state: "not_found", last_checked_at: Time.current) } }
        .to raise_error(described_class::Denied, /with companies:enrich, evidence:write/)
      expect { verifier { company.update!(careers_page_url: "https://acme.example/jobs") } }
        .to raise_error(described_class::Denied, /may not update a company/)
    end

    it "names a role from its page only while its title is pending" do
      pending_title = create(:posting, company: company, role_title: Posting::TITLE_PENDING)

      verifier { pending_title.update!(role_title: "Sales Engineer", location: "Remote") }
      expect { verifier { role.update!(role_title: "Something else") } }.to raise_error(described_class::Denied)
    end
  end

  describe "the suggester" do
    it "proposes a role, refits it and withdraws it while it is a suggestion, and nothing more" do
      suggested = suggester { company.postings.create!(role_title: "Solutions Engineer", tracking: "suggested", fit: { "title" => "x" }) }
      suggester { suggested.update!(fit: { "title" => "y" }) }

      expect { suggester { company.postings.create!(role_title: "Sales Engineer II", tracking: "tracked") } }
        .to raise_error(described_class::Denied)
      expect { suggester { suggested.update!(tracking: "tracked") } }.to raise_error(described_class::Denied, /\(tracking\)/)
      expect { suggester { role.update!(fit: { "title" => "z" }) } }.to raise_error(described_class::Denied)
      expect { suggester { role.destroy! } }.to raise_error(described_class::Denied, /may not destroy a posting/)

      suggester { suggested.destroy! }
      expect(Posting.exists?(suggested.id)).to be(false)
      expect(role.reload).to be_persisted
    end
  end

  describe "agent services" do
    it "refuse to start without their own agent's credential" do
      expect { Verifier::Ingest.new(run_id: "r1") }.to raise_error(described_class::Denied, /none was presented/)
      expect { suggester { Verifier::Ingest.new(run_id: "r1") } }.to raise_error(described_class::Denied, /not agent:suggester's/)
      expect(AuditEvent.denied.pluck(:actor)).to eq(%w[agent:verifier agent:verifier])
    end
  end

  describe "the audit log" do
    it "takes an event in an agent's name only under that agent's credential" do
      expect { AuditEvent.record!(actor: "agent:verifier", action: "update", target: role) }
        .to raise_error(described_class::Denied, /needs agent:verifier's credential, and none was presented/)
      expect { suggester { AuditEvent.record!(actor: "agent:verifier", action: "update", target: role) } }
        .to raise_error(described_class::Denied, /not agent:suggester's/)
    end

    it "is append-only, for the operator too" do
      event = AuditEvent.record!(actor: "human:operator", action: "update", target: role, reasoning: "Tracked by hand.")

      expect { event.update!(reasoning: "Something else.") }.to raise_error(described_class::Denied, /append-only/)
      expect { event.destroy! }.to raise_error(described_class::Denied, /append-only/)
      expect(event.reload.reasoning).to eq("Tracked by hand.")
    end
  end

  describe "the review queue's grant" do
    it "keeps review items, and writes nothing else" do
      expect { described_class.as_system("system:review_queue") { company.update!(name: "Other") } }
        .to raise_error(described_class::Denied, /system:review_queue: may not update a company \(name\) with review:keep/)
    end
  end

  it "leaves the operator's own writes unchecked until a login exists" do
    role.update!(tracking: "dismissed")
    AuditEvent.record_write!(role, actor: "human:operator", reasoning: "Dismissed by hand.")

    expect(AuditEvent.denied).to be_empty
  end

  describe "a refusal inside a run's real transaction" do
    self.use_transactional_tests = false

    after do
      [ AuditEvent, AgentCredential, Posting, Company ].each(&:delete_all) # past the guard, as a test's own cleanup
    end

    it "is kept when the transaction it stopped rolls back" do
      expect do
        verifier { ApplicationRecord.transaction { role.update!(tracking: "dismissed") } }
      end.to raise_error(described_class::Denied)

      expect(AuditEvent.denied.sole).to have_attributes(actor: "agent:verifier", target: role)
      expect(AgentCredential.sole.status).to eq("revoked")
    end
  end
end
