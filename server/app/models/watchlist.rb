class Watchlist < ApplicationRecord
  include Posterable

  self.table_name = "watchlist"
  self.inheritance_column = :_type_disabled # 'type' column is not STI

  validates :name, presence: true
  validates :type, presence: true, inclusion: { in: %w[show movie] }
  validates :tvmaze_id, uniqueness: true, allow_nil: true
  validates :imdb_id, uniqueness: true, allow_nil: true

  scope :shows, -> { where(type: "show") }
  scope :movies, -> { where(type: "movie") }
end
