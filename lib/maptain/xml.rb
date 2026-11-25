# frozen_string_literal: true

module Maptain
  module Xml
    DECLARATION = %(<?xml version="1.0" encoding="UTF-8"?>\n)
    URLSET_OPEN = %(#{DECLARATION}<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" ) +
      %(xmlns:xhtml="http://www.w3.org/1999/xhtml" ) +
      %(xmlns:image="http://www.google.com/schemas/sitemap-image/1.1" ) +
      %(xmlns:video="http://www.google.com/schemas/sitemap-video/1.1" ) +
      %(xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">\n)
    URLSET_CLOSE = "</urlset>\n"
    INDEX_OPEN = %(#{DECLARATION}<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
    INDEX_CLOSE = "</sitemapindex>\n"
    # Google reads no more than 1,000 images per URL.
    MAX_IMAGES_PER_URL = 1_000
    # https://developers.google.com/search/docs/crawling-indexing/sitemaps/video-sitemaps
    VIDEO_KEYS = %i[thumbnail_loc title description content_loc player_loc duration publication_date expiration_date].freeze
    MAX_VIDEO_DESCRIPTION_CHARACTERS = 2_048
    MAX_VIDEO_DURATION_SECONDS = 28_800
    MAX_VIDEO_TITLE_CHARACTERS = 100
    # What XML 1.0 forbids in text, tabs and line breaks aside.
    XML_FORBIDDEN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/
    # Regions that write Chinese in Traditional characters.
    TRADITIONAL_CHINESE = %w[tw hk mo].freeze
    # https://developers.google.com/search/docs/crawling-indexing/sitemaps/news-sitemap
    NEWS_KEYS = %i[name language title publication_date].freeze
    # Fields written as text, whatever the object: a title or a description may be an Action Text body.
    VIDEO_TEXT = %i[title description].freeze
    NEWS_TEXT = %i[name title language].freeze
    # What Google News takes as a language.
    NEWS_LANGUAGE = /\A(?:[a-z]{2,3}|zh-cn|zh-tw)\z/
    # Google reads no more than 1,000 news entries per file.
    MAX_NEWS_PER_FILE = 1_000
    # https://www.w3.org/TR/NOTE-datetime: a year, a month, a day, or a time with its zone.
    W3C_DATE = /\A(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?\z/
    W3C_TIME = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})\z/

    LOCATION = %r{<loc>([^<]*)</loc>}
    UNESCAPED_BY_ENTITY = {"&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => '"', "&apos;" => "'"}.freeze

    module_function

    # One <url> per language. Each lists every language of the page, itself included: search engines drop
    # hreflang links that are not returned by the page they point to.
    # Videos and news, written in each language, close the <url> of their language; languages that share a URL
    # write the media of the first of them that has some.
    def url_entries(page, x_default:)
      shared = "#{lastmod_tag(page.lastmod)}#{alternates(page, x_default)}#{images(page.images)}"
      if page.media_by_locale.empty?
        shared = "#{shared}</url>\n"
        return page.urls.map { |url| "<url><loc>#{escape(url)}</loc>#{shared}" }
      end

      page.url_by_locale.group_by { |_hreflang, url| url }.map do |url, pairs|
        media = pairs.lazy.filter_map { |hreflang, _url| page.media_by_locale[hreflang] }.first
        "<url><loc>#{escape(url)}</loc>#{shared}#{media}</url>\n"
      end
    end

    # A <video:video> and what was left out of it, or nil and the reason it cannot be one. Locations are absolute
    # already; page_url is the <loc>, which a player or content location must not be. Fields Maptain does not
    # write are left out of the video, not the video. Tags in the order of the sitemap-video/1.1 schema.
    def video(fields, page_url)
      ignored = fields.keys - VIDEO_KEYS
      fields = cleaned(fields.slice(*VIDEO_KEYS), VIDEO_TEXT)
      missing = %i[thumbnail_loc title description].reject { |key| fields[key] }
      missing << :player_loc unless fields[:content_loc] || fields[:player_loc]
      return [nil, "has a video without #{missing.first}, left out"] if missing.any?
      if [fields[:player_loc], fields[:content_loc]].include?(page_url)
        return [nil, "has a video whose player_loc or content_loc is the page itself, left out"]
      end

      duration = fields[:duration] && whole_number(fields[:duration])
      if fields[:duration] && !duration&.between?(1, MAX_VIDEO_DURATION_SECONDS)
        return [nil, "has a video whose duration is not 1 to #{MAX_VIDEO_DURATION_SECONDS} seconds (#{fields[:duration].inspect}), left out"]
      end

      dates = %i[expiration_date publication_date].to_h { |key| [key, fields[key] && full_date(fields[key])] }
      rejected = dates.find { |key, stamp| fields[key] && stamp.nil? }
      return [nil, "has a video #{rejected.first} that is not a full W3C date (#{fields[rejected.first].inspect}), left out"] if rejected

      tags = "<video:thumbnail_loc>#{escape(fields[:thumbnail_loc])}</video:thumbnail_loc>" \
        "<video:title>#{escape(cut(fields[:title], MAX_VIDEO_TITLE_CHARACTERS))}</video:title>" \
        "<video:description>#{escape(cut(fields[:description], MAX_VIDEO_DESCRIPTION_CHARACTERS))}</video:description>"
      tags << "<video:content_loc>#{escape(fields[:content_loc])}</video:content_loc>" if fields[:content_loc]
      tags << "<video:player_loc>#{escape(fields[:player_loc])}</video:player_loc>" if fields[:player_loc]
      tags << "<video:duration>#{duration}</video:duration>" if duration
      dates.each { |key, stamp| tags << "<video:#{key}>#{escape(stamp)}</video:#{key}>" if stamp }
      reason = "has a video with #{ignored.map(&:inspect).join(", ")}, not written (only #{VIDEO_KEYS.join(", ")})" if ignored.any?
      ["<video:video>#{tags}</video:video>", reason]
    end

    # A <news:news>, or nil and the reason it cannot be one. language: the page's when not given, spelled as Google
    # wants.
    def news(fields, hreflang)
      unknown = fields.keys - NEWS_KEYS
      return [nil, "has news with #{unknown.first.inspect}, not one of #{NEWS_KEYS.join(", ")}, left out"] if unknown.any?

      fields = cleaned(fields, NEWS_TEXT)
      missing = %i[name title publication_date].reject { |key| fields[key] }
      return [nil, "has news without #{missing.first}, left out"] if missing.any?

      published = full_date(fields[:publication_date])
      return [nil, "has news whose publication_date is not a full W3C date (#{fields[:publication_date].inspect}), left out"] unless published

      language = news_language(hreflang(fields[:language] || hreflang))
      return [nil, "has news whose language is not a language code (#{fields[:language].inspect}), left out"] unless language.match?(NEWS_LANGUAGE)

      ["<news:news><news:publication><news:name>#{escape(fields[:name])}</news:name>" \
        "<news:language>#{escape(language)}</news:language></news:publication>" \
        "<news:publication_date>#{escape(published)}</news:publication_date>" \
        "<news:title>#{escape(fields[:title])}</news:title></news:news>", nil]
    end

    # The fields with their text ones as text and every blank one gone: a String, an Action Text body or a number
    # alike.
    def cleaned(fields, text_keys)
      fields.to_h do |key, value|
        [key, (text_keys.include?(key) || value.is_a?(String)) ? text(value).presence : value]
      end.compact
    end

    # Text XML 1.0 can hold: UTF-8 whatever the String's encoding, without invalid bytes or the control characters
    # XML forbids, trimmed.
    def text(value)
      string = value.to_s
      string = (string.encoding == Encoding::BINARY) ? string.dup.force_encoding(Encoding::UTF_8) : string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      string.scrub("").gsub(XML_FORBIDDEN, "").strip
    end

    # At most limit characters as a reader counts them: an accent stays with its letter.
    def cut(text, limit)
      (text.length > limit) ? text.grapheme_clusters.first(limit).join : text
    end

    # An Integer, a whole Float, or a String of decimal digits, as an Integer; nil for anything else.
    def whole_number(value)
      case value
      when Integer then value
      when Float then value.to_i if value.finite? && value == value.to_i
      when String then Integer(value, 10, exception: false)
      end
    end

    # A W3C date with at least its day, as the video and news schemas want, or nil.
    def full_date(value)
      stamp = timestamp(value)
      stamp if stamp&.match?(/\A\d{4}-\d{2}-\d{2}/)
    end

    # Google News takes ISO 639 codes, and zh-cn or zh-tw for Chinese: the script decides, else the region.
    def news_language(hreflang)
      language, *subtags = hreflang.downcase.split("-")
      return language unless language == "zh"
      return "zh-tw" if subtags.include?("hant")
      return "zh-cn" if subtags.include?("hans")

      (subtags & TRADITIONAL_CHINESE).any? ? "zh-tw" : "zh-cn"
    end

    def sitemap_entry(url, lastmod)
      "<sitemap><loc>#{escape(url)}</loc>#{lastmod_tag(lastmod)}</sitemap>\n"
    end

    # The W3C date or time of a lastmod, in UTC, or nil when it is not one.
    def timestamp(value)
      case value
      when nil then nil
      when DateTime then value.to_time.getutc.iso8601
      when Date then value.iso8601
      when String then w3c_timestamp(value)
      else value.getutc.iso8601 if value.respond_to?(:getutc)
      end
    end

    def w3c_timestamp(text)
      if (date = W3C_DATE.match(text))
        year, month, day = date.captures
        text if Date.valid_date?(year.to_i, (month || 1).to_i, (day || 1).to_i)
      elsif (time = W3C_TIME.match(text))
        year, month, day, hour, minute, second, zone = time.captures
        return unless Date.valid_date?(year.to_i, month.to_i, day.to_i)

        Time.new(year.to_i, month.to_i, day.to_i, hour.to_i, minute.to_i, second.to_i, (zone == "Z") ? "UTC" : zone).getutc.iso8601
      end
    rescue ArgumentError
      nil
    end

    # A date alone is the day as it starts first, at UTC+14: no time zone has it in the future after that.
    def time(stamp)
      return Time.iso8601(stamp) if stamp.include?("T")

      year, month, day = stamp.split("-").map(&:to_i)
      Time.new(year, month || 1, day || 1, 0, 0, 0, "+14:00")
    end

    # Rails locales spell regions with an underscore (pt_BR), hreflang with a hyphen (pt-BR).
    def hreflang(locale)
      locale.to_s.tr("_", "-")
    end

    # The <loc> of each <url> of a sitemap file.
    def locations(xml)
      xml.scan(LOCATION).map { |(location)| location.gsub(/&(?:amp|lt|gt|quot|apos);/, UNESCAPED_BY_ENTITY) }
    end

    def escape(text)
      text.to_s.encode(xml: :text).gsub('"', "&quot;")
    end

    def lastmod_tag(stamp)
      stamp ? "<lastmod>#{escape(stamp)}</lastmod>" : ""
    end

    def alternates(page, x_default)
      return "" if page.url_by_locale.size < 2

      links = page.url_by_locale.map { |locale, url| alternate(locale, url) }
      default_url = page.url_by_locale[x_default]
      links << alternate("x-default", default_url) if default_url
      links.join
    end

    def alternate(hreflang, url)
      %(<xhtml:link rel="alternate" hreflang="#{escape(hreflang)}" href="#{escape(url)}"/>)
    end

    def images(urls)
      urls.first(MAX_IMAGES_PER_URL).map { |url| "<image:image><image:loc>#{escape(url)}</image:loc></image:image>" }.join
    end
  end
end
