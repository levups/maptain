# frozen_string_literal: true

module Maptain
  # The llms.txt of the site (https://llmstxt.org): its name, a summary, then sections of links to the pages that
  # matter most, which sources add with `llms_txt`. One file, in one language, at the root of the site.
  class LlmsTxt
    NAME = "llms.txt"
    # A model reads the file in one go: past this, it stops being a summary of the site.
    MAX_LINKS = 200

    Entry = Data.define(:section, :title, :url, :notes)

    attr_reader :locale

    # title, summary and details: a String, or a block run in the language of the file.
    def initialize(title:, summary: nil, details: nil, locale: nil)
      raise ConfigurationError, "llms_txt needs a title" if title.blank?

      @title = title
      @summary = summary
      @details = details
      @locale = locale
    end

    # The language of the file: the one given, else x_default, else the first of the site, spelled as in
    # config.locales, so that its URLs and translations are the sitemap's.
    def locale_in(configuration)
      wanted = locale || configuration.x_default || configuration.locales.first
      configuration.locales.find { |site_locale| Xml.hreflang(site_locale) == Xml.hreflang(wanted) } ||
        raise(ConfigurationError, "llms_txt locale #{wanted.inspect} is not one of the locales: #{configuration.locales.join(", ")}")
    end

    # The file, its blocks run with locale as I18n.locale (the app's when I18n does not have it), like a url block.
    # A title that comes out blank, a missing translation say, falls back to the host.
    def render(entries, locale, host)
      title, summary, details = I18n.with_locale(I18n.locale_available?(locale) ? locale : I18n.locale) do
        [@title, @summary, @details].map { |given| value(given) }
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

    def value(given)
      given.respond_to?(:call) ? given.call : given
    end

    def item(entry)
      notes = escape(line(entry.notes))
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

    # Serves the file at the root of the site when the sitemaps live elsewhere (config.sitemaps_url), where
    # crawlers do not look for it. In config/routes.rb: get "llms.txt", to: Maptain::LlmsTxt::App.new
    # It reads the file from config.storage, on every host of the site, at most once per TTL and process; when the
    # storage fails, the copy it has is served on.
    class App
      TTL = 300
      HEADERS = {"content-type" => "text/plain; charset=utf-8", "cache-control" => "public, max-age=#{TTL}"}.freeze

      def initialize
        @mutex = Mutex.new
        @content = nil
        @read_at = nil
      end

      def call(_env)
        content = cached_content
        return [404, {"content-type" => "text/plain; charset=utf-8"}, ["Not Found"]] unless content

        [200, HEADERS.dup, [content]]
      end

      private

      def cached_content
        @mutex.synchronize do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @read_at.nil? || now - @read_at >= TTL
            begin
              @content = Maptain.configuration.storage.read(NAME)
            rescue
              raise unless @content
            end
            @read_at = now
          end
          @content
        end
      end
    end
  end
end
