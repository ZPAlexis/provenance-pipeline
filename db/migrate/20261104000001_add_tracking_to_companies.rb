class AddTrackingToCompanies < ActiveRecord::Migration[8.1]
  def change
    # 4a: a company is tracked or archived by the operator, as a role is, and watched only while tracked. Every company
    # on record starts tracked. "dismissed" is the stored word for archived, as it is for roles.
    add_column :companies, :tracking, :string, null: false, default: "tracked"
    add_index :companies, :tracking
  end
end
