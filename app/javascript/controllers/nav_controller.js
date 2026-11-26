import { Controller } from "@hotwired/stimulus"

// The top bar on a narrow screen (4e step 13): its tabs folded behind a menu button, opened and closed by it, closed
// again by Escape or a click outside. On a wide screen the button is hidden and the tabs always show.
export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.outside = (event) => { if (!this.element.contains(event.target)) this.set(false) }
    this.escape = (event) => { if (event.key === "Escape") this.set(false) }
    document.addEventListener("click", this.outside)
    document.addEventListener("keydown", this.escape)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
    document.removeEventListener("keydown", this.escape)
  }

  toggle() {
    this.set(!this.element.classList.contains("open"))
  }

  set(open) {
    this.element.classList.toggle("open", open)
    this.buttonTarget.setAttribute("aria-expanded", open)
  }
}
