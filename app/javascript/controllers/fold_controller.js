import { Controller } from "@hotwired/stimulus"

// A fold (<details>) whose form has its own Cancel: closing it puts back the
// button that opened it, hidden while the form shows.
export default class extends Controller {
  close() {
    this.element.open = false
  }
}
