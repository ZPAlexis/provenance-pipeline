module Verifier
  # A careers page a free check left unread, opened for the operator's own AI assistant to read (4f): by the verifier,
  # under its own credential for this one read, the assistant named as who asked. The worker runs with no API key, so
  # nothing here can reach the AI; the page is kept (PageRender) as the extractor would have seen it, for what the
  # assistant saves of it to be checked against.
  module PageRenders
    SCOPES = %w[evidence:write].freeze

    Opened = Data.define(:render, :outcome, :reason)

    module_function

    # Opens the page `page_check` left unread. Returns Opened: the render when the page opened, or why it didn't.
    def open!(page_check, issued_by:, worker: Worker.new(run_dir: Worker.dir_for("read"), free: true))
      company = page_check.company
      Authority.run(Ingest::ACTOR, scopes: SCOPES, purpose: "read for the AI assistant: #{company.name}'s careers page",
                                   issued_by:) do
        run = worker.run([ { id: company.id, url: page_check.url, label: company.name } ], command: "read")
        result = run.results.first or raise Worker::Error, (run.stopped || "the page was not opened")
        Opened.new(render: Ingest.new(run_id: run.id).render(result, company:, page_check:), outcome: result["outcome"],
                   reason: result["reason"])
      end
    end

    # The newest render of the page `page_check` left unread, to read on from, or nil.
    def newest(page_check) = page_check.page_renders.newest_first.first
  end
end
