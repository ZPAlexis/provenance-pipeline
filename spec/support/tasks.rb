require "rake"

# The rake commands, run as the operator runs them (review pass R8): the tasks loaded once, each run afresh with the
# environment variables given for that run alone, what it prints kept, and an abort kept as the message it gave.
module TaskHelpers
  Ran = Data.define(:out, :aborted)

  def run_task(name, *args, **env)
    Rails.application.load_tasks unless Rake::Task.task_defined?("verifier:status")
    out, err = StringIO.new, StringIO.new
    aborted = nil
    printing = [ $stdout, $stderr ]
    with_env(env.to_h { |key, value| [ key.to_s, value&.to_s ] }) do
      $stdout, $stderr = out, err
      Rake::Task[name].reenable
      Rake::Task[name].invoke(*args)
    rescue SystemExit
      aborted = err.string.strip
    ensure
      $stdout, $stderr = printing
    end
    Ran.new(out: out.string, aborted: aborted)
  end

  def with_env(vars)
    before = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    before.each { |key, value| ENV[key] = value }
  end
end

RSpec.configure do |config|
  config.include TaskHelpers, type: :task
  config.define_derived_metadata(file_path: %r{/spec/tasks/}) { |metadata| metadata[:type] = :task }
  # A command that writes backs up first: here, a stand-in for the dump, which the backups spec proves.
  config.before(type: :task) { allow(DatabaseBackup).to receive(:call).and_return(Rails.root.join("tmp/backups/stand-in.dump")) }
end
