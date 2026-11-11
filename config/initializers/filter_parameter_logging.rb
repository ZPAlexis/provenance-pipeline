# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# The record's private text, out of the logs (a request's parameters, the values in SQL lines) and out of a record
# printed in a console or on an error page: the resume and a role's description (`resume_text`, `text`), what is
# written for an application (a draft's body and subject, what to stress, a review's note), notes, pay, what happened,
# and the people (a contact's name, role, link and notes: someone else's details). An audit event's changes carry some
# of these too. Exact where a looser match would hide what isn't private (`role` is not `role_title`, `subject` is not
# `subject_id`); a name is hidden wherever it is, a company's included, which keeps the private target list out too.
Rails.application.config.filter_parameters += [
  :resume_text, /\Atext\z/, :body, /subject\z/, :guidance, /\Anotes?\z/, :comp_expectation, :summary,
  /\Aname\z/, /\Arole\z/, :linkedin, /\Achanges_made\z/
]

# What the operator wants of a company and avoids (4b), in their own words: their values and stances, too.
Rails.application.config.filter_parameters += [ /\Acompany_(wants|avoids|excluded)/ ]

# The operator's background beyond the resume (4c), its three parts.
Rails.application.config.filter_parameters += [ /\A(looking_for|role_preferences|not_on_resume)\z/ ]
