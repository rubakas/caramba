require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Batch Y — TranscodeManager additions' do
  let(:tmp) { Dir.mktmpdir('jelly-y-') }
  after { FileUtils.rm_rf(tmp) }

  let(:mgr) { Jellyfin::Transcoding::TranscodeManager.new }

  describe '#find_by_session (port of TranscodeManager.cs:100)' do
    it 'returns the first job with the matching play_session_id' do
      j1 = Jellyfin::Transcoding::TranscodingJob.new(id: 'a', params: { play_session_id: 'sess-1' }, root_dir: tmp)
      j2 = Jellyfin::Transcoding::TranscodingJob.new(id: 'b', params: { play_session_id: 'sess-2' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs).merge!('a' => j1, 'b' => j2)
      expect(mgr.find_by_session('sess-2')).to equal(j2)
    end

    it 'returns nil when play_session_id is blank' do
      expect(mgr.find_by_session('')).to be_nil
      expect(mgr.find_by_session(nil)).to be_nil
    end
  end

  describe '#find_by_path (port of TranscodeManager.cs:109)' do
    it 'returns the job whose dir matches the requested path' do
      j = Jellyfin::Transcoding::TranscodingJob.new(id: 'x', params: {}, root_dir: tmp)
      mgr.instance_variable_get(:@jobs)['x'] = j
      expect(mgr.find_by_path(j.dir)).to equal(j)
    end

    it 'filters by params[:type] when provided' do
      j = Jellyfin::Transcoding::TranscodingJob.new(id: 'x', params: { type: 'hls' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs)['x'] = j
      expect(mgr.find_by_path(j.dir, type: 'hls')).to equal(j)
      expect(mgr.find_by_path(j.dir, type: 'progressive')).to be_nil
    end
  end

  describe '#kill_transcoding_jobs (port of TranscodeManager.cs:194)' do
    it 'stops every job matching the play_session_id (preferred filter)' do
      j1 = Jellyfin::Transcoding::TranscodingJob.new(id: 'a', params: { play_session_id: 'sess-1' }, root_dir: tmp)
      j2 = Jellyfin::Transcoding::TranscodingJob.new(id: 'b', params: { play_session_id: 'sess-1' }, root_dir: tmp)
      j3 = Jellyfin::Transcoding::TranscodingJob.new(id: 'c', params: { play_session_id: 'other' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs).merge!('a' => j1, 'b' => j2, 'c' => j3)

      killed = mgr.kill_transcoding_jobs(play_session_id: 'sess-1')
      expect(killed).to eq(2)
      expect(mgr.instance_variable_get(:@jobs).keys).to eq(['c'])
    end

    it 'stops jobs by device_id when no play_session_id supplied' do
      j1 = Jellyfin::Transcoding::TranscodingJob.new(id: 'a', params: { device_id: 'tv-1' }, root_dir: tmp)
      j2 = Jellyfin::Transcoding::TranscodingJob.new(id: 'b', params: { device_id: 'tv-2' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs).merge!('a' => j1, 'b' => j2)
      mgr.kill_transcoding_jobs(device_id: 'tv-1')
      expect(mgr.instance_variable_get(:@jobs).keys).to eq(['b'])
    end

    it 'honours the delete_files predicate (upstream Func<string,bool>)' do
      j = Jellyfin::Transcoding::TranscodingJob.new(id: 'x', params: { play_session_id: 'sess-x' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs)['x'] = j
      expect(j).not_to receive(:cleanup!)
      mgr.kill_transcoding_jobs(play_session_id: 'sess-x', delete_files: ->(_p) { false })
    end

    it 'is a no-op when neither device_id nor play_session_id matches' do
      j = Jellyfin::Transcoding::TranscodingJob.new(id: 'x', params: { play_session_id: 'sess-1' }, root_dir: tmp)
      mgr.instance_variable_get(:@jobs)['x'] = j
      expect(mgr.kill_transcoding_jobs(play_session_id: 'nope')).to eq(0)
      expect(mgr.instance_variable_get(:@jobs)['x']).to equal(j)
    end
  end
end
