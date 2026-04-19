require_relative "../../lib/caramba/bonjour"

# LAN discovery for the Rails server.
#
# Two mechanisms, two audiences:
#   - mDNS via `dns-sd -R`: fast path for Electron desktop on macOS. Skipped
#     on non-Darwin platforms and when CARAMBA_DISABLE_MDNS=1.
#   - Discovery beacon (TCP listener on port 3999 by default): cross-platform
#     path for Android TV, browsers, and any client that can't do mDNS.
#     Skipped when CARAMBA_DISABLE_DISCOVERY=1.
#
# The beacon is the wider gate — if it's off, mDNS is off too. Both are
# disabled in tests, Rails console, and under rake.
return unless Caramba::Bonjour.should_beacon?

Rails.application.config.after_initialize do
  port     = Caramba::Bonjour.resolve_port
  hostname = Caramba::Bonjour.hostname
  version  = Caramba::Bonjour.version

  if Caramba::Bonjour.should_advertise?
    Caramba::Bonjour.advertise!(
      port: port, hostname: hostname, version: version,
      logger: Rails.logger
    )
  end

  Caramba::Bonjour.start_beacon!(
    port: Caramba::Bonjour.beacon_port,
    payload: Caramba::Bonjour.beacon_payload(
      port: port, hostname: hostname, version: version
    ),
    logger: Rails.logger
  )
end
