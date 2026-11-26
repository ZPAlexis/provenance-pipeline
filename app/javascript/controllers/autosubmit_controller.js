import { Controller } from "@hotwired/stimulus"

// A list's filters and order (4e): a choice applies as soon as it is made, the list read again with it. A date
// (the record pages', step 11) applies a moment after its last change, so typing one isn't sent half done.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }

  submitSoon() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.submit(), 800)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
