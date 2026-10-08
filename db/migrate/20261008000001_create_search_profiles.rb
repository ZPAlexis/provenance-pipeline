class CreateSearchProfiles < ActiveRecord::Migration[8.1]
  def change
    # What the operator is looking for: the roles on watched pages that fit it are
    # suggested (1.5c). One is edited on the Profile page for now; the table holds
    # more for later. Any agent weighing a role against it (a fit scorer, a cover
    # letter drafter) reads it from here, and weighs through the worker's `suggest`.
    create_table :search_profiles, id: :uuid do |t|
      t.string :name, null: false
      t.string :titles, array: true, null: false, default: [] # every word of one, in any order
      t.string :excluded_words, array: true, null: false, default: [] # every word of one rules a title out
      t.string :places, array: true, null: false, default: [] # where the operator can work: countries, regions, cities
      t.string :work_modes, array: true, null: false, default: [] # remote | hybrid | onsite; none = any
      t.string :levels, array: true, null: false, default: [] # entry | senior | lead | director | executive; none = any
      t.timestamps
    end
  end
end
