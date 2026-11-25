# frozen_string_literal: true

require "uri"

module Maptain
  # The llms.txt of the site (https://llmstxt.org): its name, a summary, then sections of links to the pages that
  # matter most, which sources add with `llms_txt`. One file per host, in the language of that host: llms.txt for
  # a site on one host, llms-<language>.txt for each host of a site with one host per language, which App serves
  # at /llms.txt on its host.
  class LlmsTxt
    NAME = "llms.txt"
    # A model reads the file in one go: past this, it stops being a summary of the site.
    MAX_LINKS = 200
    # What I18n.t gives for a key it does not have, unless told default: nil.
    MISSING_TRANSLATION = "Translation missing: "

    Entry = Data.define(:section, :title, :url, :notes)
    # A file to write: its name, its language and the host it is for.
    Target = Data.define(:name, :locale, :host)

    attr_reader :locale

    # Text worth writing: neither blank nor a missing translation.
    def self.present?(text)
      text.present? && !text.to_s.start_with?(MISSING_TRANSLATION)
    end

    # title, summary and details: a String, or a block run in the language of the file. locale: the language of
    # the file on the main host.
    def initialize(title:, summary: nil, details: nil, locale: nil)
      raise ConfigurationError, "llms_txt needs a title" if title.blank?

      @title = title
      @summary = summary
      @details = details
      @locale = locale
    end

    # The language of the file on the main host, spelled as in config.locales so that its URLs and translations
    # are the sitemap's: locale: when given, which must be one of them, else x_default if it is one, else the first.
    def locale_in(configuration)
      locales = configuration.locales
      if locale
        site_locale(locales, locale) ||
          raise(ConfigurationError, "llms_txt locale #{locale.inspect} is not one of the locales: #{locales.join(", ")}")
      else
        (configuration.x_default && site_locale(locales, configuration.x_default)) || locales.first
      end
    end

    # The files of the site. On a host with several languages, the file is in the one of the main host's file if
    # it has it, else x_default, else its first.
    def targets(configuration)
      main = locale_in(configuration)
      locales_by_host = configuration.locales.group_by { |site_locale| configuration.host_for(site_locale) }
      return [Target.new(NAME, main, configuration.host_for(main))] if locales_by_host.size == 1

      locales_by_host.map do |host, host_locales|
        chosen = [main, configuration.x_default].compact.filter_map { |wanted| site_locale(host_locales, wanted) }.first
        chosen ||= host_locales.first
        Target.new("llms-#{Xml.hreflang(chosen)}.txt", chosen, host)
      end
    end

    # The file, its blocks run with locale as I18n.locale (the app's when I18n does not have it), like a url block.
    # A title that comes out blank, a missing translation say, falls back to the host.
    def render(entries, locale, host)
      title, summary, details = I18n.with_locale(I18n.locale_available?(locale) ? locale : I18n.locale) do
        [@title, @summary, @details].map { |given| text(given) }
      end
      lines = ["# #{line(title).presence || host}"]
      summary = line(summary)
      lines << "> #{summary}" unless summary.empty?
      details = details.to_s.strip
      lines << details unless details.empty?
      entries.group_by(&:section).each do |section, section_entries|
        lines << "## #{line(section)}"
        lines << section_entries.map { |entry| item(entry) }.join("\n")
      end
      "#{lines.join("\n\n")}\n"
    end

    private

    # The locale of locales with the same language as wanted, which may be spelled otherwise (pt-BR, pt_BR).
    def site_locale(locales, wanted)
      locales.find { |candidate| Xml.hreflang(candidate) == Xml.hreflang(wanted) }
    end

    def text(given)
      value = given.respond_to?(:call) ? given.call : given
      value if self.class.present?(value)
    end

    def item(entry)
      notes = self.class.present?(entry.notes) ? escape(line(entry.notes)) : ""
      "- [#{escape(line(entry.title)).gsub(/[\[\]]/) { |character| "\\#{character}" }}](#{destination(entry.url)})" \
        "#{": #{notes}" unless notes.empty?}"
    end

    # A backtick would open a code span across the link, a < an HTML tag.
    def escape(text)
      text.gsub(/[\\`<]/) { |character| "\\#{character}" }
    end

    # A parenthesis would end the link early.
    def destination(url)
      url.gsub("(", "%28").gsub(")", "%29")
    end

    # Markdown reads a line break as the end of an item or a heading.
    def line(text)
      text.to_s.gsub(/[[:space:]]+/, " ").strip
    end

    # Serves /llms.txt from config.storage, the file of the request's host: on a site with one host per language,
    # and when the sitemaps live elsewhere (config.sitemaps_url), where crawlers do not look for it.
    # In config/routes.rb: get "llms.txt", to: Maptain::LlmsTxt::App.new
    # Each file is read at most once per TTL_SECONDS and process, by one request while the others get the copy at
    # hand; when the storage fails, that copy is served on and the storage asked again after RETRY_SECONDS.
    class App
      TTL_SECONDS = 300
      RETRY_SECONDS = 30
      CONTENT_TYPE = "text/plain; charset=utf-8"

      Cached = Struct.new(:content, :expires_at, :refreshing)

      def initialize
        @mutex = Mutex.new
        @cached_by_name = {}
      end

      def call(env)
        name = name_for(env)
        content = name && cached_content(name)
        return [404, {"content-type" => CONTENT_TYPE}, ["Not Found"]] unless content

        [200, {"content-type" => CONTENT_TYPE, "cache-control" => "public, max-age=#{TTL_SECONDS}"}, [content]]
      end

      private

      def name_for(env)
        configuration = Maptain.configuration
        targets = configuration.llms_txt&.targets(configuration)
        return unless targets
        return targets.first.name if targets.one?

        # The Host header, without its port or a final dot. Not X-Forwarded-Host: a cache keys a response by Host,
        # so a forged X-Forwarded-Host would get another host's file cached for this one.
        request_host = env["HTTP_HOST"].presence || env["SERVER_NAME"]
        request_host = request_host.to_s.downcase.sub(/:\d+\z/, "").delete_suffix(".")
        targets.find { |target| URI(target.host).host&.downcase == request_host }&.name
      end

      def cached_content(name)
        cached, stale = @mutex.synchronize do
          entry = (@cached_by_name[name] ||= Cached.new(nil, 0, false))
          stale = !entry.refreshing && now >= entry.expires_at
          entry.refreshing = true if stale
          [entry, stale]
        end
        stale ? refresh(cached, name) : cached.content
      end

      def refresh(cached, name)
        content = Maptain.configuration.storage.read(name)
        @mutex.synchronize do
          cached.content = content
          cached.expires_at = now + TTL_SECONDS
        end
        content
      rescue # storage unreachable: the copy at hand is served on, and the storage asked again soon
        @mutex.synchronize { cached.expires_at = now + RETRY_SECONDS }
        raise unless cached.content

        cached.content
      ensure
        @mutex.synchronize { cached.refreshing = false }
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
