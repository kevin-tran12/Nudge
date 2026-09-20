Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  get "up" => "health#live", as: :liveness_check
  get "health/ready" => "health#ready", as: :readiness_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :products, only: %i[index show]

  namespace :voice do
    resource :session, only: :create, controller: "sessions"
    post "tools/:tool_name" => "tools#call", as: :tool
  end

  root "home#show"
end
