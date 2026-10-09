class AllowLlmCallsWithoutAPage < ActiveRecord::Migration[8.1]
  def change
    # Not every call reads a page: proposing titles for a search profile (purpose
    # "relate") reads only the profile. Such a call keeps its run, its cost, and
    # what produced it, with no page check.
    change_column_null :llm_calls, :page_check_id, true
  end
end
