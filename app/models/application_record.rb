class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Every write passes Authority's check (1.3): while an agent acts, against the
  # scopes of the credential its run was issued. Raises Authority::Denied.
  before_create { Authority.check!(self, :create) }
  before_update { Authority.check!(self, :update) }
  before_destroy { Authority.check!(self, :destroy) }
end
