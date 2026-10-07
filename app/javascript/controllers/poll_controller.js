import { Controller } from "@hotwired/stimulus"

// Re-asks for the Turbo Frame it sits in after a few seconds, while a check runs.
// The reply replaces this element, so each reply schedules the next ask, until
// one comes back finished without a poll controller.
export default class extends Controller {
  static values = { interval: { type: Number, default: 3000 } }

  connect() {
    this.timer = setTimeout(() => this.element.closest("turbo-frame")?.reload(), this.intervalValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
