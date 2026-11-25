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
    # https://developers.google.com/search/docs/crawling-indexing/sitemaps/news-sitemap
    NEWS_KEYS = %i[name language title publication_date].freeze
    # https://www.w3.org/TR/NOTE-datetime: a year, a month, a day, or a time with its zone.
    W3C_DATE = /\A(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?\z/
    W3C_TIME = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})\z/

    LOCATION = %r{<loc>([^<]*)</loc>}
    UNESCAPED_BY_ENTITY = {"&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => '"', "&apos;" => "'"}.freeze

    module_function

    # One <url> per language. Each lists every language of the page, itself included: search engines drop
    # hreflang links that are not returned by the page they point to.
    # Videos and news, written in each language, close the <url> of their language.
    def url_entries(page, x_default:)
      shared = "#{lastmod_tag(page.lastmod)}#{alternates(page, x_default)}#{images(page.images)}"
      if page.media_by_locale.empty?
        shared = "#{shared}</url>\n"
        return page.urls.map { |url| "<url><loc>#{escape(url)}</loc>#{shared}" }
      end

      entries = page.url_by_locale.uniq { |_hreflang, url| url }
      entries.map! { |hreflang, url| "<url><loc>#{escape(url)}</loc>#{shared}#{page.media_by_locale[hreflang]}</url>\n" }
    end

    # A <video:video>, or the reason it cannot be one. Locations are absolute already.
    def video(fields)
      unknown = fields.keys - VIDEO_KEYS
      return [nil, "has a video with #{unknown.first.inspect}, not one of #{VIDEO_KEYS.join(", ")}"] if unknown.any?

      missing = %i[thumbnail_loc title description].reject { |key| fields[key].present? }
      missing << :player_loc unless fields[:content_loc].present? || fields[:player_loc].present?
      return [nil, "has a video without #{missing.first}, left out"] if missing.any?

      duration = fields[:duration]
      if duration && !duration.to_i.between?(1, MAX_VIDEO_DURATION_SECONDS)
        return [nil, "has a video lasting #{duration.inspect} seconds, not 1 to #{MAX_VIDEO_DURATION_SECONDS}, left out"]
      end

      dates = %i[publication_date expiration_date].to_h { |key| [key, fields[key] && timestamp(fields[key])] }
      rejected = dates.find { |key, stamp| fields[key] && stamp.nil? }
      return [nil, "has a video #{rejected.first} that is not a W3C date (#{fields[rejected.first].inspect}), left out"] if rejected

      description = fields[:description].to_s.strip[0, MAX_VIDEO_DESCRIPTION_CHARACTERS]
      tags = "<video:thumbnail_loc>#{escape(fields[:thumbnail_loc])}</video:thumbnail_loc>" \
        "<video:title>#{escape(fields[:title].to_s.strip)}</video:title>" \
        "<video:description>#{escape(description)}</video:description>"
      tags << "<video:content_loc>#{escape(fields[:content_loc])}</video:content_loc>" if fields[:content_loc].present?
      tags << "<video:player_loc>#{escape(fields[:player_loc])}</video:player_loc>" if fields[:player_loc].present?
      tags << "<video:duration>#{duration.to_i}</video:duration>" if duration
      dates.each { |key, stamp| tags << "<video:#{key}>#{escape(stamp)}</video:#{key}>" if stamp }
      ["<video:video>#{tags}</video:video>", nil]
    end

    # A <news:news>, or the reason it cannot be one. language is the hreflang's language when not given.
    def news(fields, hreflang)
      unknown = fields.keys - NEWS_KEYS
      return [nil, "has news with #{unknown.first.inspect}, not one of #{NEWS_KEYS.join(", ")}"] if unknown.any?

      missing = %i[name title publication_date].reject { |key| fields[key].present? }
      return [nil, "has news without #{missing.first}, left out"] if missing.any?

      published = timestamp(fields[:publication_date])
      return [nil, "has news whose publication_date is not a W3C date (#{fields[:publication_date].inspect}), left out"] unless published

      ["<news:news><news:publication><news:name>#{escape(fields[:name])}</news:name>" \
        "<news:language>#{escape(fields[:language] || news_language(hreflang))}</news:language></news:publication>" \
        "<news:publication_date>#{escape(published)}</news:publication_date>" \
        "<news:title>#{escape(fields[:title].to_s.strip)}</news:title></news:news>", nil]
    end

    # Google News takes ISO 639 codes, and zh-cn or zh-tw for Chinese.
    def news_language(hreflang)
      language, region = hreflang.downcase.split("-", 2)
      (language == "zh" && region) ? "zh-#{region}" : language
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
