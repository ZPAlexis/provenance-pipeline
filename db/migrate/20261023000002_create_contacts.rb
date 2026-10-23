class CreateContacts < ActiveRecord::Migration[8.1]
  def change
    # Stage 2e: the people at a company the operator deals with (a recruiter, a hiring manager, a referrer, an
    # interviewer), linked to any of its applications; an activity can name the one it was with. Other people's
    # personal data: in this database only, never in the repo. Their personal details (name, email, link, notes)
    # are audited as hashes, never as values, so deleting a contact removes it.
    create_table :contacts, id: :uuid do |t|
      t.references :company, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :role # their role there: "Technical Recruiter"
      t.string :kind, null: false, default: "other" # recruiter, hiring_manager, referrer, interviewer, other
      t.string :email
      t.string :linkedin_url
      t.text :notes
      t.timestamps
    end
    add_index :contacts, %i[company_id name]

    create_table :application_contacts, id: :uuid do |t|
      t.references :application, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :contact, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :application_contacts, %i[application_id contact_id], unique: true

    add_reference :activities, :contact, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
