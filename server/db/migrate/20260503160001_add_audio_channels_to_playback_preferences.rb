class AddAudioChannelsToPlaybackPreferences < ActiveRecord::Migration[8.0]
  def change
    # Same-language same-codec audio tracks differ by channel count
    # (e.g. AAC stereo + AAC 5.1 from the same source). Without persisting
    # the channel count, the selector can't tell them apart and falls
    # back to whichever ffprobe lists first.
    add_column :playback_preferences, :audio_channels, :integer
  end
end
