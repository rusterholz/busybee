# frozen_string_literal: true

module Busybee
  # Base class for all gem operation errors.
  # Never raised directly; exists for `rescue Busybee::Error`.
  class Error < StandardError
  end
end
