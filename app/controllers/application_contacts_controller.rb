# An application's contacts (Stage 2e): one of its company's linked to it, a new one added at the company and
# linked, or one unlinked (it stays with the company). The operator's, through Contacts.
class ApplicationContactsController < ApplicationController
  before_action { @application = Application.includes(:company).find(params[:application_id]) }

  def create
    company = @application.company
    contact = if params[:contact_id].present?
      company.contacts.find(params[:contact_id]).tap { |found| Contacts.link!(found, @application) }
    else
      Contacts.save!(company, params.permit(*Contacts::FIELDS).to_h, application: @application)
    end
    back(notice: "#{contact.name} linked.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    back(alert: "Not linked: #{e.message}.")
  end

  def destroy
    contact = @application.contacts.find(params[:id])
    Contacts.unlink!(contact, @application)
    back(notice: "#{contact.name} unlinked; they stay with #{@application.company.name}.")
  end

  private

  # Back to the application: its page keeps the reader's place.
  def back(**flash) = redirect_to(application_path(@application), status: :see_other, **flash)
end
