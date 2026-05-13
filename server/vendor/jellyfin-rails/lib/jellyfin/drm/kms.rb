module Jellyfin
  module Drm
    # Pluggable Key Management Service. The actual key generation, storage,
    # and license issuance happens upstream of the encoder — we expose an
    # interface so deployments can integrate Widevine/FairPlay/PlayReady
    # license servers (Shaka KMS, AWS MediaTailor, ezDRM, BuyDRM, etc.).
    #
    # The default registered KMS is a `Local` implementation that generates
    # in-memory keys and serves them via a `/keys/:token` ClearKey endpoint.
    # That's suitable for ClearKey playback (browsers can decode it natively
    # via EME), NOT for commercial Widevine/FairPlay content.
    #
    # Production deployments override:
    #
    #   Jellyfin::Drm::Kms.register(:widevine, MyWidevineKms.new)
    #
    # MyWidevineKms must implement `acquire_key(item_id, scheme:)` returning
    # a Cenc::Material AND `license_url(item_id, system:)` returning the
    # client-facing license endpoint.
    module Kms
      class Local
        attr_reader :keys

        def initialize
          @keys = {}
          @mutex = Mutex.new
        end

        # Returns existing material for an item or mints a new one.
        def acquire_key(item_id, scheme: 'cenc-aes-ctr')
          @mutex.synchronize do
            @keys[item_id] ||= Cenc.generate(scheme: scheme)
          end
        end

        # ClearKey: the license URL points to our own /keys endpoint. The
        # browser EME stack fetches the raw key from there.
        def license_url(item_id, system:)
          # The actual URL is built by the controller because it depends on
          # request.base_url. We just stash the item id.
          "clearkey://item/#{item_id}"
        end
      end

      class << self
        def register(system, kms)
          (@registry ||= {})[system] = kms
        end

        def for(system)
          (@registry ||= {})[system] || default
        end

        def default
          @default ||= Local.new
        end

        def reset!
          @registry = nil
          @default = nil
        end
      end
    end
  end
end
