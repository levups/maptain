# Changelog

## [Unreleased]

## [0.3.0] — 2026-11-28

A build that dies midway is fully repaired by the next one, models without `updated_at` build, and IndexNow only hears about pages that changed.

**Breaking**
- A build refuses two sources sharing a slug, a list source and a relation source with the same slug included, which used to build.
- A `lastmod` block or method on a model without `updated_at` needs a `fingerprint`.
- A misspelled `lastmod` column raises a `SourceError` asking for a `fingerprint`, instead of an SQL error.
- Sources are found among named classes only: list an anonymous `Class.new(Maptain::Source)` in `config.sources`.

**Fixed**
- A build that died midway is repaired by the next one: files it started to rewrite or delete are written again, and the IndexNow URLs it had found (up to 10,000) are sent.
- Sources on models without `updated_at` build; their pages have no `lastmod`.
- Two sources with the same slug are refused before anything is written, instead of crashing midway. A source listed twice is built once, and sources unloaded by a Rails reload are no longer found.
- A `lastmod` column named by a String is watched like a Symbol.
- Action Text bodies in video, news and llms.txt fields are written as text, not HTML. A binary or invalid UTF-8 llms.txt title no longer stops the build.
- IndexNow is no longer sent unchanged pages when `shard_size` gets smaller, a range drops a file, or a list source becomes a relation (or back).

## [0.2.0] — 2026-11-25

Sitemaps for videos and Google News, and the site's llms.txt, written by the same build.

**New**
- `video` and `news` blocks on a source, run in each language of a page like its `url` block: `<video:video>` and `<news:news>` entries that follow Google's schemas, with news files of 1,000 articles at most.
- The site's llms.txt (`config.llms_txt`, and `llms_txt` on each source that joins it): a short summary for language models, rewritten only when it changes, one file per host in that host's language.
- `Maptain::LlmsTxt::App` serves `/llms.txt` for the request's host from the storage, for sitemaps kept on S3 or a site with one host per language.

## [0.1.0] — 2026-11-21

First release: XML sitemaps for Rails sites in many languages, rebuilt in milliseconds when little has changed.

**New**
- One `Maptain::Source` class per kind of page, whose hreflang links come from the languages of each record, with `config.host_by_locale` for a host per language.
- Files cut by ranges of ids, so the same records land in the same file at every build, and builds that rewrite only the ranges whose count or latest change moved: 3 changed records out of 30,000 in 24 languages rebuild 430 times faster than with sitemap_generator.
- Local storage or Active Storage, gzip at the highest level, and a manifest that lets the next build repair one that died midway.
- IndexNow submissions of the pages that appeared, changed or disappeared, which never fail a build.
- Checks without a single HTTP request: encoded URLs, W3C dates, hreflang codes, one line per repeated warning.

[Unreleased]: https://github.com/levups/maptain/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/levups/maptain/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/levups/maptain/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/levups/maptain/releases/tag/v0.1.0
