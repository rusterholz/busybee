# frozen_string_literal: true

Rails.application.routes.draw do
  root "dashboard#index"

  resources :orders, only: %i[index show new create] do
    member do
      post :start_prepare_order
      post :start_ship_order
    end
  end
  resources :shipments, only: [] do
    member do
      post :start_deliver_shipment
    end
  end
  resources :warehouses, only: %i[index show]
  resources :drivers, only: %i[index]

  get "monitoring", to: "monitoring#index"
  get "monitoring/workers/:id", to: "monitoring#worker", as: :monitoring_worker
  get "monitoring/runs/:job_key", to: "monitoring#run", as: :monitoring_run
end
