require 'spec_helper'

RSpec.describe Jellyfin::Subtitle::Charset do
  describe '.detect' do
    it 'recognises UTF-8 BOM' do
      expect(described_class.detect("\xEF\xBB\xBFhello".b)).to eq('UTF-8')
    end

    it 'recognises UTF-16LE BOM' do
      expect(described_class.detect("\xFF\xFE\x68\x00".b)).to eq('UTF-16LE')
    end

    it 'returns UTF-8 for ASCII-only content (valid UTF-8)' do
      expect(described_class.detect('plain english subtitles')).to eq('UTF-8')
    end

    it 'detects Windows-1251 cyrillic-heavy content' do
      # Cyrillic letters densely packed in 0xC0..0xFF range.
      cyr = (0xC0..0xFF).to_a.pack('C*') * 10
      expect(described_class.detect(cyr)).to eq('WINDOWS-1251')
    end

    it 'detects Windows-1252 for accented-latin content' do
      # 0x80..0xBF range, sparser — fails valid UTF-8 test.
      bytes = "Caf\xE9 \xE0 deux".b
      expect(described_class.detect(bytes)).to eq('WINDOWS-1252')
    end
  end

  describe '.to_iconv' do
    it 'maps common codepage names to iconv-friendly tokens' do
      expect(described_class.to_iconv('WINDOWS-1252')).to eq('cp1252')
      expect(described_class.to_iconv('WINDOWS-1251')).to eq('cp1251')
      expect(described_class.to_iconv('SHIFT_JIS')).to eq('shift_jis')
      expect(described_class.to_iconv('UTF-8')).to be_nil
      expect(described_class.to_iconv(nil)).to be_nil
    end
  end
end
