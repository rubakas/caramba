require 'spec_helper'

RSpec.describe 'jellyfin_player helper with slot blocks', type: :helper do
  let(:fixture) { File.join(FIXTURE_PATH, 'sample.mp4') }

  before do
    Jellyfin::Rails.configure do |c|
      c.token_secret = 'slot-test'
      c.allowed_paths = [FIXTURE_PATH]
    end
  end

  it 'captures slot blocks and renders them with slot= attributes' do
    html = helper.jellyfin_player(path: fixture) do |p|
      p.slot(:overlay_top)    { 'TOP_CONTENT' }
      p.slot(:controls_right) { 'CAST_BUTTON' }
    end

    expect(html).to include('slot="overlay-top"')
    expect(html).to include('TOP_CONTENT')
    expect(html).to include('slot="controls-right"')
    expect(html).to include('CAST_BUTTON')
  end

  it 'rejects unknown slot names' do
    expect {
      helper.jellyfin_player(path: fixture) { |p| p.slot(:nonexistent) { '' } }
    }.to raise_error(ArgumentError, /unknown slot/)
  end
end
