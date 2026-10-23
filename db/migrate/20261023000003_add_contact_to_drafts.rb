class AddContactToDrafts < ActiveRecord::Migration[8.1]
  def change
    # Stage 2e step 3: the person an outreach note is addressed to, one of the company's contacts. A deleted
    # contact leaves the note as it was written, addressed to no one on record.
    add_reference :drafts, :contact, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
