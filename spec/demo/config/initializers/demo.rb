# frozen_string_literal: true

# Simulation configuration for the busybee demo app.
#
# Speed scales all timing: worker delays AND order frequency.
# Speed 1.0  — Demo mode. Orders every 12s, delays of a few seconds (watchable).
# Speed 10.0 — Stress test. ~1 order/s, near-instant delays.
# Speed 0.5  — Slow mode. Orders every 24s, long delays for step-by-step observation.
Rails.application.config.x.demo.simulation_speed = ENV.fetch("DEMO_SPEED", "1.0").to_f
Rails.application.config.x.demo.order_interval = ENV.fetch("DEMO_ORDER_INTERVAL", "12").to_i # seconds (/ speed)
Rails.application.config.x.demo.restock_strategy = ENV.fetch("DEMO_RESTOCK_STRATEGY", "guaranteed").to_sym

# Simulated worker rollovers fire only while the demo is actually running — never
# under test, where worker specs invoke perform directly and the per-job hazard
# would be random spec pollution. DEMO_ROLLOVERS=false also freezes them for a
# stable live demo.
Rails.application.config.x.demo.rollovers_enabled =
  !Rails.env.test? && ENV.fetch("DEMO_ROLLOVERS", "true") != "false"

Rails.application.config.x.demo.item_catalog = %w[
  wireless-mouse usb-c-hub laptop-stand mechanical-keyboard monitor-arm
  webcam headset desk-lamp cable-organizer mouse-pad
  usb-drive power-strip tablet-stylus phone-charger screen-protector
].freeze
