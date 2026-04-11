# config/deploy/production.rb — NAS deployment target
#
# Prerequisites on nas.local:
#   1. SSH access: ssh nas.local (key-based auth recommended)
#   2. mise installed: curl https://mise.run | sh
#   3. Ruby 4.0.2 installed via mise: mise use -g ruby@4.0.2
#   4. pnpm installed: brew install pnpm (or npm i -g pnpm)
#   5. ffmpeg installed: brew install ffmpeg
#   6. libvips installed: brew install vips
#   7. Directory exists: sudo mkdir -p /opt/caramba && sudo chown $(whoami) /opt/caramba
#   8. master.key copied: mkdir -p /opt/caramba/shared/server/config && cp config/master.key /opt/caramba/shared/server/config/master.key

server "nas.local", user: "mac", roles: %w[app db web]

# macOS-specific SSH settings
set :ssh_options, {
  forward_agent: true,
  auth_methods: %w[publickey]
}
