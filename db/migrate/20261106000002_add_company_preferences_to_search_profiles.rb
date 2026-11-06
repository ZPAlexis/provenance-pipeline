class AddCompanyPreferencesToSearchProfiles < ActiveRecord::Migration[8.1]
  def change
    # 4b: what the operator wants of a company, beside what they look for in a role. Two texts carry the nuance (what
    # they want, what they avoid: products, markets, values, a stance); lists let the pages filter without AI: stage,
    # size, business model, industries, and words to avoid. The texts and the avoid list are the operator's own
    # business: in this database only, and audited by a hash alone.
    change_table :search_profiles, bulk: true do |t|
      t.text :company_wants
      t.text :company_avoids
      t.string :company_stages, array: true, default: [], null: false
      t.string :company_sizes, array: true, default: [], null: false
      t.string :company_models, array: true, default: [], null: false
      t.string :company_industries, array: true, default: [], null: false
      t.string :company_excluded, array: true, default: [], null: false
    end
  end
end
