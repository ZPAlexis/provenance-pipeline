import "controllers"
import "@hotwired/turbo-rails"

document.addEventListener("turbo:before-cache", function() {
  const flashContainer = document.getElementById("flash-messages");
  if (flashContainer) {
    flashContainer.innerHTML = "";
  }
});