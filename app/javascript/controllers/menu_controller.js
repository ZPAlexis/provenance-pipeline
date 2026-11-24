import { Controller } from "@hotwired/stimulus"

// A menu in the top bar (4e): a <details> that closes when you click outside it or press Escape.
export default class extends Controller {
  connect() {
    this.outside = (event) => { if (!this.element.contains(event.target)) this.element.open = false }
    this.escape = (event) => { if (event.key === "Escape" && this.element.open) { this.element.open = false; this.element.querySelector("summary")?.focus() } }
    document.addEventListener("click", this.outside)
    document.addEventListener("keydown", this.escape)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
    document.removeEventListener("keydown", this.escape)
  }
}
