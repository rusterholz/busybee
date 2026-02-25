# frozen_string_literal: true

# Simulation configuration for the busybee demo app.
#
# Speed 1.0  — Demo mode. Delays are a few seconds each (watchable by a human).
# Speed 10.0 — Fast mode for integration testing.
# Speed 0.5  — Slow mode for step-by-step observation.
Rails.application.config.x.demo.simulation_speed = ENV.fetch("DEMO_SPEED", "1.0").to_f
Rails.application.config.x.demo.order_interval = ENV.fetch("DEMO_ORDER_INTERVAL", "30").to_i # seconds
Rails.application.config.x.demo.restock_strategy = ENV.fetch("DEMO_RESTOCK_STRATEGY", "guaranteed").to_sym
