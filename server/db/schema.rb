# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_11_131632) do
  create_table "downloads", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "episode_id"
    t.string "file_path", null: false
    t.integer "file_size", default: 0, null: false
    t.integer "movie_id"
    t.float "progress", default: 0.0, null: false
    t.string "status", default: "pending", null: false
    t.index ["episode_id"], name: "index_downloads_on_episode_id", unique: true, where: "episode_id IS NOT NULL"
    t.index ["movie_id"], name: "index_downloads_on_movie_id", unique: true, where: "movie_id IS NOT NULL"
    t.check_constraint "(episode_id IS NOT NULL AND movie_id IS NULL) OR (episode_id IS NULL AND movie_id IS NOT NULL)", name: "downloads_episode_or_movie"
  end

  create_table "episodes", force: :cascade do |t|
    t.string "air_date"
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "duration_seconds", default: 0, null: false
    t.integer "episode_number"
    t.string "file_path"
    t.datetime "last_watched_at"
    t.integer "progress_seconds", default: 0, null: false
    t.integer "runtime"
    t.integer "season_number"
    t.integer "series_id", null: false
    t.string "title"
    t.integer "tvmaze_id"
    t.datetime "updated_at", null: false
    t.integer "watched", default: 0, null: false
    t.index ["series_id", "code"], name: "index_episodes_on_series_id_and_code", unique: true
    t.index ["series_id"], name: "index_episodes_on_series_id"
  end

  create_table "movies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "director"
    t.integer "duration_seconds", default: 0, null: false
    t.string "file_path"
    t.string "genres"
    t.string "imdb_id"
    t.datetime "last_watched_at"
    t.string "poster_url"
    t.integer "progress_seconds", default: 0, null: false
    t.float "rating"
    t.integer "runtime"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "watched", default: 0
    t.string "year"
    t.index ["file_path"], name: "index_movies_on_file_path", unique: true
    t.index ["slug"], name: "index_movies_on_slug", unique: true
  end

  create_table "playback_preferences", force: :cascade do |t|
    t.string "audio_language"
    t.datetime "created_at", null: false
    t.integer "movie_id"
    t.integer "series_id"
    t.string "subtitle_language"
    t.integer "subtitle_off", default: 0, null: false
    t.string "subtitle_size", default: "medium", null: false
    t.string "subtitle_style", default: "classic", null: false
    t.datetime "updated_at", null: false
    t.index ["movie_id"], name: "index_playback_preferences_on_movie_id", unique: true
    t.index ["series_id"], name: "index_playback_preferences_on_series_id", unique: true
  end

  create_table "series", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "genres"
    t.string "imdb_id"
    t.string "media_path"
    t.string "name", null: false
    t.string "poster_url"
    t.string "premiered"
    t.float "rating"
    t.string "slug", null: false
    t.string "status"
    t.integer "tvmaze_id"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_series_on_slug", unique: true
  end

  create_table "watch_histories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_seconds"
    t.datetime "ended_at"
    t.integer "episode_id", null: false
    t.integer "progress_seconds"
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.index ["episode_id"], name: "index_watch_histories_on_episode_id"
  end

  create_table "watchlist", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "director"
    t.string "genres"
    t.string "imdb_id"
    t.string "name", null: false
    t.string "network"
    t.string "poster_url"
    t.string "premiered"
    t.float "rating"
    t.integer "runtime"
    t.string "status"
    t.integer "tvmaze_id"
    t.string "type", default: "show", null: false
    t.datetime "updated_at", null: false
    t.string "year"
    t.index ["imdb_id"], name: "index_watchlist_on_imdb_id", unique: true, where: "imdb_id IS NOT NULL"
    t.index ["tvmaze_id"], name: "index_watchlist_on_tvmaze_id", unique: true, where: "tvmaze_id IS NOT NULL"
  end

  add_foreign_key "downloads", "episodes", on_delete: :cascade
  add_foreign_key "downloads", "movies", on_delete: :cascade
  add_foreign_key "episodes", "series", on_delete: :cascade
  add_foreign_key "playback_preferences", "movies", on_delete: :cascade
  add_foreign_key "playback_preferences", "series", on_delete: :cascade
  add_foreign_key "watch_histories", "episodes", on_delete: :cascade
end
