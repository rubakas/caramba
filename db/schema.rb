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

ActiveRecord::Schema[8.1].define(version: 2026_03_27_083424) do
  create_table "episodes", force: :cascade do |t|
    t.string "code"
    t.datetime "created_at", null: false
    t.integer "duration_seconds", default: 0
    t.integer "episode_number"
    t.string "file_path"
    t.datetime "last_watched_at"
    t.integer "progress_seconds", default: 0
    t.integer "season_number"
    t.string "title"
    t.datetime "updated_at", null: false
    t.boolean "watched", default: false, null: false
    t.index ["code"], name: "index_episodes_on_code", unique: true
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

  add_foreign_key "watch_histories", "episodes"
end
