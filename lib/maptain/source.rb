# frozen_string_literal: true

module Maptain
  # One kind of page. A subclass names its records, their URLs and their languages:
  #
  #   class ProductSitemap < Maptain::Source
  #     scope { Product.published }
  #     url { |product, locale| product_url(product, locale:) }
  #   end
  class Source
    # The protocol allows 50 MiB a file, uncompressed. Shards aim lower: the sizes below are estimates.
    TARGET_BYTES_PER_FILE = 40 * 1024 * 1024
    BYTES_PER_URL_ESTIMATE = 150
    BYTES_PER_ALTERNATE_ESTIMATE = 120
    MYSQL_ADAPTERS = %w[mysql2 trilogy].freeze
    SLUG_FORMAT = /\A[a-z0-9][a-z0-9_-]*\z/
    # A source that is not an Active Record relation is one shard, rendered at each build.
    WHOLE = "all"
    # What RFC 3986 lets a URL hold as is. Anything else is percent-encoded, byte by byte.
    URL_CHARACTERS = "A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%"
    UNSAFE = "[^#{URL_CHARACTERS}]|%(?![0-9A-Fa-f]{2})"
    UNSAFE_CHARACTER = Regexp.new(UNSAFE)
    UNSAFE_BYTE = Regexp.new(UNSAFE, Regexp::NOENCODING)
    # Records loaded at once for the llms.txt: one more than it may list.
    LLMS_TXT_BATCH = 201

    class << self
      def inherited(subclass)
        super
        # A subclass lists its own records in the llms.txt, or none: inherited, the same links would come twice.
        subclass.instance_variable_set(:@definitions, definitions.except(:llms_txt))
      end

      def definitions
        @definitions ||= {lastmod: :updated_at}
      end

      # The records, as an Active Record relation or any enumerable.
      def scope(&block)
        definitions[:scope] = block
      end

      def scope?
        definitions.key?(:scope)
      end

      # The URL of a record in a language, or nil when it has none. A path is completed with the host.
      def url(&block)
        definitions[:url] = block
      end

      # The languages a record exists in. Without it, every configured language.
      def locales(&block)
        definitions[:locales] = block
      end

      # A column, or a block for anything else. With a block on a relation, name what changes with it in
      # `fingerprint`: the column alone no longer tells a build what moved.
      def lastmod(column = nil, &block)
        definitions[:lastmod] = block || column
      end

      def images(&block)
        definitions[:images] = block
      end

      # The SQL expression whose greatest value changes whenever a record's sitemap entry does.
      def fingerprint(sql)
        definitions[:fingerprint] = sql
      end

      # How many consecutive ids share a file.
      def shard_size(count)
        definitions[:shard_size] = Integer(count)
      end

      # Lists records in the llms.txt of the site, under a heading: the records of `scope`, by default all of
      # the source's, each with the title and notes the block returns ([title, notes], or a title alone).
      def llms_txt(section, scope: nil, &entry)
        raise SourceError, "#{name}.llms_txt needs a block returning the title of a record" unless entry
        raise SourceError, "#{name}.llms_txt scope: must be a lambda, such as -> { Product.featured }" if scope && !scope.respond_to?(:call)

        definitions[:llms_txt] = {section:, scope:, entry:}
      end

      def slug(name = nil)
        definitions[:slug] = name.to_s if name
        return definitions[:slug] if definitions[:slug]

        self.name ? self.name.demodulize.underscore.delete_suffix("_sitemap") : superclass.slug
      end
    end

    attr_reader :configuration, :slug

    def initialize(configuration)
      @configuration = configuration
      @slug = self.class.slug
      return if slug.match?(SLUG_FORMAT)

      raise SourceError, "#{self.class.name}'s slug #{slug.inspect} must be lowercase letters, digits, - and _"
    end

    # What `url` blocks read when they call a route helper. Frozen: one hash serves every URL of a host.
    def default_url_options
      @url_options_by_host ||= {}
      @url_options_by_host[current_host] ||= begin
        uri = URI.parse(current_host)
        {host: uri.host, protocol: uri.scheme, port: (uri.port unless uri.port == uri.default_port)}.compact.freeze
      end
    end

    # A nil fingerprint means the shard has to be rendered to know whether it changed.
    def fingerprint_by_shard
      return {WHOLE => nil} unless relation?

      # The sum of the ids moves when a record leaves a range and another enters it; the shard size, when the
      # ranges themselves move. Summed as offsets within the range: SQLite's SUM overflows on large ids.
      offset_sum = Arel.sql("SUM(#{model.quoted_table_name}.#{model.quoted_primary_key} % #{shard_size})")
      relation.reorder(nil).group(shard_sql).pluck(shard_sql, Arel.sql("COUNT(*)"), offset_sum, fingerprint_sql)
        .to_h { |shard, count, sum, latest| [shard.to_i.to_s, "#{shard_size}/#{count}/#{sum.to_i}/#{precise(latest)}"] }
    end

    def each_page(shard)
      return to_enum(:each_page, shard) unless block_given?

      records_of(shard) do |record|
        page = page_for(record)
        yield page unless page.url_by_locale.empty?
      end
    end

    def basename(shard)
      prefix = "#{configuration.filename}-#{slug}"
      (shard == WHOLE) ? prefix : "#{prefix}-#{shard.rjust(5, "0")}"
    end

    # The links this source adds to the llms.txt, in one language, and whether reading stopped at
    # LlmsTxt::MAX_RECORDS before the file was full. A record that does not exist in that language, or whose title
    # is blank or a missing translation, is left out. Its blocks, scope included, run in that language.
    # seen_urls: the URLs the file lists already, from earlier sources; a URL listed again is skipped, not counted.
    def llms_txt_entries(locale, seen_urls = Set.new)
      definition = definitions[:llms_txt]
      return [[], false] unless definition

      hreflang = Xml.hreflang(locale)
      speaking(locale) do
        given = definition[:section]
        section = given.respond_to?(:call) ? instance_exec(&given) : given
        next [[], false] unless LlmsTxt.present?(section)

        entries = []
        read = 0
        cut_short = false
        each_llms_txt_record(definition[:scope]) do |record|
          # A record past MAX_RECORDS is not read: it only tells that some were left.
          if (read += 1) > LlmsTxt::MAX_RECORDS
            cut_short = true
            break
          end
          # Spelled as the record's languages spell it, as the sitemap does.
          record_locale = locales_of(record).find { |candidate| Xml.hreflang(candidate) == hreflang }
          url = record_locale && url_by_locale_of(record, [record_locale])[hreflang]
          next unless url && !seen_urls.include?(url)

          title, notes = speaking(locale) { Array(instance_exec(record, &definition[:entry])) }
          next unless LlmsTxt.present?(title)

          seen_urls << url
          entries << LlmsTxt::Entry.new(section:, title:, url:, notes:)
          # One more than the file may list, for the build to warn about it.
          break if entries.size > LlmsTxt::MAX_LINKS
        end
        [entries, cut_short]
      end
    end

    def llms_txt?
      definitions.key?(:llms_txt)
    end

    private

    # The records of the llms.txt, until the caller has enough: in batches of ids for a relation that names no
    # order, limit or offset, so that the file does not change with the database's order; otherwise as the relation
    # says, a page of BATCH at a time, never more than MAX_RECORDS + 1 rows. A block named, not forwarded: Ruby
    # 3.3.0 rejects & inside a block.
    def each_llms_txt_record(scope, &block)
      records = scope ? instance_exec(&scope) : relation
      return records.each(&block) unless records.respond_to?(:find_each) && records.respond_to?(:order_values)
      return records.find_each(batch_size: LLMS_TXT_BATCH, &block) if records.order_values.empty? && !records.limit_value && !records.offset_value

      wanted = [records.limit_value, LlmsTxt::MAX_RECORDS + 1].compact.min
      first = records.offset_value || 0
      done = 0
      while done < wanted
        page = records.offset(first + done).limit([LLMS_TXT_BATCH, wanted - done].min).to_a
        page.each(&block)
        break if page.size < [LLMS_TXT_BATCH, wanted - done].min

        done += page.size
      end
    end

    def locales_of(record)
      definitions[:locales] ? Array(instance_exec(record, &definitions[:locales])) : configuration.locales
    end

    # Runs a block with the host and I18n locale of a language, as the url block gets them.
    def speaking(locale)
      app_locale = I18n.locale
      outer_host = @language_host
      _hreflang, @language_host, i18n_locale = language_for(locale)
      I18n.locale = i18n_locale || app_locale
      yield
    ensure
      @language_host = outer_host
      I18n.locale = app_locale
    end

    def definitions
      self.class.definitions
    end

    def relation
      @relation ||= instance_exec(&definitions.fetch(:scope))
    end

    def relation?
      relation.respond_to?(:find_each) && relation.respond_to?(:group)
    end

    def model
      relation.klass
    end

    def records_of(shard, &)
      return relation.each(&) unless relation?

      first_id = shard.to_i * shard_size
      relation.where(model.primary_key => first_id...(first_id + shard_size)).find_each(&)
    end

    def page_for(record)
      locales = locales_of(record)
      given_lastmod = lastmod_of(record)
      lastmod = Xml.timestamp(given_lastmod)
      Page.new(url_by_locale: url_by_locale_of(record, locales), lastmod:, modified_at: lastmod && Xml.time(lastmod),
        images: images_of(record), rejected_lastmod: (given_lastmod if lastmod.nil? && given_lastmod.present?))
    end

    # The url block runs with the host of its language and with that language as I18n.locale: route helpers,
    # paths and translated slugs get them without naming them. A language outside I18n.available_locales, which
    # I18n may refuse, runs in the app's. Set per URL and restored per page: I18n.with_locale costs twice as much.
    def url_by_locale_of(record, locales)
      app_locale = I18n.locale
      outer_host = @language_host
      locales.filter_map do |locale|
        hreflang, @language_host, i18n_locale = language_for(locale)
        I18n.locale = i18n_locale || app_locale
        location = instance_exec(record, locale, &definitions.fetch(:url))
        [hreflang, absolute(location)] if location
      end.to_h
    ensure
      @language_host = outer_host
      I18n.locale = app_locale
    end

    # [hreflang, host, I18n locale or nil when I18n does not have it], worked out once per language.
    # The hreflang is frozen: a hash copies a key that is not, here once per URL.
    def language_for(locale)
      @language_by_locale ||= {}
      @language_by_locale[locale] ||=
        [Xml.hreflang(locale).freeze, configuration.host_for(locale), (locale if I18n.locale_available?(locale))]
    end

    def current_host
      @language_host || configuration.host!
    end

    def absolute(location)
      location = location.to_s
      if location.start_with?("//")
        location = "#{current_host.split("//", 2).first}#{location}"
      elsif location.start_with?("/")
        location = "#{current_host}#{location}"
      end
      encoded(location)
    end

    # Route helpers encode their URLs already; a URL written by hand may hold spaces or accents.
    def encoded(url)
      return url if url.ascii_only? && !url.match?(UNSAFE_CHARACTER)

      url.b.gsub(UNSAFE_BYTE) { |byte| format("%%%02X", byte.ord) }.force_encoding(Encoding::UTF_8)
    end

    def lastmod_of(record)
      lastmod = definitions[:lastmod]
      return instance_exec(record, &lastmod) if lastmod.respond_to?(:call)

      record.public_send(lastmod) if lastmod && record.respond_to?(lastmod)
    end

    def images_of(record)
      definitions[:images] ? Array(instance_exec(record, &definitions[:images])).map { |location| absolute(location) } : []
    end

    def shard_size
      @shard_size ||= definitions[:shard_size] || default_shard_size
    end

    def default_shard_size
      locale_count = configuration.locales.size
      alternates = (locale_count > 1) ? locale_count + 1 : 0
      bytes_per_record = locale_count * (BYTES_PER_URL_ESTIMATE + alternates * BYTES_PER_ALTERNATE_ESTIMATE)
      [ShardWriter::MAX_URLS_PER_FILE / locale_count, TARGET_BYTES_PER_FILE / bytes_per_record].min.clamp(1..)
    end

    # Two updates in the same second must not look like one.
    def precise(latest)
      latest.respond_to?(:utc) ? latest.utc.iso8601(6) : latest.to_s
    end

    def shard_sql
      @shard_sql ||= begin
        primary_key = model.primary_key
        unless primary_key.is_a?(String) && model.type_for_attribute(primary_key).type == :integer
          raise SourceError, "#{self.class.name} needs a scope whose model has an integer primary key"
        end
        # MySQL's / returns a decimal.
        division = MYSQL_ADAPTERS.include?(model.connection_db_config.adapter) ? "DIV" : "/"
        Arel.sql("#{model.quoted_table_name}.#{model.quoted_primary_key} #{division} #{shard_size}")
      end
    end

    def fingerprint_sql
      column = definitions[:lastmod].is_a?(Symbol) ? definitions[:lastmod] : :updated_at
      expression = definitions[:fingerprint] ||
        "#{model.quoted_table_name}.#{model.adapter_class.quote_column_name(column)}"
      Arel.sql("MAX(#{expression})")
    end
  end
end
