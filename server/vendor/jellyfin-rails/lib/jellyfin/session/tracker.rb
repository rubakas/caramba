module Jellyfin
  module Session
    # In-memory playback-session tracker. Mirrors the upstream SessionManager:
    # clients call Playing → Progress (every ~5s) → Stopped, and we surface
    # the active sessions through /sessions/active.
    #
    # The tracker is process-local; if you run multiple Rails processes you
    # need to swap this for a shared store (Redis, etc.) — for now, single-
    # process is enough.
    class Tracker
      Session = Struct.new(:id, :item_id, :user_id, :client, :device, :version,
                           :position_ticks, :run_time_ticks, :paused,
                           :playback_method, :started_at, :last_updated_at,
                           keyword_init: true) do
        def progress_fraction
          return 0.0 unless run_time_ticks && run_time_ticks.positive?
          position_ticks.to_f / run_time_ticks.to_f
        end

        def to_h_serializable
          to_h.merge(progress_fraction: progress_fraction)
        end
      end

      def self.instance
        @instance ||= new
      end

      def self.reset!
        @instance = nil
      end

      def initialize
        @sessions = {}
        @mutex = Mutex.new
      end

      def started(id:, item_id:, user_id: nil, client: nil, device: nil, version: nil,
                  run_time_ticks: nil, playback_method: 'direct_play')
        @mutex.synchronize do
          @sessions[id] = Session.new(
            id: id, item_id: item_id, user_id: user_id, client: client, device: device,
            version: version, run_time_ticks: run_time_ticks, paused: false,
            playback_method: playback_method, position_ticks: 0,
            started_at: Time.now, last_updated_at: Time.now
          )
        end
      end

      def progress(id:, position_ticks:, paused: nil)
        @mutex.synchronize do
          sess = @sessions[id]
          return nil unless sess
          sess.position_ticks = position_ticks.to_i
          sess.paused = paused unless paused.nil?
          sess.last_updated_at = Time.now
          sess
        end
      end

      def stopped(id:, position_ticks: nil)
        @mutex.synchronize do
          sess = @sessions.delete(id)
          return nil unless sess
          sess.position_ticks = position_ticks.to_i if position_ticks
          sess.last_updated_at = Time.now
          sess
        end
      end

      def ping(id:)
        @mutex.synchronize do
          sess = @sessions[id]
          sess.last_updated_at = Time.now if sess
          sess
        end
      end

      def fetch(id) = @mutex.synchronize { @sessions[id]&.dup }
      def active   = @mutex.synchronize { @sessions.values.map(&:dup) }
      def size     = @mutex.synchronize { @sessions.size }
    end
  end
end
