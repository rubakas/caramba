require 'spec_helper'

RSpec.describe Jellyfin::Output::Mp4 do
  it 'emits +faststart for progressive single-file MP4 by default' do
    args = described_class.output_args(output_path: '/tmp/x.mp4')
    expect(args).to include('-f', 'mp4')
    expect(args).to include('-movflags', '+faststart')
    expect(args.last).to eq('/tmp/x.mp4')
  end

  it 'emits frag_keyframe + empty_moov + default_base_moof when fragmented:true' do
    args = described_class.output_args(output_path: '/tmp/y.mp4', fragmented: true)
    movflags_idx = args.index('-movflags')
    expect(args[movflags_idx + 1]).to include('+frag_keyframe')
    expect(args[movflags_idx + 1]).to include('+empty_moov')
    expect(args[movflags_idx + 1]).to include('+default_base_moof')
  end
end
