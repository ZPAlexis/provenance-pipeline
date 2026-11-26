module ChangesHelper
  RESOLUTION_WORDS = { "resolved" => "careers page found", "candidate" => "a page held for you", "failed" => "no careers page" }.freeze
  RESULT_TONES = { "not_found" => "gone", "verified_live" => "live", "inaccessible" => "unsure", "refused" => "gone" }.freeze

  # A check result's kind (4e step 11), as a badge in the tone of the answer it records.
  def result_kind_badge(row) = tag.span(WhatChanged::KINDS.fetch(row.kind), class: [ "badge", RESULT_TONES[row.kind] ])

  # The company of a role a result names, when its row is about a role: the role's, or (a suggestion withdrawn, gone
  # since) the one its event recorded.
  def result_company(event)
    return unless event.target_type == "Posting"

    event.target&.company || Company.find_by(id: Array(event.changes_made["company_id"]).compact.first)
  end

  # What an audited change to a company did to its careers page or its board, in a few words.
  def company_change(event)
    changes = event.changes_made
    if (board = changes["board_vendor"])
      board.last ? "#{board.last.capitalize} board adopted#{" in place of #{board.first.capitalize}'s" if board.first}" : "#{board.first.to_s.capitalize} board dropped"
    elsif (page = changes["careers_page_url"])
      page.first ? "page moved from #{page.first}" : "page found: #{page.last}"
    else
      RESOLUTION_WORDS.fetch(changes.dig("resolution_status", 1).to_s, changes.keys.join(", "))
    end
  end
end
