namespace :agents do
  desc "The credentials agent runs were issued, newest first, with what each wrote and was refused, then the latest " \
       "refused writes. [ACTOR=agent:verifier] [LIMIT=20]"
  task credentials: :environment do
    actor = ENV["ACTOR"].presence
    abort "ACTOR is one of: #{Authority::AGENTS.keys.join(', ')}." if actor && !Authority::AGENTS.key?(actor)

    credentials = AgentCredential.newest_first.limit((ENV["LIMIT"].presence || 20).to_i)
    credentials = credentials.where(actor: actor) if actor
    abort "No credential issued yet#{" to #{actor}" if actor}: one is issued with each run." if credentials.empty?

    ids = credentials.map(&:id)
    wrote = AuditEvent.where(credential_id: ids).where.not(action: "denied").group(:credential_id).count
    refused = AuditEvent.denied.where(credential_id: ids).group(:credential_id).count
    credentials.each do |credential|
      puts format("%s  %-8s %-17s %-48s wrote %3d  refused %d  [%s]", credential.id, credential.status, credential.actor,
                  credential.purpose.truncate(48), wrote.fetch(credential.id, 0), refused.fetch(credential.id, 0),
                  credential.scopes.join(", "))
      puts "    issued #{credential.created_at.utc.strftime('%Y-%m-%d %H:%M')} UTC, expires #{credential.expires_at.utc.strftime('%Y-%m-%d %H:%M')} UTC"
    end

    denied = AuditEvent.denied.order(occurred_at: :desc).limit(10)
    puts "\nRefused writes: #{AuditEvent.denied.count}#{' (the latest 10)' if AuditEvent.denied.count > 10}"
    denied.each do |event|
      puts "  #{event.occurred_at.utc.strftime('%Y-%m-%d %H:%M')}  #{event.actor}: #{event.reasoning.to_s.delete_prefix('Denied: ')}"
    end
  end

  desc "Revoke a credential while its run is going: the run's next write is refused. Audited as you; backs up first. " \
       "Usage: [NOTE=\"why\"] bin/rails \"agents:revoke[credential_id]\""
  task :revoke, [ :id ] => :environment do |_task, args|
    credential = AgentCredential.find_by(id: args[:id]) or abort "No credential #{args[:id].inspect}: see agents:credentials."
    abort "It is already #{credential.status}." unless credential.status == "active"

    puts "Backed up to #{DatabaseBackup.call}"
    credential.revoke_by!(AuditEvent::OPERATOR, note: ENV["NOTE"])
    puts "Revoked #{credential.actor}'s credential for #{credential.purpose}: its run's next write is refused."
  end
end
