import { Controller } from "@hotwired/stimulus"

// Tabs inside a page (4e): every panel is in the page already, so switching is
// instant and fetches nothing. A panel's id is the anchor links into the page
// have always used (#links, #fit), so a link or a redirect to one opens the
// panel holding it. A page opens on its first tab, unless a form was just sent
// from another: that tab is remembered once, so the page comes back to it
// (Turbo drops a redirect's anchor). It is put back after a morph refresh.
export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.show(this.fromHash() || this.sentFrom() || this.panelTargets[0]?.id)
    this.onHash = () => { const id = this.fromHash(); if (id) this.show(id) }
    this.onMorph = () => this.show(this.current)
    this.onSubmit = () => this.remember(this.current)
    window.addEventListener("hashchange", this.onHash)
    document.addEventListener("turbo:morph", this.onMorph)
    this.element.addEventListener("submit", this.onSubmit)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHash)
    document.removeEventListener("turbo:morph", this.onMorph)
    this.element.removeEventListener("submit", this.onSubmit)
  }

  select(event) {
    event.preventDefault()
    const id = event.currentTarget.getAttribute("aria-controls")
    this.show(id)
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

  // The tab a form was just sent from, once: read and forgotten.
  sentFrom() {
    try {
      const id = sessionStorage.getItem(this.key_)
      sessionStorage.removeItem(this.key_)
      return id
    } catch { return null }
  }

  remember(id) {
    try { sessionStorage.setItem(this.key_, id) } catch { /* private windows may refuse storage */ }
  }

  get key_() { return `tabs:${window.location.pathname}` }
}
