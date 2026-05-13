require 'base64'
require 'json'
require 'openssl'
require 'securerandom'

module Jellyfin
  module Transcoding
    # HMAC-signed token carrying transcode parameters. Callers post a Params struct
    # to /transcode/start and get back an opaque base64 token. Subsequent segment
    # requests carry only the token — there's no server-side session state.
    #
    # Payload schema (all optional except `path`):
    #   { path:, video_codec:, video_bitrate:, audio_codec:, audio_bitrate:,
    #     audio_track:, subtitle_track:, subtitle_mode:, max_height:,
    #     segment_length:, nonce: }
    class Token
      class InvalidToken < StandardError; end

      def self.encode(payload)
        secret = require_secret!
        body = payload.merge(nonce: payload[:nonce] || SecureRandom.hex(8)).to_json
        sig = OpenSSL::HMAC.hexdigest('SHA256', secret, body)
        Base64.urlsafe_encode64("#{sig}.#{body}", padding: false)
      end

      def self.decode(token)
        secret = require_secret!
        raw = Base64.urlsafe_decode64(token.to_s)
        sig, body = raw.split('.', 2)
        raise InvalidToken, 'malformed' if sig.nil? || body.nil?
        expected = OpenSSL::HMAC.hexdigest('SHA256', secret, body)
        unless OpenSSL.fixed_length_secure_compare(sig, expected)
          raise InvalidToken, 'bad signature'
        end
        JSON.parse(body, symbolize_names: true)
      rescue ArgumentError, JSON::ParserError => e
        raise InvalidToken, e.message
      end

      def self.require_secret!
        secret = Jellyfin::Rails.configuration.token_secret
        raise InvalidToken, 'token_secret not configured' if secret.nil? || secret.empty?
        secret
      end
    end
  end
end
