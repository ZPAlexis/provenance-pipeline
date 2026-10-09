import { Controller } from "@hotwired/stimulus"

// Related titles the operator ticked go into the profile's titles box, each once:
// nothing is saved until they preview or save the profile as usual.
export default class extends Controller {
  static targets = ["choice", "status"]
  static values = { field: String }

  add() {
    const field = document.getElementById(this.fieldValue)
    const have = new Set(field.value.split("\n").map((title) => title.trim().toLowerCase()).filter(Boolean))
    const picked = this.choiceTargets.filter((box) => box.checked && !have.has(box.value.trim().toLowerCase()))

    if (picked.length > 0) {
      field.value = [field.value.trimEnd(), ...picked.map((box) => box.value)].filter(Boolean).join("\n")
    }
    picked.forEach((box) => { box.disabled = true })
    this.statusTarget.textContent = picked.length > 0
      ? `Added ${picked.length}. Preview or save to keep them.`
      : "Nothing new to add."
  }
}
