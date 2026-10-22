# Finding records by words as typed, case and accents set aside ("sao paulo"
# finds "São Paulo"): each word must appear in one of the columns given. Folded
# with Postgres's own translate(), so no extension is needed.
module Searchable
  FROM = "áàâãäåéèêëíìîïóòôõöúùûüçñ".freeze
  TO = "aaaaaaeeeeiiiiooooouuuucn".freeze

  module_function

  # The words typed, folded as the columns are; none for a blank search. A word of punctuation alone ("/", "-")
  # is no word: "Acme / Sales Engineer" finds what "Acme Sales Engineer" does.
  def words(text) = text.to_s.downcase.tr(FROM, TO).split.grep(/[[:alnum:]]/).uniq.first(8)

  def folded(column) = "translate(lower(coalesce(#{column}, '')), '#{FROM}', '#{TO}')"

  # `scope` narrowed to records where every word appears in one of `columns` (SQL expressions of this code's own).
  def narrow(scope, text, columns)
    words(text).reduce(scope) do |narrowed, word|
      narrowed.where(columns.map { |column| "#{folded(column)} LIKE :word" }.join(" OR "),
                     word: "%#{ActiveRecord::Base.sanitize_sql_like(word)}%")
    end
  end
end
