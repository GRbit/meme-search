# frozen_string_literal: true

module Api
  module V2
    # Same bearer tokens, scope checks and error envelope as v1, so clients
    # handle both versions alike.
    class BaseController < Api::V1::BaseController
    end
  end
end
