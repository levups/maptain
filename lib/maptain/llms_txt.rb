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

    # The language of the file: the one given, else x_default, else the first of the site.
    def locale_in(configuration)
      locale || configuration.x_default || configuration.locales.first
    end

    # The file, its blocks run with locale as I18n.locale (the app's when I18n does not have it), like a url block.
    def render(entries, locale)
      title, summary, details = I18n.with_locale(I18n.locale_available?(locale) ? locale : I18n.locale) do
        [@title, @summary, @details].map { |given| value(given) }
      end
      lines = ["# #{line(title)}"]
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
      notes = line(entry.notes)
      "- [#{line(entry.title).gsub(/[\\\[\]]/) { |character| "\\#{character}" }}](#{destination(entry.url)})#{": #{notes}" unless notes.empty?}"
    end

    # A parenthesis would end the link early.
    def destination(url)
      url.gsub("(", "%28").gsub(")", "%29")
    end

    # Markdown reads a line break as the end of an item or a heading.
    def line(text)
      text.to_s.gsub(/[[:space:]]+/, " ").strip
    end
  end
end
