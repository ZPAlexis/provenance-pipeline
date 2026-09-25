class CreateCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :companies, id: :uuid do |t|
      t.string :name, null: false
      t.string :domain
      t.string :careers_page_url
      t.string :ats_type
      t.text :notes

      # Variable enrichment payload. Clay exports carry 7 columns on some pulls
      # and 28 on others; structured core + JSONB avoids a migration every time
      # an upstream source adds a field. Promote a key to a real column once it
      # is filtered or sorted on regularly.
      t.jsonb :enrichment, null: false, default: {}

      t.timestamps
    end

    # Domain is the dedup key — far more reliable than matching display names.
    # Partial index because ~1% of rows arrive without a domain.
    add_index :companies, :domain, unique: true, where: "domain IS NOT NULL"
    add_index :companies, :name
    add_index :companies, :enrichment, using: :gin
  end
end
