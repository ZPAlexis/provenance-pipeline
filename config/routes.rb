Rails.application.routes.draw do
  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # Health check endpoint for whatever host or uptime monitor runs the app
  get "up" => "rails/health#show", as: :rails_health_check

  root "dashboard#show"
  resources :roles, only: %i[index show]
  resources :companies, only: %i[index show]
  get "about", to: "pages#about"
end
