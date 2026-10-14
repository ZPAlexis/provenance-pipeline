module ChangesHelper
  RESOLUTION_WORDS = { "resolved" => "careers page found", "candidate" => "a page held for you", "failed" => "no careers page" }.freeze

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
