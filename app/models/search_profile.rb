# What the operator is looking for. A role on a watched page fits when its title
# holds every word of one of `titles`, in any order, and every word of none of
# `excluded_words`; it is open to one of `places`, where the operator can work (a
# role in São Paulo, or open to Latin America, is open to Brazil); and its work mode
# and the level its title states are among those sought (none sought = any). What
# a role does not state fits, marked. The rules run in the worker
# (workers/verifier/src/verifier/profiles.py), so every agent weighs roles alike.
class SearchProfile < ApplicationRecord
  WORK_MODES = %w[remote hybrid onsite].freeze
  # Mirrors workers/verifier/src/verifier/titles.py LEVELS, lowest to highest.
  LEVELS = %w[entry senior lead director executive].freeze
  LISTS = %i[titles excluded_words places].freeze

  # What the operator wants of a company (4b), beside what they look for in a role: what they want and what they avoid,
  # in their own words, and lists the pages filter on without AI. A company review is read against these and the
  # places (where a company hires, against where the operator can work), and goes stale when they change.
  COMPANY_STAGES = { "pre_seed" => "Pre-seed", "seed" => "Seed", "series_a" => "Series A", "series_b" => "Series B",
                     "series_c_plus" => "Series C or later", "public" => "Public", "private" => "Privately held",
                     "bootstrapped" => "Bootstrapped" }.freeze
  COMPANY_SIZES = %w[1-10 11-50 51-200 201-500 501-1000 1001-5000 5001+].freeze
  COMPANY_MODELS = { "b2b" => "B2B", "b2c" => "B2C", "b2b2c" => "B2B2C" }.freeze
  # Industries, and the words of what to avoid (an industry, a kind of product): in the operator's own words, one per line.
  COMPANY_WORDS = %i[company_industries company_excluded].freeze
  COMPANY_PREFERENCES = %w[company_wants company_avoids company_stages company_sizes company_models company_industries
                           company_excluded].freeze

  attribute :name, :string, default: "Main"

  # The operator's resume, version by version (2b): kept through Resumes, never in the repo.
  has_many :resumes, dependent: nil # the key cascades
  # Their background beyond the resume, in three parts, version by version (4c): kept through Backgrounds, never in the repo.
  has_many :backgrounds, dependent: nil # the key cascades

  validates :name, presence: true
  validates :titles, presence: { message: "need at least one: a role fits when its title holds every word of one" }
  validate :known_values

  # Trimmed, blanks dropped, each once whatever its case.
  normalizes(*LISTS, with: ->(list) { Array(list).map(&:squish).compact_blank.uniq(&:downcase) })
  normalizes :work_modes, :levels, with: ->(list) { Array(list).compact_blank.uniq }
  normalizes(*COMPANY_WORDS, with: ->(list) { Array(list).map(&:squish).compact_blank.uniq(&:downcase) })
  normalizes :company_stages, :company_sizes, :company_models, with: ->(list) { Array(list).map { |each| each.to_s.strip }.compact_blank.uniq }
  # A browser sends a textarea's line breaks as CRLF: kept as LF, so the same words digest alike from the page or a command.
  normalizes :company_wants, :company_avoids, with: ->(text) { text.to_s.gsub("\r\n", "\n").strip.presence }

  # The one profile edited on the Profile page.
  def self.current = order(:created_at).first

  # One per line on the page.
  [ *LISTS, *COMPANY_WORDS ].each do |list|
    define_method(:"#{list}_text") { public_send(list).join("\n") }
    define_method(:"#{list}_text=") { |text| public_send(:"#{list}=", text.to_s.lines) }
  end

  # Whether the operator has said anything of the companies they want: a company review needs something to weigh.
  def company_preferences? = COMPANY_PREFERENCES.any? { |field| public_send(field).present? }

  # What a company review is read against, as one digest: the company preferences and the places. A review whose digest
  # differs is stale.
  def company_preferences_digest
    said = COMPANY_PREFERENCES.to_h { |field| [ field, public_send(field) ] }.merge("places" => places)
    sorted = said.transform_values { |value| value.is_a?(Array) ? value.map(&:downcase).sort : value }
    "sha256:#{Digest::SHA256.hexdigest(sorted.to_json)}"
  end

  # A short name for it, from its digest: what a client that read the preferences gives back when it saves a review.
  def company_preferences_version = company_preferences_digest.delete_prefix("sha256:")[0, 12]

  # As the worker reads it (workers/verifier/src/verifier/contract.py SearchProfile).
  def to_worker
    { titles: titles, excluded: excluded_words, places: places, work_modes: work_modes, levels: levels }
  end

  private

  def known_values
    errors.add(:work_modes, "can only be #{WORK_MODES.to_sentence(last_word_connector: ', or ')}") if (work_modes - WORK_MODES).any?
    errors.add(:levels, "can only be #{LEVELS.to_sentence(last_word_connector: ', or ')}") if (levels - LEVELS).any?
    { company_stages: COMPANY_STAGES.keys, company_sizes: COMPANY_SIZES, company_models: COMPANY_MODELS.keys }.each do |field, known|
      errors.add(field, "can only be #{known.to_sentence(last_word_connector: ', or ')}") if (public_send(field) - known).any?
    end
  end
end
