Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      get "search", to: "search#index"
      get "folders", to: "folders#index"
      get "tags", to: "tags#index"
      resources :memes, only: [ :index, :show ] do
        get :content, on: :member
        # Served by SearchController so it shares the per-token search rate limit bucket.
        get :similar, on: :member, to: "search#similar"
      end
    end
    namespace :v2 do
      resources :memes, only: [ :create ]
    end
  end

  resources :image_to_texts
  resources :image_embeddings
  resources :image_tags
  resources :image_uploads, only: [ :new, :create ]

  # Redirect /settings to /settings/tag_names (default settings page)
  get "/settings", to: redirect("/settings/tag_names")

  namespace :settings do
    resources :api_tokens, only: [ :index, :create ] do
      patch :revoke, on: :member
    end
    resources :tag_names
    resources :image_paths do
      member do
        post :rescan
      end
    end
    resources :image_to_texts do
      collection do
        post :update_current
        post :save_openai_settings
        post :test_openai_settings
        delete :clear_openai_key
      end
    end
  end

  resources :image_cores do
    collection do
      get "search"
      post "search_items"
      post "description_receiver"
      post "status_receiver"
      post "bulk_generate_descriptions"
      get "bulk_operation_status"
      post "bulk_operation_cancel"
    end
    member do
      post "generate_description"
      post "generate_stopper"
    end
  end

  # Pages
  get "about", to: "pages#about"

  # Root
  root "image_cores#index"

  # Healthcheck
  get "up" => "rails/health#show", as: :rails_health_check
end
