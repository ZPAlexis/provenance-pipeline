# A contact linked to an application (Stage 2e): someone at the application's own company.
class ApplicationContact < ApplicationRecord
  belongs_to :application
  belongs_to :contact

  validates :contact_id, uniqueness: { scope: :application_id, message: "is already linked to it" }
  validate :at_the_applications_company

  private

  def at_the_applications_company
    errors.add(:contact, "must be at the application's company") if contact && application && contact.company_id != application.company_id
  end
end
