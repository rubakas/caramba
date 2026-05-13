require 'securerandom'

module Jellyfin
  # Port of MediaInfoController.GetBitrateTestBytes (cs:331). Returns N
  # random bytes so clients can measure their effective bandwidth before
  # picking an ABR rung. Upstream caps size at 100 MB.
  class BitrateTestController < ApplicationController
    MIN_SIZE = 1
    MAX_SIZE = 100_000_000
    DEFAULT_SIZE = 102_400

    def show
      size = (params[:size] || DEFAULT_SIZE).to_i
      return unprocessable("size out of range") unless size.between?(MIN_SIZE, MAX_SIZE)
      send_data SecureRandom.random_bytes(size),
                type: 'application/octet-stream',
                disposition: 'inline'
    end

    private

    def unprocessable(msg)
      render json: { error: msg }, status: :unprocessable_entity
    end
  end
end
