module Jellyfin
  # ActionCable channel that streams ffmpeg `-progress` output to subscribers.
  #
  # Subscribe with:
  #   const cable = ActionCable.createConsumer('/jellyfin/cable')
  #   cable.subscriptions.create({ channel: 'Jellyfin::ProgressChannel', job_id: 'abc123' },
  #     { received(data) { console.log(data) } })
  #
  # Falls back to a no-op when ActionCable isn't loaded (e.g., the engine is
  # mounted in an API-only host without Rails::Engine ActionCable wiring).
  class ProgressChannel < (defined?(ApplicationCable::Channel) ? ApplicationCable::Channel : (defined?(ActionCable::Channel::Base) ? ActionCable::Channel::Base : Object))
    def subscribed
      @job_id = params[:job_id].to_s
      reject and return if @job_id.empty?
      stream_from broadcast_key(@job_id)

      @sub_id = Jellyfin::Transcoding::ProgressBroadcaster.instance.subscribe(@job_id) do |snapshot|
        ActionCable.server.broadcast(broadcast_key(@job_id), snapshot)
      end
    end

    def unsubscribed
      Jellyfin::Transcoding::ProgressBroadcaster.instance.unsubscribe(@job_id, @sub_id) if @sub_id
    end

    private

    def broadcast_key(job_id)
      "jellyfin:progress:#{job_id}"
    end
  end
end if defined?(ActionCable)
