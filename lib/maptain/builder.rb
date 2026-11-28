# frozen_string_literal: true

module Maptain
  class Builder
    # full: whether this build rewrote everything, asked to or because rebuild_every had passed.
    Result = Data.define(:full, :written, :kept, :deleted, :url_count, :submitted, :warnings) do
      def changed?
        written.any? || deleted.any?
      end
    end

    # https://www.sitemaps.org/protocol.html
    MAX_URL_CHARACTERS = 2_048
    MAX_FILES_PER_INDEX = 50_000
    LAST_TIME_ZONE_OFFSET_SECONDS = 12 * 60 * 60
    DAY_LENGTH = "2026-01-01".length
    # One request's worth: what a refusing endpoint leaves in the manifest stays small.
    MAX_UNSUBMITTED_URLS = IndexNow::MAX_URLS_PER_REQUEST
    # A language, then maybe a script and a region: en, pt-BR, zh-Hant-TW, es-419.
    HREFLANG = /\A[a-z]{2,3}(-[a-z]{4})?(-([a-z]{2}|\d{3}))?\z/i

    Rendered = Data.define(:source_slug, :shard, :fingerprint, :files, :changed_urls)

    # others: how many more times its source made the same mistake.
    Warning = Data.define(:source, :url, :message, :others) do
      def to_s
        line = "#{source}: #{url} #{message}"
        others.zero? ? line : "#{line}, and #{others} more like it"
      end
    end

    def initialize(configuration, storage: configuration.storage, submit: true)
      @configuration = configuration
      @storage = storage
      @submit = submit
    end

    def build(full: false)
      ActiveSupport::Notifications.instrument("build.maptain", full:) do |payload|
        payload[:result] = Dir.mktmpdir("maptain") { |directory| build_in(directory, full:) }
        payload[:full] = payload[:result].full
        payload[:result]
      end
    end

    private

    def build_in(directory, full:)
      @configuration.validate!
      @directory = directory
      @previous = Manifest.read(@storage, manifest_name)
      @previous_file_by_name = @previous.files.to_h { |file| [file["name"], file] }
      built_at = Time.now
      @full = full || rebuild_due?(built_at)
      @reusable = !@full && @previous.digest == @configuration.digest
      @manifest = Manifest.new(digest: @configuration.digest, built_at:, rebuilt_at: @full ? built_at : @previous.rebuilt_at)
      @written = []
      @kept = []
      @warnings = []
      @changed_urls = []
      @checked_hreflangs = Set.new
      @reported = Set.new
      @warning_index_by_mistake = {}
      @x_default = Xml.hreflang(@configuration.x_default)
      @hosts = @configuration.hosts
      @host_prefixes = @hosts.map { |host| "#{host}/" }
      @outside_message = "is outside #{@hosts.first}#{" and the hosts of its other languages" if @hosts.size > 1}"
      @index_now = IndexNow.new(key: @configuration.index_now_key, key_path: @configuration.index_now_key_location)

      @rendered = []
      # The first build has no "before": submitting a whole site at once is not what IndexNow is for. Nor is a
      # new configuration, which rewrites every file: then only the lastmods tell what changed.
      @tracking = @submit && @configuration.index_now_key && @previous.built_at.present?
      @diffing = @tracking && @previous.digest == @configuration.digest
      @moved_sources = Set.new
      @news_sources = @configuration.sources.select { |source_class| source_class.definitions.key?(:news) }.to_set { |source_class| source_class.slug }

      llms_txt_sources = []
      @configuration.sources.each do |source_class|
        source = source_class.new(@configuration)
        build_source(source)
        llms_txt_sources << source if @configuration.llms_txt && source.llms_txt?
      end
      # Rendered before anything is published: a block that raises stops the build before it changes the storage.
      llms_txt_by_name = render_llms_txt(llms_txt_sources) if @configuration.llms_txt
      deleted = (@previous.file_names | @previous.pending | @previous.extras.keys) - @manifest.file_names -
        @rendered.flat_map { |rendered| rendered.files.map(&:name) } - llms_txt_by_name.to_h.keys
      @changed_urls.concat(@rendered.flat_map(&:changed_urls))
      # Not the pages of moved ranges, nor the articles of a news file gone because they grew old.
      @changed_urls.concat(urls_in(deleted.reject { |name| @moved_sources.include?(previous_source_of(name)) || @news_sources.include?(previous_source_of(name)) })) if @diffing
      urls = urls_to_submit
      publish_rendered(urls)
      publish_index
      publish_llms_txt(llms_txt_by_name) if llms_txt_by_name
      deleted.each { |name| @storage.delete(name) }
      publish_index_now_key
      # Written before submitting, with the URLs still to send: a build that dies while submitting loses none.
      @manifest.unsubmitted.replace(urls.last(MAX_UNSUBMITTED_URLS))
      upload(manifest_name, @manifest.to_json)
      submitted = submit(urls)

      Result.new(full: @full, written: @written, kept: @kept, deleted:, url_count: @manifest.files.sum { |file| file["urls"] },
        submitted:, warnings: @warnings)
    end

    def build_source(source)
      seen_urls = Set.new
      source.fingerprint_by_shard.sort_by { |shard, _fingerprint| shard.to_i }.each do |shard, fingerprint|
        stored = @previous.shard(source.slug, shard) if @reusable
        if fingerprint && stored && stored["fingerprint"] == fingerprint
          keep(source, shard, stored)
        else
          render(source, shard, fingerprint, seen_urls)
        end
      end
    end

    def keep(source, shard, stored)
      @manifest.record(source.slug, shard, fingerprint: stored["fingerprint"], files: stored["files"])
      @kept.concat(stored["files"].map { |file| file["name"] })
    end

    def render(source, shard, fingerprint, seen_urls)
      # Google reads no more than 1,000 news entries a file, whatever the shard size.
      max_urls = source.news? ? Xml::MAX_NEWS_PER_FILE : ShardWriter::MAX_URLS_PER_FILE
      writer = ShardWriter.new(directory: @directory, basename: source.basename(shard), max_urls:)
      changed_urls = []
      urls = [] if @diffing
      ActiveSupport::Notifications.instrument("shard.maptain", source: source.slug, shard:) do
        source.each_page(shard) do |page|
          inspect_page(source, page, seen_urls)
          writer.add(Xml.url_entries(page, x_default: @x_default), page.lastmod)
          changed_urls.concat(page.urls) if @tracking && changed_since_last_build?(page)
          urls&.concat(page.urls)
        end
        writer.close
      end

      if writer.files.all? { |file| same_as_before?(file) }
        changed_urls.clear
      elsif urls
        changed_urls.concat(appeared_or_gone(source.slug, shard, fingerprint, urls, gone: !source.news?))
      end
      fingerprint ||= writer.content_digest
      # Recorded now, published once every shard is rendered: the index keeps the order of the sources.
      @manifest.record(source.slug, shard, fingerprint:, files: [])
      @rendered << Rendered.new(source_slug: source.slug, shard:, fingerprint:, files: writer.files, changed_urls:)
    end

    # Read while the previous files are still in the storage: a page that appeared or went away is a change too,
    # whatever its lastmod says. Not when the ranges moved, which only carries pages from one file to another.
    # gone: false for news, whose articles leave when they grow old, not when their page does.
    def appeared_or_gone(source_slug, shard, fingerprint, urls, gone: true)
      stored = @previous.shard(source_slug, shard)
      if stored && fingerprint && stored["fingerprint"].to_s.split("/").first != fingerprint.split("/").first
        @moved_sources << source_slug
        return []
      end

      previous_urls = urls_in((stored&.fetch("files") || []).map { |file| file["name"] }).to_set
      urls = urls.to_set
      gone ? (urls - previous_urls).to_a + (previous_urls - urls).to_a : (urls - previous_urls).to_a
    end

    def publish_rendered(urls)
      changed_names = @rendered.flat_map(&:files).reject { |file| same_as_before?(file) }.to_set(&:name)
      announce(changed_names, urls)
      @rendered.each do |rendered|
        entries = rendered.files.map do |file|
          changed = changed_names.include?(file.name)
          publish(file, changed)
          manifest_entry(file, changed)
        end
        @manifest.record(rendered.source_slug, rendered.shard, fingerprint: rendered.fingerprint, files: entries)
      end
    end

    def previous_source_of(file_name)
      @previous_source_by_file_name ||= @previous.shards_by_source.each_with_object({}) do |(source_slug, shards), source_by_name|
        shards.each_value { |stored| stored["files"].each { |file| source_by_name[file["name"]] = source_slug } }
      end
      @previous_source_by_file_name[file_name]
    end

    def urls_in(names)
      names.flat_map do |name|
        content = @storage.read(name)
        content ? Xml.locations(Zlib.gunzip(content.b)) : []
      rescue Zlib::Error
        []
      end
    end

    def same_as_before?(file)
      @previous_file_by_name.dig(file.name, "digest") == file.digest
    end

    # Recorded before the first upload, so that a build dying midway leaves no file the next one cannot remove, and
    # no URL to submit it cannot find again: the files that told which pages appeared or went away are gone by then.
    def announce(names, urls = @previous.unsubmitted)
      new_names = names.to_a - @previous_file_by_name.keys - @previous.pending - @previous.extras.keys
      urls = urls.last(MAX_UNSUBMITTED_URLS)
      return if new_names.empty? && urls == @previous.unsubmitted

      @previous.pending.concat(new_names)
      @previous.unsubmitted.replace(urls)
      upload(manifest_name, @previous.to_json)
    end

    # A full build uploads every file, so that it also repairs a storage that lost one.
    def publish(file, changed)
      if changed || @full
        @storage.write(file.name, file.path)
        @written << file.name
      else
        @kept << file.name
      end
      File.delete(file.path)
    end

    # The index tells crawlers which files to read again: a file that changed gets a later date even when the
    # change is a removal, and one that did not keeps its date.
    def manifest_entry(file, changed)
      previous_lastmod = @previous_file_by_name.dig(file.name, "lastmod")
      lastmod = if !changed
        previous_lastmod
      elsif @previous_file_by_name.key?(file.name) && !later?(file.lastmod, previous_lastmod)
        @manifest.built_at.getutc.iso8601
      else
        file.lastmod
      end
      {"name" => file.name, "urls" => file.url_count, "lastmod" => lastmod, "digest" => file.digest}
    end

    # A manifest written by an older version may hold a lastmod in another format: compare times, not text.
    def later?(stamp, previous_stamp)
      return false if stamp.nil?

      previous_stamp = Xml.timestamp(previous_stamp)
      previous_stamp.nil? || Xml.time(stamp) > Xml.time(previous_stamp)
    end

    def rebuild_due?(now)
      every = @configuration.rebuild_every
      every.present? && (@previous.rebuilt_at.nil? || @previous.rebuilt_at + every <= now)
    end

    def publish_index
      name = "#{@configuration.filename}.xml"
      entries = @manifest.files.map do |file|
        Xml.sitemap_entry("#{@configuration.sitemaps_url}/#{file["name"]}", file["lastmod"])
      end
      inspect_index("#{@configuration.sitemaps_url}/#{name}", entries.size)
      upload(name, "#{Xml::INDEX_OPEN}#{entries.join}#{Xml::INDEX_CLOSE}")
    end

    # One file per host, rendered at each build from a handful of records, by name. A link listed twice is kept
    # once; one outside the site is a warning, and so is a file past MAX_LINKS, which a model no longer reads as a
    # summary.
    def render_llms_txt(sources)
      llms_txt = @configuration.llms_txt
      llms_txt.targets(@configuration).to_h do |target|
        location = "#{@configuration.sitemaps_url}/#{target.name}"
        seen_urls = Set.new
        entries = sources.flat_map do |source|
          source_entries, cut_short = source.llms_txt_entries(target.locale, seen_urls)
          if cut_short
            warn(source.slug, location, "read #{LlmsTxt::MAX_RECORDS} records without filling #{target.name}: " \
              "give its llms_txt a scope: with the records of that language")
          end
          source_entries
        end
        check_llms_txt(target.name, location, entries)
        [target.name, llms_txt.render(entries.first(LlmsTxt::MAX_LINKS), target.locale, target.host)]
      end
    end

    # Each file is published when it differs from the last build's, the new ones announced together.
    def publish_llms_txt(content_by_name)
      changed = content_by_name.select { |name, content| @full || @previous.extras[name] != Digest::SHA256.hexdigest(content) }
      announce(changed.keys)
      content_by_name.each do |name, content|
        @manifest.extras[name] = Digest::SHA256.hexdigest(content)
        if changed.key?(name)
          upload(name, content)
          @written << name
        else
          @kept << name
        end
      end
    end

    def check_llms_txt(name, location, entries)
      outside = entries.reject { |entry| on_host?(entry.url) }
      if outside.any?
        @warnings << Warning.new(source: name, url: outside.first.url, message: @outside_message, others: outside.size - 1)
      end
      return if entries.size <= LlmsTxt::MAX_LINKS

      warn(name, location, "has more than #{LlmsTxt::MAX_LINKS} links, the first #{LlmsTxt::MAX_LINKS} are " \
        "listed: give llms_txt a smaller scope")
    end

    def upload(name, content)
      path = File.join(@directory, name)
      File.write(path, content)
      @storage.write(name, path)
    end

    def manifest_name
      "#{@configuration.filename}-manifest.json"
    end

    def inspect_page(source, page, seen_urls)
      page.urls.each do |url|
        warn_counted(source, :outside, url, @outside_message) unless on_host?(url)
        warn_counted(source, :listed_twice, url, "is listed twice") unless seen_urls.add?(url)
        warn_counted(source, :long, url, "is longer than #{MAX_URL_CHARACTERS} characters") if url.length > MAX_URL_CHARACTERS
      end
      page.url_by_locale.each do |hreflang, url|
        warn(source, url, "has hreflang #{hreflang.inspect}, not a language code") if @checked_hreflangs.add?(hreflang) && !hreflang.match?(HREFLANG)
      end
      if page.url_by_locale.size > 1 && page.urls.one?
        warn_once(source, :one_url, page.urls.first, "is the URL of every language of its page: does the url block use the locale?")
      end
      inspect_lastmod(source, page)
    end

    def inspect_lastmod(source, page)
      if page.rejected_lastmod
        warn_once(source, :rejected_lastmod, page.urls.first, "has a lastmod that is not a W3C date (#{page.rejected_lastmod.inspect}), left out")
      elsif page.modified_at && page.modified_at > @manifest.built_at
        warn_counted(source, :future_lastmod, page.urls.first, "has a lastmod in the future (#{page.lastmod})")
      end
      # Counted by kind of mistake: the reason without what it quotes or counts.
      page.rejected_media.each { |url, reason| warn_counted(source, :"media #{reason.sub(/ \(.*\z/, "").gsub(/-?\d+/, "N")}", url, reason) }
    end

    def inspect_index(url, file_count)
      return if file_count <= MAX_FILES_PER_INDEX

      warn("index", url, "lists #{file_count} files, more than #{MAX_FILES_PER_INDEX}: raise shard_size")
    end

    # For a mistake every page of a source would repeat.
    def warn_once(source, kind, url, message)
      warn(source, url, message) if @reported.add?([source.slug, kind])
    end

    # For a mistake any number of URLs of a source may share: the first is reported, the others are counted.
    def warn_counted(source, kind, url, message)
      mistake = [source.slug, kind]
      index = @warning_index_by_mistake[mistake]
      if index
        @warnings[index] = @warnings[index].with(others: @warnings[index].others + 1)
      else
        @warning_index_by_mistake[mistake] = @warnings.size
        warn(source, url, message)
      end
    end

    def warn(source, url, message)
      @warnings << Warning.new(source: source.is_a?(Source) ? source.slug : source, url:, message:, others: 0)
    end

    def on_host?(url)
      url.start_with?(*@host_prefixes) || @hosts.include?(url)
    end

    def host_of(url)
      @hosts.find { |host| url == host || url.start_with?("#{host}/") }
    end

    # A day may still be the day of the last build somewhere: it changed if it is not older than the date at
    # UTC-12, the last time zone to leave a day. A month or a year alone says too little to tell.
    def changed_since_last_build?(page)
      return false unless page.lastmod
      return page.modified_at >= @previous.built_at if page.lastmod.include?("T")

      page.lastmod.length == DAY_LENGTH && page.lastmod >= (@previous.built_at - LAST_TIME_ZONE_OFFSET_SECONDS).utc.to_date.iso8601
    end

    def urls_to_submit
      return [] unless @submit && @configuration.index_now_key

      (@previous.unsubmitted + @changed_urls).uniq.select { |url| on_host?(url) }
    end

    # Returns how many URLs the endpoint took. The others, refused or unreachable, stay in the manifest for the
    # next build: the sitemaps are published, so a refusal never fails the build.
    def submit(urls)
      return 0 if urls.empty?

      replies = urls.group_by { |url| host_of(url) }.flat_map { |host, urls_of_host| submit_to(host, urls_of_host) }
      @manifest.unsubmitted.replace(replies.reject(&:accepted?).flat_map(&:urls).last(MAX_UNSUBMITTED_URLS))
      upload(manifest_name, @manifest.to_json)
      replies.select(&:accepted?).sum { |reply| reply.urls.size }
    end

    def submit_to(host, urls)
      replies = @index_now.submit(host, urls)
      replies.reject(&:accepted?).group_by(&:status).each do |status, refused|
        count = refused.sum { |reply| reply.urls.size }
        answer = status.is_a?(Integer) ? "answered #{status}" : "could not be reached (#{status})"
        warn("indexnow", IndexNow::ENDPOINT, "#{answer} for #{count} URLs of #{host}, sent again with the next build")
      end
      replies
    end

    # IndexNow reads the key at the root of a host unless told where it is, and only on that host.
    def publish_index_now_key
      key = @configuration.index_now_key
      return if key.nil? || @configuration.index_now_key_location

      if @configuration.sitemaps_url == @configuration.host!
        upload("#{key}.txt", key)
      else
        warn("indexnow", "#{@configuration.host!}/#{key}.txt", "must hold the key: sitemaps go to #{@configuration.sitemaps_url}, " \
          "so put #{key}.txt in public/ and set index_now_key_location to \"/#{key}.txt\"")
      end
    end
  end
end
