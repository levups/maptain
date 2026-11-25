# frozen_string_literal: true

require "test_helper"

class MediaTest < MaptainTest
  def test_a_video_is_written_in_each_language_with_its_translated_fields
    I18n.available_locales = %i[en fr]
    Maptain.configuration.sources = [source("VideoSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      video do |post, locale|
        {title: "#{post.title} (#{I18n.locale})", description: "About <#{post.title}>", thumbnail_loc: "/thumbs/#{post.id}.jpg",
         player_loc: "https://player.example.com/#{post.id}?lang=#{locale}&autoplay=0", duration: 90}
      end
    end]
    create_post(1)
    build

    xml = storage.xml("sitemap-video-00000.xml.gz")

    assert_includes xml, "<url><loc>https://example.com/fr/posts/1</loc><lastmod>2026-01-01T12:00:00Z</lastmod>"
    assert_includes xml, "<video:video><video:thumbnail_loc>https://example.com/thumbs/1.jpg</video:thumbnail_loc>" \
      "<video:title>Post 1 (fr)</video:title><video:description>About &lt;Post 1&gt;</video:description>" \
      "<video:player_loc>https://player.example.com/1?lang=fr&amp;autoplay=0</video:player_loc>" \
      "<video:duration>90</video:duration></video:video></url>"
    assert_includes xml, "<video:title>Post 1 (en)</video:title>"
  ensure
    I18n.available_locales = nil
  end

  def test_a_video_missing_a_required_field_is_left_out_with_a_warning
    Maptain.configuration.sources = [source("VideoSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      video { |post| {title: post.title, description: "About it", player_loc: "https://player.example.com/#{post.id}"} }
    end]
    create_post(1)
    create_post(2)
    warnings = build.warnings

    refute_includes storage.xml("sitemap-video-00000.xml.gz"), "<video:video>"
    warning = warnings.find { |found| found.message.include?("without thumbnail_loc") }

    assert_equal "https://example.com/en/posts/1", warning.url
    assert_equal 3, warning.others
  end

  def test_a_nil_video_adds_nothing_and_an_array_adds_several
    Maptain.configuration.sources = [source("VideoSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      video do |post|
        next if post.id == 1

        Array.new(2) { |index| {title: "Part #{index}", description: "d", thumbnail_loc: "/t.jpg", content_loc: "/v#{index}.mp4"} }
      end
    end]
    create_post(1)
    create_post(2)
    build
    xml = storage.xml("sitemap-video-00000.xml.gz")

    assert_equal 4, xml.scan("<video:video>").size
    assert_includes xml, "<video:content_loc>https://example.com/v1.mp4</video:content_loc>"
  end

  def test_unknown_fields_a_bad_duration_or_date_are_warned_about
    Maptain.configuration.sources = [source("VideoSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      video do |post|
        base = {title: "t", description: "d", thumbnail_loc: "/t.jpg", player_loc: "/p"}
        case post.id
        when 1 then base.merge(rating: 5)
        when 2 then base.merge(duration: 0)
        else base.merge(publication_date: "yesterday")
        end
      end
    end]
    (1..3).each { |id| create_post(id) }
    messages = build.warnings.map(&:message)

    assert(messages.any? { |message| message.include?(":rating") })
    assert(messages.any? { |message| message.include?("lasting 0 seconds") })
    assert(messages.any? { |message| message.include?("publication_date that is not a W3C date") })
  end

  def test_news_is_written_with_the_language_of_each_url
    Maptain.configuration.locales = %i[en pt_BR]
    Maptain.configuration.sources = [source("NewsSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      news { |post| {name: "Example News", title: post.title, publication_date: Date.new(2026, 11, 24)} }
    end]
    create_post(1, languages: "en,pt_BR")
    build
    xml = storage.xml("sitemap-news-00000.xml.gz")

    assert_includes xml, "<news:news><news:publication><news:name>Example News</news:name><news:language>pt</news:language>" \
      "</news:publication><news:publication_date>2026-11-24</news:publication_date><news:title>Post 1</news:title></news:news></url>"
    assert_includes xml, "<news:language>en</news:language>"
  end

  def test_news_language_keeps_the_region_for_chinese_only
    assert_equal "zh-tw", Maptain::Xml.news_language("zh-TW")
    assert_equal "pt", Maptain::Xml.news_language("pt-BR")
  end

  def test_news_without_a_date_is_left_out_with_a_warning
    Maptain.configuration.sources = [source("NewsSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      news { |post| {name: "Example News", title: post.title} }
    end]
    create_post(1)
    warnings = build.warnings

    refute_includes storage.xml("sitemap-news-00000.xml.gz"), "<news:news>"
    assert(warnings.any? { |warning| warning.message.include?("news without publication_date") })
  end

  def test_an_article_that_leaves_a_two_day_scope_rewrites_its_file
    Maptain.configuration.sources = [source("NewsSitemap") do
      scope { Post.published.where(created_at: Time.utc(2026, 11, 23)..) }
      url { |post, locale| post_url(post, locale:) }
      news { |post| {name: "Example News", title: post.title, publication_date: post.created_at} }
    end]
    Post.create!(id: 1, title: "Fresh", created_at: Time.utc(2026, 11, 24), updated_at: Time.utc(2026, 11, 24))
    build

    assert_includes storage.xml("sitemap-news-00000.xml.gz"), "<news:title>Fresh</news:title>"

    Post.find(1).update_columns(created_at: Time.utc(2026, 11, 20))
    build

    refute storage.content_by_name.key?("sitemap-news-00000.xml.gz")
  end

  private

  def source(name, &definition)
    Class.new(Maptain::Source) do
      define_singleton_method(:name) { name }
      class_eval(&definition)
    end
  end
end
