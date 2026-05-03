class AddAudioCodecToPlaybackPreferences < ActiveRecord::Migration[8.0]
  def change
    # Sources commonly carry multiple same-language audio tracks (UHD remux:
    # TrueHD eng + AC3 eng). Saving only the language can't disambiguate, so
    # picking up the saved pref always lands on whichever stream was found
    # first. Persist the codec too so the user's exact pick survives.
    add_column :playback_preferences, :audio_codec, :string
  end
end
