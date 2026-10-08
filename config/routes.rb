Rails.application.routes.draw do
  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # Health check endpoint for whatever host or uptime monitor runs the app
  get "up" => "rails/health#show", as: :rails_health_check

  root "dashboard#show"
  resources :roles, only: %i[index show] do
    member do
      patch :track
      patch :dismiss
    end
  end
  resources :companies, only: %i[index show]
  resources :check_runs, only: %i[create show]
  resource :profile, only: %i[show update] do
    patch :preview
  end
  get "about", to: "pages#about"
end
