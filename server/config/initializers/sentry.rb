require "sentry-rails"
require Rails.root.join("lib/sentry/scrubbers")

# ── Release tag: explicit > git sha > unknown ────────────────────
release_tag =
  ENV["SENTRY_RELEASE"] ||
  begin
    sha = `git -C #{Rails.root} rev-parse --short HEAD 2>/dev/null`.strip
    sha.empty? ? "caramba@unknown" : "caramba@#{sha}"
  rescue StandardError
    "caramba@unknown"
  end

# ── Guard against noise ──────────────────────────────────────────
dsn = ENV["SENTRY_DSN"]
skip_reason =
  if dsn.nil? || dsn.empty?
    "no DSN configured"
  elsif Rails.env.test?
    "test environment"
  elsif Rails.env.development? && ENV["SENTRY_ENABLE_DEV"] != "1"
    "development environment (set SENTRY_ENABLE_DEV=1 to override)"
  end

if skip_reason
  Rails.logger.info "[sentry] skipped — #{skip_reason}"
else
  Sentry.init do |config|
    config.dsn = dsn
    config.release = release_tag
    config.environment = Rails.env.to_s
    config.send_default_pii = false
    config.traces_sample_rate = Rails.env.development? ? 1.0 : 0.2
    config.enabled_environments = %w[production development]
    config.breadcrumbs_logger = [ :sentry_logger, :http_logger ]

    # SDK shape (sentry-ruby 5.28.1):
    #   event           — Sentry::ErrorEvent < Sentry::Event
    #   event.message=  — writer via attr_writer(*WRITER_ATTRIBUTES)
    #   event.request   — Sentry::RequestInterface; has attr_accessor :url, :query_string
    #   event.exception — Sentry::ExceptionInterface; attr_reader :values (Array<SingleExceptionInterface>)
    #   SingleExceptionInterface — attr_accessor :value; attr_reader :stacktrace
    #   StacktraceInterface — attr_reader :frames (Array<Frame>)
    #   Frame — attr_accessor :abs_path, :filename
    #   event.user      — plain Hash ({})
    config.before_send = lambda do |event, _hint|
      scrubbed = Sentry::Scrubbers.before_send(event.to_hash)

      # message
      event.message = scrubbed[:message] if event.respond_to?(:message=) && scrubbed[:message]

      # request — RequestInterface has real url= and query_string= setters
      if event.respond_to?(:request) && event.request && scrubbed[:request]
        req = event.request
        if req.respond_to?(:url=) && scrubbed[:request][:url]
          req.url = scrubbed[:request][:url]
        end
        if req.respond_to?(:query_string=) && scrubbed[:request].key?(:query_string)
          req.query_string = scrubbed[:request][:query_string]
        end
      end

      # exception values + stacktrace frames
      # ExceptionInterface#values is attr_reader (Array<SingleExceptionInterface>)
      # SingleExceptionInterface#value is attr_accessor
      # StacktraceInterface#frames is attr_reader; Frame#filename/abs_path are attr_accessor
      if event.respond_to?(:exception) &&
          event.exception.respond_to?(:values) &&
          event.exception.values &&
          scrubbed.dig(:exception, :values)
        event.exception.values.each_with_index do |v, i|
          src = scrubbed[:exception][:values][i]
          next unless src

          v.value = src[:value] if v.respond_to?(:value=) && src[:value]

          next unless v.respond_to?(:stacktrace) &&
            v.stacktrace&.respond_to?(:frames) &&
            v.stacktrace.frames &&
            src.dig(:stacktrace, :frames)

          v.stacktrace.frames.each_with_index do |f, j|
            fsrc = src[:stacktrace][:frames][j]
            next unless fsrc
            f.filename = fsrc[:filename] if f.respond_to?(:filename=) && fsrc[:filename]
            f.abs_path = fsrc[:abs_path] if f.respond_to?(:abs_path=) && fsrc[:abs_path]
          end
        end
      end

      # user — event.user is a plain Hash; drop :username to avoid PII
      if event.respond_to?(:user) && event.user.is_a?(Hash) && event.user[:username]
        event.user.delete(:username)
      end

      event
    end

    # Breadcrumb shape: Sentry::Breadcrumb
    #   attr_reader :message  (with explicit message= writer)
    #   attr_accessor :data   (plain Hash)
    config.before_breadcrumb = lambda do |crumb, _hint|
      hashed = Sentry::Scrubbers.before_breadcrumb(crumb.to_hash)
      crumb.message = hashed[:message] if crumb.respond_to?(:message=) && hashed[:message]
      if crumb.respond_to?(:data) && crumb.data.is_a?(Hash) && hashed[:data].is_a?(Hash)
        %i[url to from].each do |k|
          crumb.data[k] = hashed[:data][k] if hashed[:data][k]
        end
      end
      crumb
    end
  end

  Sentry.set_tags(platform: "server")
  Rails.logger.info "[sentry] initialized release=#{release_tag} env=#{Rails.env}"
end
