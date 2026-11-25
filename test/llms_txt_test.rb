# frozen_string_literal: true

require "test_helper"

class FeaturedPostSitemap < Maptain::Source
  scope { Post.published }
  url { |post, locale| post_url(post, locale:) }
  locales { |post| post.languages.split(",").map(&:to_sym) }
  llms_txt("Posts", scope: -> { Post.published.order(:id).limit(3) }) { |post| [post.title, "Written in #{I18n.locale}"] }
end

class AboutSitemap < Maptain::Source
  scope { %i[about] }
  url { |page, locale| about_path(locale:) }
  llms_txt("Pages") { |page| page.to_s.capitalize }
end

class LlmsTxtTest < MaptainTest
  def setup
    super
    Maptain.configure do |config|
      config.sources = [FeaturedPostSitemap, AboutSitemap]
      config.llms_txt = {title: "Example", summary: "A blog about examples."}
    end
  end

  def test_a_build_writes_the_llms_txt_of_the_sources_that_list_records_in_it
    create_post(1)
    create_post(2, languages: "fr")
    built = build

    assert_equal <<~MARKDOWN, storage.content_by_name.fetch("llms.txt")
      # Example

      > A blog about examples.

      ## Posts

      - [Post 1](https://example.com/en/posts/1): Written in en

      ## Pages

      - [About](https://example.com/en/about)
    MARKDOWN
    assert_includes built.written, "llms.txt"
    assert_empty built.warnings
  end

  def test_no_llms_txt_without_the_setting
    Maptain.configuration.llms_txt = nil
    create_post(1)
    build

    refute storage.content_by_name.key?("llms.txt")
  end

  def test_it_is_written_again_only_when_it_changes
    create_post(1)
    build
    built = build

    refute_includes storage.writes, "llms.txt"
    assert_includes built.kept, "llms.txt"

    Post.find(1).update!(title: "Post one", updated_at: Time.utc(2026, 2, 1))
    build

    assert_includes storage.writes, "llms.txt"
    assert_includes storage.content_by_name.fetch("llms.txt"), "- [Post one](https://example.com/en/posts/1)"
  end

  def test_a_full_build_writes_it_again
    create_post(1)
    build
    build(full: true)

    assert_includes storage.writes, "llms.txt"
  end

  def test_it_is_deleted_once_the_setting_is_gone
    create_post(1)
    build
    Maptain.configuration.llms_txt = nil
    build

    assert_includes storage.deletions, "llms.txt"
    refute storage.content_by_name.key?("llms.txt")
  end

  def test_it_is_in_one_language_and_its_blocks_run_in_it
    I18n.available_locales = %i[en fr]
    Maptain.configuration.llms_txt = {title: -> { "Example (#{I18n.locale})" }, locale: :fr}
    create_post(1)
    create_post(2, languages: "en")
    build

    assert_equal <<~MARKDOWN, storage.content_by_name.fetch("llms.txt")
      # Example (fr)

      ## Posts

      - [Post 1](https://example.com/fr/posts/1): Written in fr

      ## Pages

      - [About](https://example.com/fr/about)
    MARKDOWN
  ensure
    I18n.available_locales = nil
  end

  def test_brackets_line_breaks_and_parentheses_cannot_break_a_link
    create_post(1, title: "Post [one]\nwith (parentheses)")
    build

    assert_includes storage.content_by_name.fetch("llms.txt"),
      "- [Post \\[one\\] with (parentheses)](https://example.com/en/posts/1): Written in en"
  end

  def test_a_link_outside_the_site_is_a_warning
    outside = Class.new(AboutSitemap) do
      def self.name = "OutsideSitemap"
      url { "https://elsewhere.example.org/about" }
    end
    Maptain.configuration.sources = [outside]
    warnings = build.warnings

    assert(warnings.any? { |warning| warning.source == "llms.txt" && warning.url == "https://elsewhere.example.org/about" })
  end

  def test_too_many_links_is_a_warning
    many = Class.new(AboutSitemap) do
      def self.name = "ManySitemap"
      scope { (1..Maptain::LlmsTxt::MAX_LINKS + 1).to_a }
      url { |number, locale| "/pages/#{number}" }
    end
    Maptain.configuration.sources = [many]
    warnings = build.warnings

    assert(warnings.any? { |warning| warning.source == "llms.txt" && warning.message.include?("more than 200") })
  end

  def test_check_renders_it_without_writing_it
    create_post(1)

    assert_empty Maptain.check
    assert_empty storage.writes
  end

  def test_the_app_serves_the_file_from_the_storage
    create_post(1)
    build
    status, headers, body = Maptain::LlmsTxt::App.new.call({})

    assert_equal 200, status
    assert_equal "text/plain; charset=utf-8", headers["content-type"]
    assert_equal storage.content_by_name.fetch("llms.txt"), body.join
  end

  def test_the_app_answers_404_before_the_first_build
    status, _headers, _body = Maptain::LlmsTxt::App.new.call({})

    assert_equal 404, status
  end

  def test_a_title_is_required
    assert_raises(Maptain::ConfigurationError) { Maptain.configuration.llms_txt = {title: ""} }
  end

  def test_a_source_needs_a_block_for_its_entries
    assert_raises(Maptain::SourceError) { Class.new(Maptain::Source) { llms_txt "Posts" } }
  end
end
