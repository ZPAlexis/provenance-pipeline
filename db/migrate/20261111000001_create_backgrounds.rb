# The operator's background beyond the resume (4c), kept with the search profile version by version, as the resume is:
# three parts, each read only by what may use it, and a hash of each, so a reader records the hash of what it read.
class CreateBackgrounds < ActiveRecord::Migration[8.1]
  def change
    create_table :backgrounds, id: :uuid do |t|
      t.references :search_profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :looking_for
      t.text :role_preferences
      t.text :not_on_resume
      t.string :looking_for_hash
      t.string :role_preferences_hash
      t.string :not_on_resume_hash
      t.string :content_hash, null: false
      t.timestamps
    end
    add_index :backgrounds, %i[search_profile_id created_at]
  end
end
