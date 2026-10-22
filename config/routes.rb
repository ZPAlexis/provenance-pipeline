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
    patch :dismiss_many, on: :collection
  end
  resources :applications, only: %i[index show create] do
    member do
      patch :move
      post :log
      patch :note
    end
    resources :activities, only: %i[update destroy]
    resources :drafts, only: %i[create update destroy]
    resources :resume_reviews, only: :destroy
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
  resource :check_all, only: %i[show create], controller: "check_all"
  get "changes", to: "changes#index", as: :changes
  resources :suggestions, only: :create
  resource :profile, only: %i[show update] do
    patch :preview
    patch :related
    patch :resume
    delete :resume, action: :remove_resume
  end
  get "review", to: "review_items#index", as: :review
  resources :review_items, only: [] do
    patch :decide, on: :member
  end
  get "agents", to: "agents#index", as: :agents
  resources :agent_credentials, only: :show, path: "agents/credentials" do
    patch :revoke, on: :member
  end
  get "about", to: "pages#about"
end
