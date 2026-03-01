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
end
