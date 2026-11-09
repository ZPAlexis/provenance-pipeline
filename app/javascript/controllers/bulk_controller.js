import { Controller } from "@hotwired/stimulus"

// Roles or companies picked for one action at once (archiving them, or tracking the
// proposals picked): says how many are picked, and keeps the buttons off until there is
// one. The boxes sit in the table and belong to the form by its id.
export default class extends Controller {
  static targets = ["box", "all", "count", "submit"]

  connect() {
    this.count()
  }

  all({ target }) {
    this.boxTargets.forEach((box) => { box.checked = target.checked })
    this.count()
  }

  count() {
    const picked = this.boxTargets.filter((box) => box.checked).length
    this.countTarget.textContent = picked ? `${picked} selected` : "None selected"
    this.submitTargets.forEach((submit) => { submit.disabled = picked === 0 })
    if (this.hasAllTarget) {
      this.allTarget.checked = picked > 0 && picked === this.boxTargets.length
      this.allTarget.indeterminate = picked > 0 && picked < this.boxTargets.length
    }
  }
}
