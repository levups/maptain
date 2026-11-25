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
    # The most records read for one file: past it, a scope should pick the records of the file's language itself.
    MAX_RECORDS = 2_000
    # How I18n.t begins what it gives for a key it does not have, unless told default: nil: "Translation missing",
    # "translation missing" before i18n 1.13.
    MISSING_TRANSLATION = /\Atranslation missing/i

    Entry = Data.define(:section, :title, :url, :notes)
    # A file to write: its name, its language and the host it is for.
    Target = Data.define(:name, :locale, :host)

    attr_reader :locale

    # Text worth writing: neither blank nor a missing translation.
    def self.present?(text)
      text.present? && !text.to_s.match?(MISSING_TRANSLATION)
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

    # Serves /llms.txt from config.storage, the file of the request's host, for one host per language or sitemaps
    # served elsewhere: get "llms.txt", to: Maptain::LlmsTxt::App.new in config/routes.rb. A file is read once per
    # TTL_SECONDS and process, by one request while the others get the copy at hand; with the storage unreachable,
    # that copy is served on, or a 503 when there is none yet: the file is not gone.
    class App
      TTL_SECONDS = 300
      RETRY_SECONDS = 30
      CONTENT_TYPE = "text/plain; charset=utf-8"

      # The storage could not be read and no copy is at hand: answered 503, never 404, since the file is not gone.
      class StorageUnreachable < StandardError; end

      Cached = Struct.new(:content, :expires_at, :refreshing, :error)

      def initialize
        @mutex = Mutex.new
        @cached_by_name = {}
      end

      def call(env)
        name = name_for(env)
        content = name && cached_content(name)
        return [404, {"content-type" => CONTENT_TYPE}, ["Not Found"]] unless content

        [200, {"content-type" => CONTENT_TYPE, "cache-control" => "public, max-age=#{TTL_SECONDS}"}, [content]]
      rescue StorageUnreachable
        [503, {"content-type" => CONTENT_TYPE, "retry-after" => RETRY_SECONDS.to_s}, ["Service Unavailable"]]
      end

      private

      # The file of the request's Host header, without a final dot. Not X-Forwarded-Host: a cache keys a response
      # by Host, so a forged one would get another host's file cached for this one. The port tells apart hosts
      # that share a name.
      def name_for(env)
        configuration = Maptain.configuration
        targets = configuration.llms_txt&.targets(configuration)
        return unless targets
        return targets.first.name if targets.one?

        name, port = (env["HTTP_HOST"].presence || env["SERVER_NAME"]).to_s.downcase.split(/:(?=\d+\z)/)
        name = name.to_s.delete_suffix(".")
        same_name = targets.select { |target| URI(target.host).host.downcase == name }
        return same_name.first&.name if same_name.size < 2

        same_name.find { |target| URI(target.host).port == (port&.to_i || URI(target.host).default_port) }&.name
      end

      # Refreshed by the first request past expiry. While the storage is unreachable with no copy at hand, the
      # others get the error until the next try; while a first read runs, they read the file too rather than
      # answer that it does not exist.
      def cached_content(name)
        cached, action, copy, error = @mutex.synchronize do
          entry = (@cached_by_name[name] ||= Cached.new(nil, 0, false, nil))
          action = if !entry.refreshing && now >= entry.expires_at
            entry.refreshing = true
            :refresh
          elsif entry.content.nil? && entry.error
            :error
          elsif entry.content.nil? && entry.refreshing
            :read
          else
            :cached
          end
          [entry, action, entry.content, entry.error]
        end
        case action
        when :refresh then refresh(cached, name)
        when :read then read(name)
        when :error then raise StorageUnreachable, error.message
        else copy
        end
      end

      # A file not there yet, before the first build, is asked for again after RETRY_SECONDS, not TTL_SECONDS.
      def refresh(cached, name)
        content = read(name)
        @mutex.synchronize do
          cached.content = content
          cached.error = nil
          cached.expires_at = now + (content ? TTL_SECONDS : RETRY_SECONDS)
        end
        content
      rescue StorageUnreachable => exception
        copy = @mutex.synchronize do
          cached.error = exception
          cached.expires_at = now + RETRY_SECONDS
          cached.content
        end
        copy || raise
      ensure
        @mutex.synchronize { cached.refreshing = false }
      end

      def read(name)
        Maptain.configuration.storage.read(name)
      rescue => exception # whatever the storage raises: a timeout, a refused connection, a 5xx
        raise StorageUnreachable, exception.message
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
