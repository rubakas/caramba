require 'spec_helper'

RSpec.describe Jellyfin::Subtitle::PgsOverlay do
  def job(sub_codec:, output_height: nil)
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
    s = Jellyfin::Probing::MediaStream.new(index: 2, type: :subtitle, codec: sub_codec)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x.mkv', streams: [v, s])
    Jellyfin::Encoding::EncodingJobInfo.new(
      media_source: src,
      output_video_codec: 'h264',
      subtitle_stream: s,
      subtitle_method: :encode,
      output_height: output_height
    )
  end

  it 'emits a scale + overlay chain for PGS subs' do
    _inputs, chain = described_class.build(job(sub_codec: 'hdmv_pgs_subtitle'))
    expect(chain).to include('scale=1920:1080:flags=lanczos')
    expect(chain).to include('format=yuva420p')
    expect(chain).to include('overlay=shortest=1')
    expect(chain).to end_with('[vout]')
  end

  it 'scales the subs to the output canvas, not the source canvas' do
    _inputs, chain = described_class.build(job(sub_codec: 'hdmv_pgs_subtitle', output_height: 720))
    # output_width is nil → falls back to source width (1920), but height is 720.
    expect(chain).to include('scale=1920:720:flags=lanczos')
  end

  it 'returns [[], nil] when the job is not asking to burn graphical subs' do
    v = Jellyfin::Probing::MediaStream.new(index: 0, type: :video, codec: 'h264', width: 1920, height: 1080)
    src = Jellyfin::Probing::MediaSourceInfo.new(path: '/x', streams: [v])
    j = Jellyfin::Encoding::EncodingJobInfo.new(media_source: src, output_video_codec: 'h264')
    inputs, chain = described_class.build(j)
    expect(inputs).to eq([])
    expect(chain).to be_nil
  end
end
