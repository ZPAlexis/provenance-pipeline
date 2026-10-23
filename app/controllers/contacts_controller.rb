# A company's contacts (Stage 2e), on its page: added, edited, and deleted by the operator, through Contacts.
class ContactsController < ApplicationController
  before_action { @company = Company.find(params[:company_id]) }
  before_action(except: :create) { @contact = @company.contacts.find(params[:id]) }

  def create
    contact = Contacts.save!(@company, fields)
    back(notice: "#{contact.name} added.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    back(alert: "Not added: #{e.message}.")
  end

  def update
    Contacts.save!(@company, fields, contact: @contact)
    back(notice: "#{@contact.name} saved.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    back(alert: "Not saved: #{e.message}.")
  end

  def destroy
    Contacts.delete!(@contact)
    back(notice: "#{@contact.name} deleted.")
  end

  private

  def fields = params.permit(*Contacts::FIELDS).to_h

  def back(**flash) = redirect_to(company_path(@company, anchor: "contacts"), status: :see_other, **flash)
end
