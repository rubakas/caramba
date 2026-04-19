class Api::Admin::BaseController < Api::BaseController
  # Grouping point for the admin namespace. Per the approved plan, no
  # auth is required today — Caramba is a personal LAN tool and matches
  # the rest of the API. If that ever changes, a `before_action` token
  # gate would go here.
end
