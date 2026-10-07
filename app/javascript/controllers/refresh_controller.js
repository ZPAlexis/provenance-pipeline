import { Controller } from "@hotwired/stimulus"

// A check just finished: reload the page once, so its new answer shows in the
// badges and the history as well. The reloaded page renders the finished run
// without this controller, so it happens only once.
export default class extends Controller {
  connect() {
    window.Turbo.visit(window.location.href, { action: "replace" })
  }
}
