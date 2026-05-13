require 'spec_helper'

RSpec.describe Jellyfin::Output::Dash do
  it 'produces a DASH MPD output for VOD by default (window_size=0)' do
    args = described_class.output_args(
      manifest_path: '/tmp/master.mpd',
      segment_dir: '/tmp',
      segment_length: 4
    )
    expect(args).to include('-f', 'dash')
    expect(args).to include('-seg_duration', '4')
    expect(args).to include('-window_size', '0')
    expect(args).to include('-use_template', '1')
    expect(args).to include('-use_timeline', '1')
    expect(args.last).to eq('/tmp/master.mpd')
  end

  it 'splits video/audio into separate AdaptationSets' do
    args = described_class.output_args(manifest_path: '/tmp/m.mpd', segment_dir: '/tmp', segment_length: 4)
    expect(args).to include('-adaptation_sets', 'id=0,streams=v id=1,streams=a')
  end
end
