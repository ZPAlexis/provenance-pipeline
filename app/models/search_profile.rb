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

  attribute :name, :string, default: "Main"

  validates :name, presence: true
  validates :titles, presence: { message: "need at least one: a role fits when its title holds every word of one" }
  validate :known_values

  # Trimmed, blanks dropped, each once whatever its case.
  normalizes(*LISTS, with: ->(list) { Array(list).map(&:squish).compact_blank.uniq(&:downcase) })
  normalizes :work_modes, :levels, with: ->(list) { Array(list).compact_blank.uniq }

  # The one profile edited on the Profile page.
  def self.current = order(:created_at).first

  # One per line on the page.
  LISTS.each do |list|
    define_method(:"#{list}_text") { public_send(list).join("\n") }
    define_method(:"#{list}_text=") { |text| public_send(:"#{list}=", text.to_s.lines) }
  end

  # As the worker reads it (workers/verifier/src/verifier/contract.py SearchProfile).
  def to_worker
    { titles: titles, excluded: excluded_words, places: places, work_modes: work_modes, levels: levels }
  end

  private

  def known_values
    errors.add(:work_modes, "can only be #{WORK_MODES.to_sentence(last_word_connector: ', or ')}") if (work_modes - WORK_MODES).any?
    errors.add(:levels, "can only be #{LEVELS.to_sentence(last_word_connector: ', or ')}") if (levels - LEVELS).any?
  end
end
