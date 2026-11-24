import { Controller } from "@hotwired/stimulus"

// A list's filters and order (4e): a choice applies as soon as it is made, the list read again with it.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
