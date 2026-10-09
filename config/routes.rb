Rails.application.routes.draw do
  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # Health check endpoint for whatever host or uptime monitor runs the app
  get "up" => "rails/health#show", as: :rails_health_check

  root "dashboard#show"
  resources :roles, only: %i[index show create] do
    member do
      patch :track
      patch :dismiss
    end
  end
  resources :companies, only: %i[index show create] do
    member do
      patch :confirm_page
      patch :reject_page
      patch :set_page
      patch :rename
    end
  end
  resources :check_runs, only: %i[create show]
  resources :suggestions, only: :create
  resource :profile, only: %i[show update] do
    patch :preview
  end
  get "about", to: "pages#about"
end
