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
    assert(messages.any? { |message| message.include?("publication_date that is not a full W3C date") })
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

  def test_false_and_nil_are_no_video
    Maptain.configuration.sources = [video_source { |post| (post.id == 1) ? false : [nil, VIDEO] }]
    create_post(1)
    create_post(2)
    warnings = build.warnings

    assert_equal 2, storage.xml("sitemap-video-00000.xml.gz").scan("<video:video>").size
    assert_empty warnings
  end

  def test_forbidden_characters_and_invalid_utf8_are_dropped
    Maptain.configuration.sources = [video_source { VIDEO.merge(title: "Pl\u0000ay \v", description: "caf\xE9 au lait") }]
    create_post(1)
    build
    xml = storage.xml("sitemap-video-00000.xml.gz")

    assert_includes xml, "<video:title>Play</video:title><video:description>caf au lait</video:description>"
  end

  def test_tags_follow_the_schema_order_and_long_titles_are_cut
    Maptain.configuration.sources = [video_source do
      VIDEO.merge(title: "t" * 150, publication_date: "2026-11-01", expiration_date: "2027-11-01T00:00:00Z", duration: "90")
    end]
    create_post(1)
    build
    xml = storage.xml("sitemap-video-00000.xml.gz")

    assert_includes xml, "<video:title>#{"t" * 100}</video:title>"
    assert_includes xml, "<video:duration>90</video:duration><video:expiration_date>2027-11-01T00:00:00Z</video:expiration_date>" \
      "<video:publication_date>2026-11-01</video:publication_date></video:video>"
  end

  def test_a_malformed_duration_a_partial_date_or_the_page_as_player_are_left_out
    Maptain.configuration.sources = [video_source do |post|
      case post.id
      when 1 then VIDEO.merge(duration: "1e4")
      when 2 then VIDEO.merge(publication_date: "2026-11")
      else VIDEO.merge(player_loc: "https://example.com/en/posts/3")
      end
    end]
    (1..3).each { |id| create_post(id) }
    messages = build.warnings.map(&:message)

    # Only the French page of post 3 keeps its video: its player is the English page, not itself.
    assert_equal 1, storage.xml("sitemap-video-00000.xml.gz").scan("<video:video>").size
    assert(messages.any? { |message| message.include?("lasting \"1e4\" seconds") })
    assert(messages.any? { |message| message.include?("not a full W3C date") })
    assert(messages.any? { |message| message.include?("is the page itself") })
  end

  def test_blank_optional_fields_are_left_out
    Maptain.configuration.sources = [video_source { VIDEO.merge(duration: "", publication_date: " ") }]
    create_post(1)
    build

    assert_includes storage.xml("sitemap-video-00000.xml.gz"), "<video:player_loc>https://player.example.com/1</video:player_loc></video:video>"
  end

  def test_chinese_news_languages_are_the_two_google_takes
    assert_equal "zh-cn", Maptain::Xml.news_language("zh-hans")
    assert_equal "zh-tw", Maptain::Xml.news_language("zh-hant-tw")
    assert_equal "zh-tw", Maptain::Xml.news_language("zh-hk")
    assert_equal "zh-cn", Maptain::Xml.news_language("zh-cn")
    assert_equal "zh", Maptain::Xml.news_language("zh")
  end

  def test_a_given_news_language_is_spelled_as_google_wants
    Maptain.configuration.sources = [source("NewsSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      news { |post| {name: "Example News", title: post.title, publication_date: "2026-11-24", language: "pt_BR"} }
    end]
    create_post(1)
    build

    assert_includes storage.xml("sitemap-news-00000.xml.gz"), "<news:language>pt</news:language>"
  end

  def test_a_news_source_gets_files_of_at_most_a_thousand_articles
    Maptain.configuration.sources = [source("NewsSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      news { |post| {name: "Example News", title: post.title, publication_date: "2026-11-24"} }
    end]
    Post.insert_all((1..1_200).map { |id| {id:, title: "Post #{id}", created_at: LONG_AGO, updated_at: LONG_AGO} })
    build
    news_counts = storage.content_by_name.keys.grep(/\Asitemap-news-/).map { |name| storage.xml(name).scan("<news:news>").size }

    assert_operator news_counts.max, :<=, 1_000
    assert_equal 2_400, news_counts.sum
  end

  private

  VIDEO = {title: "Video", description: "About it", thumbnail_loc: "/t.jpg", player_loc: "https://player.example.com/1"}.freeze

  def video_source(&video)
    source("VideoSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      video(&video)
    end
  end

  def source(name, &definition)
    Class.new(Maptain::Source) do
      define_singleton_method(:name) { name }
      class_eval(&definition)
    end
  end
end
