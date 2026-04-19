require_relative "../../lib/caramba/bonjour"

# Advertise the Rails server on the LAN via mDNS so the Electron desktop
# client (which embeds bonjour-service) can find it without manual URL
# entry. macOS-only because we shell out to `dns-sd`; other clients rely
# on subnet-scanning `/api/health` — no advertisement needed for that.
return unless Caramba::Bonjour.should_advertise?

Rails.application.config.after_initialize do
  Caramba::Bonjour.advertise!(
    port: Caramba::Bonjour.resolve_port,
    hostname: Caramba::Bonjour.hostname,
    version: Caramba::Bonjour.version,
    logger: Rails.logger
  )
end
