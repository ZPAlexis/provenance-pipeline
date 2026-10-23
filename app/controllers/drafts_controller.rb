# An application's drafts (Stage 2c): written by the drafter in the background
# (a check run of kind draft), then the operator's to edit, approve, copy, or
# delete. Every write here is the operator's, through Drafts. Nothing is sent.
class DraftsController < ApplicationController
  before_action { @application = Application.includes(:company, :posting).find(params[:application_id]) }
  before_action(except: :create) { @draft = @application.drafts.find(params[:id]) }

  def create
    contact = @application.company.contacts.find(params[:contact_id]) if params[:contact_id].present?
    asked = { kind: params[:kind].to_s, language: params[:language].to_s.strip.presence, guidance: params[:guidance].to_s.strip.presence,
              contact: contact }
    if (why = Drafts.refusal(@application, **asked))
      return back(alert: "Not written: #{why}.")
    end

    CheckRun.start_draft!(@application, **asked)
    back
  end

  # Saves the text as it stands; "Save and approve" approves it too.
  def update
    was_approved = @draft.approved?
    edited = Drafts.edit!(@draft, body: params[:body], subject: params[:subject])
    approving = params[:approve].present? && !@draft.reload.approved?
    Drafts.approve!(@draft) if approving
    back(notice: said(edited, approving, was_approved))
  rescue ArgumentError => e
    back(alert: "Not saved: #{e.message}.")
  end

  def destroy
    Drafts.delete!(@draft)
    back(notice: "#{@draft.label} deleted.")
  end

  private

  def said(edited, approving, was_approved)
    if approving
      "#{@draft.label} #{'saved and ' if edited}approved. Copy it and send it yourself: nothing is sent from here."
    elsif edited
      "#{@draft.label} saved.#{' It was approved: it is a draft again.' if was_approved}"
    else
      "Nothing to save: it says the same as before."
    end
  end

  # Back to the application: its page keeps the reader's place.
  def back(**flash) = redirect_to(application_path(@application), status: :see_other, **flash)
end
