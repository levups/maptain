# frozen_string_literal: true

module Maptain
  # What the last build wrote: for each shard of each source, its fingerprint and its files. pending lists the
  # files a build was about to write or delete when it died, so that the next one writes or removes them again;
  # unsubmitted the URLs IndexNow has yet to take, refused or not sent by a build that died, for the next one to
  # send; extras the digest of each file that is not a sitemap, such as llms.txt, by name.
  class Manifest
    attr_reader :built_at, :rebuilt_at, :digest, :shards_by_source, :pending, :unsubmitted, :extras

    def self.read(storage, name)
      json = storage.read(name)
      return new unless json

      stored = JSON.parse(json)
      new(digest: stored["digest"], built_at: time(stored["built_at"]), rebuilt_at: time(stored["rebuilt_at"]),
        shards_by_source: stored["sources"] || {}, pending: stored["pending"] || [], unsubmitted: stored["unsubmitted"] || [],
        extras: stored["extras"] || {})
    rescue JSON::ParserError, ArgumentError, TypeError
      # A manifest we cannot read is a manifest we do not have: the build starts over and replaces it.
      new
    end

    def self.time(text)
      Time.iso8601(text) if text
    end

    def initialize(digest: nil, built_at: nil, rebuilt_at: nil, shards_by_source: {}, pending: [], unsubmitted: [], extras: {})
      @digest = digest
      @built_at = built_at
      @rebuilt_at = rebuilt_at
      @shards_by_source = shards_by_source
      @pending = pending
      @unsubmitted = unsubmitted
      @extras = extras
    end

    def shard(source, key)
      shards_by_source.dig(source, key)
    end

    def record(source, key, fingerprint:, files:)
      (shards_by_source[source] ||= {})[key] = {"fingerprint" => fingerprint, "files" => files}
    end

    def files
      shards_by_source.each_value.flat_map { |shards| shards.each_value.flat_map { |shard| shard["files"] } }
    end

    def file_names
      files.map { |file| file["name"] }
    end

    def to_json(*)
      # Whole seconds, like the lastmods compared to built_at: a change in the second of a build is sent again
      # rather than never.
      JSON.pretty_generate("digest" => digest, "built_at" => built_at&.utc&.iso8601,
        "rebuilt_at" => rebuilt_at&.utc&.iso8601, "pending" => pending, "unsubmitted" => unsubmitted, "extras" => extras,
        "sources" => shards_by_source)
    end
  end
end
