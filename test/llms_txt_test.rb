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

  def test_one_a_build_died_after_writing_is_written_again_even_with_its_records_back
    create_post(1)
    build
    Post.find(1).update!(title: "Post one")
    failing = Class.new(MemoryStorage) do
      def write(name, source_path)
        raise IOError, "connection reset" if writes.include?("llms.txt")

        super
      end
    end.new
    failing.content_by_name.merge!(storage.content_by_name)
    Maptain.configuration.storage = failing

    assert_raises(IOError) { Maptain.build }
    Post.find(1).update!(title: "Post 1")
    @storage = MemoryStorage.new
    storage.content_by_name.merge!(failing.content_by_name)
    Maptain.configuration.storage = storage

    assert_includes build.written, "llms.txt"
    assert_includes storage.content_by_name.fetch("llms.txt"), "- [Post 1](https://example.com/en/posts/1)"
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
    Maptain.configuration.sources = [source("OutsideSitemap") do
      scope { %i[about] }
      url { "https://elsewhere.example.org/about" }
      llms_txt("Pages") { "About" }
    end]
    warnings = build.warnings

    assert(warnings.any? { |warning| warning.source == "llms.txt" && warning.url == "https://elsewhere.example.org/about" })
  end

  def test_too_many_links_is_a_warning_and_a_relation_is_never_loaded_whole
    Post.insert_all((1..1000).map { |id| {id:, title: "Post #{id}", created_at: LONG_AGO, updated_at: LONG_AGO} })
    Maptain.configuration.sources = [source("AllPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      llms_txt("Posts") { |post| post.title }
    end]
    llms_txt_rows = 0
    counting = ->(*, payload) { llms_txt_rows += payload[:record_count] if payload[:class_name] == "Post" }
    ActiveSupport::Notifications.subscribed(counting, "instantiation.active_record") do
      Maptain.configuration.sources.first.new(Maptain.configuration).llms_txt_entries(:en)
    end
    warnings = build.warnings

    assert(warnings.any? { |warning| warning.source == "llms.txt" && warning.message.include?("more than 200 links") })
    assert_equal 200, storage.content_by_name.fetch("llms.txt").scan(/^- /).size
    assert_equal 201, llms_txt_rows
  end

  def test_records_left_out_do_not_take_the_place_of_others
    Post.insert_all((1..250).map { |id| {id:, title: "Post #{id}", languages: "fr", created_at: LONG_AGO, updated_at: LONG_AGO} })
    create_post(251, languages: "en")
    Maptain.configuration.sources = [source("AllPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      locales { |post| post.languages.split(",").map(&:to_sym) }
      llms_txt("Posts") { |post| post.title }
    end]
    build

    assert_includes storage.content_by_name.fetch("llms.txt"), "- [Post 251](https://example.com/en/posts/251)"
  end

  def test_reading_stops_at_max_records_with_a_warning
    Post.insert_all((1..2_100).map { |id| {id:, title: "Post #{id}", languages: "fr", created_at: LONG_AGO, updated_at: LONG_AGO} })
    create_post(2_101, languages: "en")
    Maptain.configuration.sources = [source("AllPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      locales { |post| post.languages.split(",").map(&:to_sym) }
      llms_txt("Posts") { |post| post.title }
    end]
    warnings = build.warnings

    assert(warnings.any? { |warning| warning.source == "all_post" && warning.message.include?("read 2000 records") })
    refute_includes storage.content_by_name.fetch("llms.txt"), "Post 2101"
  end

  def test_an_offset_scope_keeps_its_offset
    (1..5).each { |id| create_post(id) }
    Maptain.configuration.sources = [source("LatestPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      llms_txt("Posts", scope: -> { Post.order(:id).offset(3) }) { |post| post.title }
    end]
    build

    assert_equal ["Post 4", "Post 5"], storage.content_by_name.fetch("llms.txt").scan(/\[(Post \d)\]/).flatten
  end

  def test_a_missing_translation_in_a_section_or_with_options_is_left_out
    Maptain.configuration.sources = [source("TranslatedSitemap") do
      scope { %i[about] }
      url { |_page, locale| about_path(locale:) }
      llms_txt(-> { I18n.t("sitemaps.pages") }) { "About" }
    end, source("OptionsSitemap") do
      scope { %i[about] }
      url { |_page, locale| about_path(locale:) }
      llms_txt("Pages") { I18n.t("pages.about", default: [:"pages.other"]) }
    end]
    build

    refute_includes storage.content_by_name.fetch("llms.txt"), "Translation missing"
    refute_includes storage.content_by_name.fetch("llms.txt"), "## "
  end

  def test_a_relation_with_a_join_is_ordered_without_ambiguity
    create_post(1)
    Maptain.configuration.sources = [source("JoinedPostSitemap") do
      scope { Post.published.joins("LEFT JOIN posts AS others ON others.id = posts.id") }
      url { |post, locale| post_url(post, locale:) }
      llms_txt("Posts") { |post| post.title }
    end]
    build

    assert_includes storage.content_by_name.fetch("llms.txt"), "- [Post 1]"
  end

  def test_a_block_that_raises_stops_the_build_before_it_publishes_anything
    create_post(1)
    Maptain.configuration.sources = [source("FailingSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      llms_txt("Posts") { |_post| raise "no title" }
    end]

    assert_raises(RuntimeError) { build }
    assert_empty storage.writes - ["sitemap-manifest.json"]
  end

  def test_a_missing_translation_is_left_out
    Maptain.configuration.llms_txt = {title: -> { I18n.t("llms_txt.title") }, summary: -> { I18n.t("llms_txt.summary") }}
    create_post(1)
    build

    refute_includes storage.content_by_name.fetch("llms.txt"), "Translation missing"
    assert storage.content_by_name.fetch("llms.txt").start_with?("# https://example.com\n")
  end

  def test_false_is_no_llms_txt
    Maptain.configuration.llms_txt = false
    create_post(1)
    build

    refute storage.content_by_name.key?("llms.txt")
    assert_equal 404, Maptain::LlmsTxt::App.new.call({}).first
  end

  def test_a_record_language_spelled_otherwise_links_to_the_sitemap_url
    Maptain.configuration.locales = %i[en pt_BR]
    Maptain.configuration.llms_txt = {title: "Example", locale: :pt_BR}
    create_post(1, languages: "pt-BR")
    build

    assert_includes storage.xml("sitemap-featured_post-00000.xml.gz"), "https://example.com/pt-BR/posts/1"
    assert_includes storage.content_by_name.fetch("llms.txt"), "(https://example.com/pt-BR/posts/1)"
  end

  def test_a_relation_without_order_or_limit_is_read_in_id_order_and_bounded
    create_post(3)
    create_post(1)
    create_post(2)
    Maptain.configuration.sources = [source("AllPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      llms_txt("Posts") { |post| post.title }
    end]
    build

    assert_match(/Post 1.*\n.*Post 2.*\n.*Post 3/, storage.content_by_name.fetch("llms.txt"))
  end

  def test_a_subclass_does_not_list_its_parent_records_again
    Maptain.configuration.sources = [AboutSitemap, Class.new(AboutSitemap) { slug "other" }]
    build

    assert_equal 1, storage.content_by_name.fetch("llms.txt").scan("[About]").size
  end

  def test_a_locale_spelled_otherwise_is_the_sitemap_one
    Maptain.configuration.locales = %i[en pt_BR]
    Maptain.configuration.llms_txt = {title: "Example", locale: "pt-BR"}
    create_post(1, languages: "pt_BR")
    build

    assert_includes storage.content_by_name.fetch("llms.txt"), "(https://example.com/pt_BR/posts/1)"
  end

  def test_a_locale_outside_the_site_fails_the_build
    Maptain.configuration.llms_txt = {title: "Example", locale: :de}

    assert_raises(Maptain::ConfigurationError) { build }
  end

  def test_backticks_and_tags_cannot_break_a_link
    create_post(1, title: "Use `x <b>")
    build

    assert_includes storage.content_by_name.fetch("llms.txt"), "- [Use \\`x \\<b>](https://example.com/en/posts/1)"
  end

  def test_a_blank_title_leaves_the_record_out
    create_post(1, title: " ")
    build

    refute_includes storage.content_by_name.fetch("llms.txt"), "posts/1"
  end

  def test_rich_text_is_listed_as_its_text
    rich = Struct.new(:body) do
      def to_s
        %(<div class="trix-content">#{body}</div>)
      end

      def to_plain_text
        body
      end
    end
    Maptain.configuration.sources = [source("RichSitemap") do
      scope { %i[about] }
      url { |page, locale| about_path(locale:) }
      llms_txt("Pages") { [rich.new("About us"), rich.new("Who we are")] }
    end]
    Maptain.configuration.llms_txt = {title: "Example", details: rich.new("Prices include VAT.")}
    build

    assert_equal <<~MARKDOWN, storage.content_by_name.fetch("llms.txt")
      # Example

      Prices include VAT.

      ## Pages

      - [About us](https://example.com/en/about): Who we are
    MARKDOWN
  end

  def test_check_renders_it_without_writing_it
    Maptain.configuration.sources = [source("OutsideSitemap") do
      scope { %i[about] }
      url { "https://elsewhere.example.org/about" }
      llms_txt("Pages") { "About" }
    end]

    assert(Maptain.check.any? { |warning| warning.source == "llms.txt" })
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

  def test_the_app_answers_404_before_the_first_build_with_headers_middleware_can_change
    status, headers, _body = Maptain::LlmsTxt::App.new.call({})
    headers["x-request-id"] = "1"

    assert_equal 404, status
  end

  def test_the_app_answers_503_while_the_storage_is_unreachable_and_it_has_no_copy
    storage.define_singleton_method(:read) { |_name| raise IOError, "unreachable" }
    app = Maptain::LlmsTxt::App.new

    assert_equal 503, app.call({}).first
    assert_equal 503, app.call({}).first
  end

  def test_a_request_during_the_first_read_reads_the_file_too
    create_post(1)
    build
    app = Maptain::LlmsTxt::App.new
    app.instance_variable_get(:@cached_by_name)["llms.txt"] = Maptain::LlmsTxt::App::Cached.new(nil, 0, true, nil)
    app.instance_variable_get(:@cached_by_name)["llms.txt"].expires_at = Float::INFINITY

    assert_equal 200, app.call({}).first
  end

  def test_a_file_not_there_yet_is_asked_for_again_soon
    app = Maptain::LlmsTxt::App.new
    app.call({})

    assert_operator app.instance_variable_get(:@cached_by_name).fetch("llms.txt").expires_at,
      :<=, Process.clock_gettime(Process::CLOCK_MONOTONIC) + Maptain::LlmsTxt::App::RETRY_SECONDS
  end

  def test_the_app_reads_the_storage_once_per_ttl_and_serves_its_copy_when_the_storage_fails
    create_post(1)
    build
    app = Maptain::LlmsTxt::App.new
    app.call({})
    storage.content_by_name["llms.txt"] = "changed"

    assert_includes app.call({}).last.join, "# Example"

    reads = 0
    storage.define_singleton_method(:read) do |_name|
      reads += 1
      raise IOError, "unreachable"
    end
    app.instance_variable_get(:@cached_by_name).fetch("llms.txt").expires_at = 0

    assert_includes app.call({}).last.join, "# Example"
    assert_includes app.call({}).last.join, "# Example"
    assert_equal 1, reads
  end

  def test_one_host_per_language_gets_one_file_per_host_in_its_language
    I18n.available_locales = %i[en fr de]
    Maptain.configure do |config|
      config.locales = %i[en fr de]
      config.host_by_locale = {de: "https://example.de"}
      config.llms_txt = {title: -> { "Example (#{I18n.locale})" }}
    end
    create_post(1, languages: "en,fr,de")
    build

    assert_nil storage.content_by_name["llms.txt"]
    assert_equal <<~MARKDOWN, storage.content_by_name.fetch("llms-en.txt")
      # Example (en)

      ## Posts

      - [Post 1](https://example.com/en/posts/1): Written in en

      ## Pages

      - [About](https://example.com/en/about)
    MARKDOWN
    assert_equal <<~MARKDOWN, storage.content_by_name.fetch("llms-de.txt")
      # Example (de)

      ## Posts

      - [Post 1](https://example.de/de/posts/1): Written in de

      ## Pages

      - [About](https://example.de/de/about)
    MARKDOWN
  ensure
    I18n.available_locales = nil
  end

  def test_the_app_serves_the_file_of_the_request_host
    Maptain.configuration.host_by_locale = {fr: "https://example.fr"}
    create_post(1)
    build
    app = Maptain::LlmsTxt::App.new

    assert_includes app.call("HTTP_HOST" => "example.fr").last.join, "https://example.fr/fr/posts/1"
    assert_includes app.call("HTTP_HOST" => "EXAMPLE.com:443").last.join, "https://example.com/en/posts/1"
    assert_equal 404, app.call("HTTP_HOST" => "elsewhere.example.org").first
    assert_includes app.call("HTTP_HOST" => "example.fr.").last.join, "https://example.fr/fr/posts/1"
    assert_includes app.call("HTTP_HOST" => "", "SERVER_NAME" => "example.fr").last.join, "https://example.fr/fr/posts/1"
    # A forged X-Forwarded-Host must not get another host's file cached for this one.
    assert_includes app.call("HTTP_HOST" => "example.com", "HTTP_X_FORWARDED_HOST" => "example.fr").last.join,
      "https://example.com/en/posts/1"
  end

  def test_moving_to_one_host_per_language_replaces_the_single_file
    create_post(1)
    build
    Maptain.configuration.host_by_locale = {fr: "https://example.fr"}
    build

    assert_includes storage.deletions, "llms.txt"
    assert_equal %w[llms-en.txt llms-fr.txt], storage.content_by_name.keys.grep(/\Allms/).sort
  end

  def test_a_title_is_required
    assert_raises(Maptain::ConfigurationError) { Maptain.configuration.llms_txt = {title: ""} }
  end

  def test_a_source_needs_a_block_for_its_entries_and_a_lambda_for_its_scope
    assert_raises(Maptain::SourceError) { Class.new(Maptain::Source) { llms_txt "Posts" } }
    assert_raises(Maptain::SourceError) { Class.new(Maptain::Source) { llms_txt("Posts", scope: Post.all) { "Post" } } }
  end

  def test_a_url_listed_again_does_not_count_against_the_limit
    Post.insert_all((1..300).map { |id| {id:, title: "Post #{id}", created_at: LONG_AGO, updated_at: LONG_AGO} })
    Maptain.configuration.sources = [source("JoinedPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      llms_txt("Posts", scope: -> { Post.joins("CROSS JOIN (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3)").order(:id) }) { |post| post.title }
    end]
    warnings = build.warnings

    assert_equal 200, storage.content_by_name.fetch("llms.txt").scan(/^- /).size
    assert(warnings.any? { |warning| warning.message.include?("more than 200 links") })
  end

  def test_a_scope_ending_at_max_records_is_not_cut_short
    Post.insert_all((1..2_000).map { |id| {id:, title: "Post #{id}", languages: "fr", created_at: LONG_AGO, updated_at: LONG_AGO} })
    Maptain.configuration.sources = [source("AllPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      locales { |post| post.languages.split(",").map(&:to_sym) }
      llms_txt("Posts") { |post| post.title }
    end]

    refute(build.warnings.any? { |warning| warning.message.include?("records without filling") })
  end

  def test_an_ordered_scope_is_read_in_one_query_of_at_most_max_records_plus_one
    Post.insert_all((1..2_500).map { |id| {id:, title: "Post #{id}", languages: "fr", created_at: LONG_AGO, updated_at: LONG_AGO} })
    source = source("OrderedPostSitemap") do
      scope { Post.published }
      url { |post, locale| post_url(post, locale:) }
      locales { |post| post.languages.split(",").map(&:to_sym) }
      llms_txt("Posts", scope: -> { Post.order(:title) }) { |post| post.title }
    end
    largest = 0
    counting = ->(*, payload) { largest = [largest, payload[:record_count]].max if payload[:class_name] == "Post" }
    ActiveSupport::Notifications.subscribed(counting, "instantiation.active_record") { source.new(Maptain.configuration).llms_txt_entries(:en) }

    assert_equal 2_001, largest
  end

  def test_hosts_that_differ_by_port_get_their_own_file
    Maptain.configure do |config|
      config.host = "http://localhost:3000"
      config.host_by_locale = {fr: "http://localhost:3001"}
    end
    create_post(1)
    build
    app = Maptain::LlmsTxt::App.new

    assert_includes app.call("HTTP_HOST" => "localhost:3001").last.join, "http://localhost:3001/fr/posts/1"
    assert_includes app.call("HTTP_HOST" => "localhost:3000").last.join, "http://localhost:3000/en/posts/1"
  end

  def test_a_lowercase_missing_translation_is_left_out
    refute Maptain::LlmsTxt.present?("translation missing: en.llms_txt.title")
    refute Maptain::LlmsTxt.present?("Translation missing. Options considered were:\n- en.a\n- en.b")
    assert Maptain::LlmsTxt.present?("Translation missing in Safari: a fix")
    assert Maptain::LlmsTxt.present?("Translation missing: Dr. No")
    assert Maptain::LlmsTxt.present?("Translation Missing: St. Louis edition")
    assert Maptain::LlmsTxt.present?("Translation missing: e.g. a novel")
    refute Maptain::LlmsTxt.present?("Translation missing: zh_Hant.llms.titre_é")
    assert Maptain::LlmsTxt.present?("Translations")
  end

  def test_requests_during_a_retry_after_a_failure_get_503_without_reading
    reads = 0
    storage.define_singleton_method(:read) do |_name|
      reads += 1
      raise IOError, "unreachable"
    end
    app = Maptain::LlmsTxt::App.new
    app.call({})
    app.instance_variable_get(:@cached_by_name).fetch("llms.txt").refreshing = true
    app.instance_variable_get(:@cached_by_name).fetch("llms.txt").expires_at = Float::INFINITY

    assert_equal 503, app.call({}).first
    assert_equal 1, reads
  end

  def test_a_configuration_mistake_is_raised_not_answered_503
    Maptain.configuration.host_by_locale = {fr: "https://example.fr"}
    Maptain.configuration.llms_txt = {title: "Example", locale: :de}

    assert_raises(Maptain::ConfigurationError) { Maptain::LlmsTxt::App.new.call("HTTP_HOST" => "example.fr") }
  end

  def test_string_keys_are_read_and_unknown_ones_refused
    Maptain.configuration.llms_txt = {"title" => "Example"}
    create_post(1)
    build

    assert storage.content_by_name.fetch("llms.txt").start_with?("# Example\n")
    assert_raises(Maptain::ConfigurationError) { Maptain.configuration.llms_txt = {title: "Example", sumary: "typo"} }
  end

  def test_a_storage_mistake_is_raised_and_an_outage_instrumented
    storage.define_singleton_method(:read) { |_name| raise NameError, "uninitialized constant Sitemaps" }

    assert_raises(NameError) { Maptain::LlmsTxt::App.new.call({}) }

    storage.define_singleton_method(:read) { |_name| raise IOError, "unreachable" }
    events = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { events << payload }, "storage_error.maptain") do
      assert_equal 503, Maptain::LlmsTxt::App.new.call({}).first
    end

    assert_equal ["llms.txt"], events.map { |payload| payload[:name] }
    assert_instance_of IOError, events.first[:exception_object]
  end

  def test_missing_translations_of_any_key_are_left_out
    Maptain.configuration.llms_txt = {title: -> { I18n.t("site.title?") }, summary: -> { I18n.t("llms_txt.résumé") }}
    create_post(1)
    build

    refute_includes storage.content_by_name.fetch("llms.txt"), "Translation missing"
    refute Maptain::LlmsTxt.present?("Translation missing: en.a.b c.x")
  end

  def test_a_cached_copy_is_served_whatever_a_refresh_raises
    create_post(1)
    build
    app = Maptain::LlmsTxt::App.new
    app.call({})
    reads = 0
    storage.define_singleton_method(:read) do |_name|
      reads += 1
      raise NoMethodError, "undefined method 'body' for nil"
    end
    app.instance_variable_get(:@cached_by_name).fetch("llms.txt").expires_at = 0

    assert_equal [200, 200, 200], Array.new(3) { app.call({}).first }
    assert_equal 1, reads
  end

  def test_a_code_mistake_keeps_raising_until_the_next_try
    storage.define_singleton_method(:read) { |_name| raise NameError, "uninitialized constant Sitemaps" }
    app = Maptain::LlmsTxt::App.new

    assert_raises(NameError) { app.call({}) }
    assert_raises(NameError) { app.call({}) }
  end

  private

  def source(name, &definition)
    Class.new(Maptain::Source) do
      define_singleton_method(:name) { name }
      class_eval(&definition)
    end
  end
end
