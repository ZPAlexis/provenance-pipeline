class AddBoardsAndReusedReads < ActiveRecord::Migration[8.1]
  def change
    # A free ATS board found to list the same roles as the watched page, by role
    # overlap: verification reads it through its API in place of the page, which
    # stays the page on record. Who owns the board is in the evidence, not required.
    change_table :companies, bulk: true do |t|
      t.string :board_vendor
      t.string :board_token
      t.decimal :board_overlap, precision: 4, scale: 3
      t.text :board_evidence
      t.datetime :board_confirmed_at
    end

    # A check whose page linked to exactly the role pages it did before reuses
    # that read's listings instead of paying the LLM again: the read it reused,
    # and when the listings were last actually read (the 14-day valve runs on it).
    add_reference :page_checks, :reused_from, type: :uuid, index: true,
                                              foreign_key: { to_table: :page_checks, on_delete: :nullify }
    add_column :page_checks, :listings_read_at, :datetime
  end
end
