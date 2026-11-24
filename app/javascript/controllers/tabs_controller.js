import { Controller } from "@hotwired/stimulus"

// Tabs inside a page (4e): every panel is in the page already, so switching is
// instant and fetches nothing. A panel's id is the anchor links into the page
// have always used (#links, #fit), so a link or a redirect to one opens the
// panel holding it. The tab chosen is remembered for this page while the
// browser tab is open, so a form sent from a tab comes back to it, and it is
// put back after a refresh that morphs the page.
export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.show(this.fromHash() || this.remembered() || this.panelTargets[0]?.id)
    this.onHash = () => { const id = this.fromHash(); if (id) this.show(id) }
    this.onMorph = () => this.show(this.current)
    window.addEventListener("hashchange", this.onHash)
    document.addEventListener("turbo:morph", this.onMorph)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHash)
    document.removeEventListener("turbo:morph", this.onMorph)
  }

  select(event) {
    event.preventDefault()
    const id = event.currentTarget.getAttribute("aria-controls")
    this.show(id)
    this.remember(id)
    history.replaceState(history.state, "", `#${id}`)
  }

  // Arrow keys move along the tabs, Home and End to either end, as a tab list does.
  key(event) {
    const tabs = this.tabTargets
    const at = tabs.indexOf(event.currentTarget)
    const to = { ArrowRight: at + 1, ArrowLeft: at - 1, Home: 0, End: tabs.length - 1 }[event.key]
    if (to === undefined) return
    event.preventDefault()
    const tab = tabs[(to + tabs.length) % tabs.length]
    tab.focus()
    tab.click()
  }

  show(id) {
    if (!this.panelTargets.some((panel) => panel.id === id)) id = this.panelTargets[0]?.id
    this.current = id
    this.panelTargets.forEach((panel) => { panel.hidden = panel.id !== id })
    this.tabTargets.forEach((tab) => {
      const on = tab.getAttribute("aria-controls") === id
      tab.setAttribute("aria-selected", on)
      tab.tabIndex = on ? 0 : -1
      tab.classList.toggle("current", on)
      if (on) this.reveal(tab)
    })
  }

  // On a narrow screen the tabs scroll sideways: bring the chosen one into the bar's view, never moving the page.
  reveal(tab) {
    const bar = tab.parentElement.getBoundingClientRect()
    const box = tab.getBoundingClientRect()
    if (box.left < bar.left || box.right > bar.right) tab.parentElement.scrollLeft += box.left - bar.left - 16
  }

  // The panel holding the element the address's anchor names, scrolled to when it sits inside the panel.
  fromHash() {
    const anchor = decodeURIComponent(window.location.hash.slice(1))
    const target = anchor && document.getElementById(anchor)
    const panel = target && this.panelTargets.find((each) => each === target || each.contains(target))
    if (panel && panel !== target) requestAnimationFrame(() => target.scrollIntoView())
    return panel?.id
  }

  remembered() {
    try { return sessionStorage.getItem(this.key_) } catch { return null }
  }

  remember(id) {
    try { sessionStorage.setItem(this.key_, id) } catch { /* private windows may refuse storage */ }
  }

  get key_() { return `tabs:${window.location.pathname}` }
}
