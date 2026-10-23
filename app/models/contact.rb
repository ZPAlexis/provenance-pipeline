# A person at a company the operator deals with (Stage 2e): a recruiter, a hiring manager, a referrer, an
# interviewer. Kept with the company, linked to any of its applications; an activity can name the one it was
# with. Other people's personal data: in this database only. Written through Contacts, which audits its
# personal details as hashes, never as values.
class Contact < ApplicationRecord
  KINDS = %w[recruiter hiring_manager referrer interviewer other].freeze
  # What its audit events name by a hash alone: deleting the contact removes these from the record.
  PERSONAL = %w[name email linkedin_url notes].freeze
  EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  belongs_to :company
  has_many :application_contacts, dependent: :destroy
  has_many :applications, through: :application_contacts
  has_many :activities, dependent: :nullify
  has_many :drafts, dependent: :nullify # outreach notes addressed to them, kept as written
  # No `dependent:` on purpose — see Posting#audit_events.
  has_many :audit_events, as: :target

  validates :name, presence: true, length: { maximum: 120 }
  validates :role, length: { maximum: 120 }
  validates :kind, inclusion: { in: KINDS }
  validates :email, format: { with: EMAIL, message: "isn't an email address" }, allow_blank: true
  validates :linkedin_url, format: { with: %r{\Ahttps?://\S+\z}, message: "isn't a web address" }, allow_blank: true
  validates :notes, length: { maximum: 2_000 }

  scope :by_name, -> { order(Arel.sql("lower(contacts.name)"), :created_at) }

  def self.kind_label(kind) = kind.to_s.humanize

  def kind_label = self.class.kind_label(kind)

  # Its name, and its role there when it has one: "Ana Lima (Technical Recruiter)".
  def label = role.present? ? "#{name} (#{role})" : name
end
