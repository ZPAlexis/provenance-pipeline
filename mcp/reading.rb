module ProvenanceMcp
  # How the operator's own AI assistant reads a careers page a free check left unread (4f step 3): by the rules the
  # app's own reader (the worker's extractor) keeps, read from the one file both share, so either reads a page alike.
  module Reading
    RULES_FILE = File.expand_path("../workers/verifier/src/verifier/reading_rules.md", __dir__)

    module_function

    # The rules, word for word as the extractor's prompt: what follows the file's `---` line.
    def rules = @rules ||= File.read(RULES_FILE, encoding: "utf-8").split("\n---\n", 2).last.strip
  end
end
