# frozen_string_literal: true

class DriversController < ApplicationController
  def index
    @drivers = Delivery::Driver.by_mileage
  end
end
