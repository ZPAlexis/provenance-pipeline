import { Controller } from "@hotwired/stimulus"

// Copies a draft's subject or text as it stands on the page, for the operator
// to paste and send themselves: nothing is ever sent from here. Where the
// clipboard can't be written, the text is selected for a Ctrl+C instead.
export default class extends Controller {
  static targets = ["subject", "body"]

  async copy({ params: { field }, currentTarget }) {
    const source = field === "subject" ? this.subjectTarget : this.bodyTarget
    try {
      await navigator.clipboard.writeText(source.value)
      this.say(currentTarget, "Copied")
    } catch {
      source.focus()
      source.select()
      this.say(currentTarget, "Selected: press Ctrl+C")
    }
  }

  say(button, words) {
    button.dataset.label ||= button.textContent
    button.textContent = words
    clearTimeout(button.copyTimer)
    button.copyTimer = setTimeout(() => { button.textContent = button.dataset.label }, 2000)
  }
}
