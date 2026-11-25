import { Controller } from "@hotwired/stimulus"

// Reloads the page as it is (4e): the AI assistant's banner's Refresh. A "replace" visit to the same address fetches
// the page again, its open tab kept in the address.
export default class extends Controller {
  now() {
    window.Turbo.visit(window.location.href, { action: "replace" })
  }
}
