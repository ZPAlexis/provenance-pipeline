require "rails_helper"

# The target list is private: no company on the record may be named in the repo (review pass R10 and R11). Made-up
# companies stand in for the record here.
RSpec.describe NameGuard do
  def guard(words: [], allowed: {}) = described_class.new(names: [ "Initech", "Harbor", "Hooli", "Vox" ], domains: [ "initech.com", "acme.example" ],
                                                         words: words, allowed: allowed)

  def named(texts, **options) = guard(**options).findings(texts).map { |finding| [ finding.where, finding.line, *finding.names ] }

  it "finds a company by name in any case, as a whole word, and a short one only as written" do
    texts = { "app/a.rb" => "# Found with Initech: its board.\nhooli's page\nInitechnology isn't it\n",
              "app/b.rb" => "Vox and vox, but not app/vox/ nor voxel" }

    expect(named(texts)).to eq([ [ "app/a.rb", 1, "Initech" ], [ "app/a.rb", 2, "Hooli" ], [ "app/b.rb", 1, "Vox" ] ])
  end

  it "finds a domain, its subdomains too (and the name in it), and never a made-up .example one" do
    texts = { "spec/c.rb" => "https://careers.initech.com/jobs\nhttps://acme.example/jobs\nnotinitech.com\n" }

    expect(named(texts)).to eq([ [ "spec/c.rb", 1, "Initech", "initech.com" ] ])
  end

  # Found in R10: the first scan passed over the names that are also words, and missed one written as a company's.
  it "checks a name that is also a word as written: the word passes, the company doesn't" do
    texts = { "tests/t.py" => "# the harbor of roles\n# Harbor and Initech each have a board\n" }

    expect(named(texts, words: [ "Harbor" ])).to eq([ [ "tests/t.py", 2, "Initech", "Harbor" ] ])
    expect(named(texts)).to include([ "tests/t.py", 1, "Harbor" ])
  end

  it "allows a name where it may appear: by path, dotfiles too, or anywhere, commit messages included" do
    texts = { ".gitignore" => "Initech\n", "lib/x.rb" => "Initech\n", "app/y.rb" => "Hooli\n", "commit abc1234" => "Hooli in a message\n" }

    expect(named(texts, allowed: { "Initech" => [ "*" ], "Hooli" => [ "app/**" ] })).to eq([ [ "commit abc1234", 1, "Hooli" ] ])
  end

  it "reads the repo's files, tracked and new, and its commits on no remote yet, leaving out ignored and generated files" do
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      git = ->(*args) { system("git", "-C", dir, "-c", "user.email=spec@acme.example", "-c", "user.name=spec", *args, out: File::NULL, err: File::NULL) }
      git.("init", "-q")
      root.join(".gitignore").write("tmp/\n")
      root.join("a.rb").write("tracked")
      git.("add", ".")
      git.("commit", "-q", "-m", "A message naming Initech")
      root.join("new.rb").write("not added yet")
      root.join("Gemfile.lock").write("generated")
      root.join("tmp").mkpath
      root.join("tmp/x.rb").write("ignored")

      texts = described_class.repo_texts(root)

      expect(texts.keys).to contain_exactly(".gitignore", "a.rb", "new.rb", a_string_matching(/\Acommit \h{7,}\z/))
      expect(texts.values).to include("not added yet", a_string_including("A message naming Initech"))
    end
  end
end
