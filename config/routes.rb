Rails.application.routes.draw do
  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # Health check endpoint (used by Kamal and load balancers)
  get "up" => "rails/health#show", as: :rails_health_check

  get "about", to: "pages#about"

  root "pages#home"
end
