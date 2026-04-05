#!/usr/bin/env ruby

require "sinatra"
require "json"
require "set"
require "sqlite3"
require "fileutils"
require "uri"
require "cgi"
require "pathname"
require "digest"
require "time"
require "net/http"
require "nokogiri"

DATA_DIR = File.expand_path("~/.local/share/doko")
DB_PATH  = File.join(DATA_DIR, "data.sqlite3")
GIT_REVISION = `git -C #{__dir__} rev-parse --short HEAD 2>/dev/null`.strip.freeze

FileUtils.mkdir_p(DATA_DIR)
$db = SQLite3::Database.new(DB_PATH)
$db.results_as_hash = true
$db.execute("PRAGMA journal_mode=WAL")
$db.execute("PRAGMA foreign_keys=ON")

$db.execute_batch(<<~SQL)
  CREATE TABLE IF NOT EXISTS sources(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uri TEXT UNIQUE NOT NULL,
    content_sha TEXT NOT NULL,
    title TEXT,
    keywords TEXT,
    mtime INTEGER NOT NULL,
    last_indexed_at INTEGER NOT NULL,
    deleted_at INTEGER
  );

  CREATE TABLE IF NOT EXISTS docs(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    content TEXT NOT NULL,
    lang TEXT,
    updated_at INTEGER NOT NULL,
    UNIQUE(source_id, chunk_index)
  );

  CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(
    content, title, uri,
    tokenize = 'unicode61 remove_diacritics 2',
    content = ''
  );
SQL

# Migration: add keywords column to existing sources table
begin
  $db.execute("SELECT keywords FROM sources LIMIT 0")
rescue SQLite3::SQLException
  $db.execute("ALTER TABLE sources ADD COLUMN keywords TEXT")
end

# --- Helpers from ref.rb ---

def canonical_uri(input)
  u = URI.parse(input)
  case u.scheme&.downcase
  when "file"
    raw  = URI.decode_www_form_component(u.path || "")
    abs  = File.expand_path(raw)
    norm = Pathname(abs).cleanpath.to_s
    enc  = CGI.escape(norm).gsub("+", "%20")
    "file:///#{enc}"
  when "http", "https"
    u.to_s
  else
    raise "unsupported URI scheme: #{input}"
  end
end

def uri_to_path(uri_str)
  u = URI.parse(uri_str)
  URI.decode_www_form_component(u.path)
end

def read_resource(uri_str)
  u = URI.parse(uri_str)
  case u.scheme&.downcase
  when "file"
    p = uri_to_path(uri_str)
    raise "file not found: #{p}" unless File.file?(p)
    [File.read(p, mode: "r:UTF-8"), File.mtime(p).to_i]
  when "http", "https"
    max_redirects = 5
    current_uri = u
    res = nil
    max_redirects.times do
      current_uri = URI.parse(current_uri.to_s) unless current_uri.is_a?(URI)
      res = Net::HTTP.start(current_uri.host, current_uri.port, use_ssl: current_uri.scheme == "https") { |http|
        http.request(Net::HTTP::Get.new(current_uri))
      }
      break unless res.is_a?(Net::HTTPRedirection) && res["location"]
      current_uri = URI.parse(res["location"])
    end
    raise "HTTP #{res.code} for #{uri_str}" unless res.is_a?(Net::HTTPSuccess)
    body = res.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    mtime = (Time.httpdate(res["Last-Modified"]) rescue Time.now).to_i
    [body, mtime]
  else
    raise "unsupported URI: #{uri_str}"
  end
end

def read_and_extract_body_by_uri(uri_str, raw)
  u = URI.parse(uri_str)
  if %w[http https].include?(u.scheme&.downcase)
    head = raw.lstrip[0, 512]
    return extract_text_from_xml(raw) if head =~ /<\?xml/i || head =~ /<html|<!doctype html|<body|<head/i
    return normalize_text(raw)
  else
    path = uri_to_path(uri_str)
    ext  = File.extname(path).downcase
    return extract_text_from_xml(raw) if %w[.xml .xhtml .opf .rss .atom .html .htm].include?(ext)
    normalize_text(raw)
  end
end

def extract_text_from_xml(str)
  doc = Nokogiri::HTML5(str)
  doc.css("script, style").each(&:remove)
  normalize_text(doc.text)
end

def normalize_text(s)
  s = s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  s = s.gsub("\r\n", "\n").gsub("\r", "\n")
  s = s.gsub(/[ \t\f\v]+/, " ").gsub(/\n{3,}/, "\n\n").strip
  s
end

def infer_title(uri_str, content)
  first = content.lines.first&.strip
  return first.sub(/\A#+\s*/, "") if first&.start_with?("#")
  u = URI.parse(uri_str)
  u.scheme&.downcase == "file" ? File.basename(uri_to_path(uri_str)) : uri_str
end

def chunk_text(s, size = 1200)
  out, off = [], 0
  while off < s.length
    ch = s[off, size]
    if s.length > off + size
      cut = ch.rindex("\n")
      ch = ch[0...cut] if cut && cut > size * 0.6
    end
    out << ch
    off += ch.length
  end
  out
end

def safe_snippet(html)
  html = CGI.escapeHTML(html)
  html.gsub!("&lt;mark&gt;", "<mark>")
  html.gsub!("&lt;/mark&gt;", "</mark>")
  html
end

def keywords_text(keywords)
  return "" if keywords.nil? || keywords.empty?
  entries = JSON.parse(keywords)
  entries.flat_map { |e| Array.new(e["count"], e["word"]) }.join(" ")
end

def merge_keywords(existing_json, new_words)
  entries = existing_json ? JSON.parse(existing_json) : []
  new_words.each do |word|
    entry = entries.find { |e| e["word"] == word }
    if entry
      entry["count"] += 1
    else
      entries << { "word" => word, "count" => 1 }
    end
  end
  entries.to_json
end

def rebuild_fts_for_source(source_id, title, uri, keywords_json)
  kw_text = keywords_text(keywords_json)

  $db.execute(<<~SQL, sid: source_id)
    INSERT INTO docs_fts(docs_fts, rowid, content, title, uri)
    SELECT 'delete', d.id, d.content, s.title, s.uri
    FROM docs d JOIN sources s ON s.id = d.source_id
    WHERE d.source_id = :sid
  SQL

  fts_title = kw_text.empty? ? title : "#{title} #{kw_text}"
  $db.execute(<<~SQL, sid: source_id, ttl: fts_title, uri: uri)
    INSERT INTO docs_fts(rowid, content, title, uri)
    SELECT d.id, d.content, :ttl, :uri
    FROM docs d
    WHERE d.source_id = :sid
    ORDER BY d.chunk_index
  SQL
end

def do_index(uri_str, new_keywords: [])
  uri = canonical_uri(uri_str)

  # Handle keyword-only update (source already exists, no re-fetch needed)
  if new_keywords.any?
    cur = $db.get_first_row("SELECT id, title, keywords FROM sources WHERE uri=:uri LIMIT 1", uri: uri)
    if cur
      merged = merge_keywords(cur["keywords"], new_keywords)
      $db.transaction(:immediate) do
        $db.execute("UPDATE sources SET keywords=:kw WHERE id=:id", kw: merged, id: cur["id"])
        rebuild_fts_for_source(cur["id"], cur["title"], uri, merged)
      end
      return { status: "keywords_updated", uri: uri, title: cur["title"], keywords: JSON.parse(merged) }
    end
  end

  begin
    raw, mtime = read_resource(uri)
  rescue => e
    raise unless e.message.match?(/\AHTTP \d+/)
    return do_bookmark(uri, e.message)
  end

  norm = read_and_extract_body_by_uri(uri, raw)
  content_sha = Digest::SHA256.hexdigest(norm)
  title = infer_title(uri, norm)
  chunks = chunk_text(norm)

  cur = $db.get_first_row("SELECT content_sha, keywords FROM sources WHERE uri=:uri LIMIT 1", uri: uri)
  keywords_json = new_keywords.any? ? merge_keywords(cur&.[]("keywords"), new_keywords) : cur&.[]("keywords")

  if cur && cur["content_sha"] == content_sha && new_keywords.empty?
    return { status: "unchanged", uri: uri, title: title }
  end

  now = Time.now.to_i

  $db.transaction(:immediate) do
    $db.execute(<<~SQL, uri: uri, sha: content_sha, ttl: title, kw: keywords_json, mt: mtime, ts: now)
      INSERT INTO sources(uri, content_sha, title, keywords, mtime, last_indexed_at)
      VALUES(:uri, :sha, :ttl, :kw, :mt, :ts)
      ON CONFLICT(uri) DO UPDATE SET
        content_sha=excluded.content_sha,
        title=excluded.title,
        keywords=excluded.keywords,
        mtime=excluded.mtime,
        last_indexed_at=excluded.last_indexed_at
    SQL

    source_id = $db.get_first_value("SELECT id FROM sources WHERE uri=:uri", uri: uri)

    $db.execute(<<~SQL, sid: source_id)
      INSERT INTO docs_fts(docs_fts, rowid, content, title, uri)
      SELECT 'delete', d.id, d.content, s.title, s.uri
      FROM docs d JOIN sources s ON s.id = d.source_id
      WHERE d.source_id = :sid
    SQL
    $db.execute("DELETE FROM docs WHERE source_id=:sid", sid: source_id)

    chunks.each_with_index do |txt, idx|
      $db.execute(
        "INSERT INTO docs(source_id, chunk_index, content, lang, updated_at) VALUES(:sid, :idx, :content, NULL, :now)",
        sid: source_id, idx: idx, content: txt, now: now
      )
    end

    rebuild_fts_for_source(source_id, title, uri, keywords_json)
  end

  result = { status: "indexed", uri: uri, title: title, chunks: chunks.size }
  result[:keywords] = JSON.parse(keywords_json) if keywords_json
  result
end

def do_bookmark(uri, error_message)
  cur = $db.get_first_row("SELECT id FROM sources WHERE uri=:uri LIMIT 1", uri: uri)
  return { status: "bookmarked", uri: uri, title: uri, error: error_message } if cur

  now = Time.now.to_i
  empty_sha = Digest::SHA256.hexdigest("")

  $db.execute(<<~SQL, uri: uri, sha: empty_sha, ttl: uri, mt: now, ts: now)
    INSERT INTO sources(uri, content_sha, title, mtime, last_indexed_at)
    VALUES(:uri, :sha, :ttl, :mt, :ts)
  SQL

  { status: "bookmarked", uri: uri, title: uri, error: error_message }
end

# --- Sinatra Routes ---

get "/" do
  erb :index
end

get "/manifest.json" do
  content_type "application/manifest+json"
  {
    id: "/",
    name: "doko",
    short_name: "doko",
    start_url: "/",
    scope: "/",
    display: "browser",
    background_color: "#030712",
    theme_color: "#030712",
    icons: [
      { src: "/icon.svg", sizes: "any", type: "image/svg+xml" },
      { src: "/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
      { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
      { src: "/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" }
    ]
  }.to_json
end

get "/icon.svg" do
  content_type "image/svg+xml"
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
      <rect width="512" height="512" rx="96" fill="#030712"/>
      <text x="256" y="330" font-family="system-ui,sans-serif" font-size="240" font-weight="bold" fill="#60a5fa" text-anchor="middle">d</text>
    </svg>
  SVG
end

ICON_192 = File.binread(File.join(__dir__, "icon-192.png"))
ICON_512 = File.binread(File.join(__dir__, "icon-512.png"))
ICON_MASKABLE_512 = File.binread(File.join(__dir__, "icon-maskable-512.png"))

get "/icon-192.png" do
  content_type "image/png"
  ICON_192
end

get "/icon-512.png" do
  content_type "image/png"
  ICON_512
end

get "/icon-maskable-512.png" do
  content_type "image/png"
  ICON_MASKABLE_512
end

SW_VERSION = Digest::SHA256.file(File.expand_path(__FILE__)).hexdigest[0, 8]

get "/sw.js" do
  content_type "application/javascript"
  cache_control :no_cache
  <<~JS
    const CACHE = "doko-#{SW_VERSION}";
    const PRECACHE = ["/", "/icon.svg"];

    self.addEventListener("install", (e) => {
      e.waitUntil(caches.open(CACHE).then((c) => c.addAll(PRECACHE)));
      self.skipWaiting();
    });

    self.addEventListener("activate", (e) => {
      e.waitUntil(
        caches.keys().then((keys) =>
          Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
        )
      );
      self.clients.claim();
    });

    self.addEventListener("fetch", (e) => {
      if (e.request.method !== "GET") return;
      const url = new URL(e.request.url);
      if (url.pathname.startsWith("/api/")) return;
      e.respondWith(
        fetch(e.request).then((res) => {
          const clone = res.clone();
          caches.open(CACHE).then((c) => c.put(e.request, clone));
          return res;
        }).catch(() => caches.match(e.request))
      );
    });
  JS
end

get "/api/search" do
  content_type :json
  q = params[:q].to_s.strip
  return "[]" if q.empty?

  fts_sql = <<~SQL
    WITH ranked AS (
      SELECT d.id, s.uri, s.title, d.updated_at,
             bm25(docs_fts) AS bm,
             snippet(docs_fts, 0, '<mark>', '</mark>', '…', 20) AS snip,
             ROW_NUMBER() OVER (PARTITION BY s.uri ORDER BY bm25(docs_fts)) AS rn
      FROM docs_fts
      JOIN docs d ON d.id = docs_fts.rowid
      JOIN sources s ON s.id = d.source_id
      WHERE docs_fts MATCH :q
    )
    SELECT id, uri, title, updated_at, bm, snip
    FROM ranked WHERE rn = 1
    ORDER BY bm LIMIT 20
  SQL

  like_sql = <<~SQL
    SELECT s.id, s.uri, s.title, s.last_indexed_at AS updated_at, 0 AS bm, '' AS snip
    FROM sources s
    WHERE s.uri LIKE :like OR s.title LIKE :like
    ORDER BY s.last_indexed_at DESC
    LIMIT 20
  SQL

  begin
    rows = $db.execute(fts_sql, q: q).dup
  rescue
    rows = []
  end

  seen = rows.map { |r| r["uri"] }.to_set
  like_rows = $db.execute(like_sql, like: "%#{q}%")
  like_rows.each { |r| rows << r unless seen.include?(r["uri"]) }

  rows.each { |r| r["snip"] = safe_snippet(r["snip"].to_s) }
  rows.first(20).to_json
end

post "/api/index" do
  content_type :json
  body = JSON.parse(request.body.read)
  uri = body["uri"].to_s.strip
  halt 400, { error: "uri is required" }.to_json if uri.empty?

  new_keywords = Array(body["keywords"]).map(&:strip).reject(&:empty?)

  begin
    result = do_index(uri, new_keywords: new_keywords)
    result.to_json
  rescue => e
    $stderr.puts "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
    halt 500, { error: e.message }.to_json
  end
end

delete "/api/index" do
  content_type :json
  body = JSON.parse(request.body.read)
  uri = body["uri"].to_s.strip
  halt 400, { error: "uri is required" }.to_json if uri.empty?

  source = $db.get_first_row("SELECT id FROM sources WHERE uri=:uri", uri: uri)
  halt 404, { error: "not found" }.to_json unless source

  sid = source["id"]
  $db.transaction(:immediate) do
    $db.execute(<<~SQL, sid: sid)
      INSERT INTO docs_fts(docs_fts, rowid, content, title, uri)
      SELECT 'delete', d.id, d.content, s.title, s.uri
      FROM docs d JOIN sources s ON s.id = d.source_id
      WHERE d.source_id = :sid
    SQL
    $db.execute("DELETE FROM docs WHERE source_id=:sid", sid: sid)
    $db.execute("DELETE FROM sources WHERE id=:sid", sid: sid)
  end

  { status: "deleted", uri: uri }.to_json
end

__END__

@@index
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#030712">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <link rel="manifest" href="/manifest.json">
  <link rel="icon" href="/icon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="/icon-192.png">
  <title>doko</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    mark { background: #facc15; color: #111; border-radius: 2px; padding: 0 1px; }
  </style>
</head>
<body class="bg-gray-950 text-gray-100 min-h-screen flex flex-col items-center pt-24" style="padding-top: max(6rem, env(safe-area-inset-top, 0px) + 2rem);">
  <h1 class="text-4xl font-bold mb-8 tracking-tight">doko</h1>
  <div id="app" class="w-full max-w-2xl px-4 relative">
    <div class="flex gap-2">
      <input id="q" type="text" autofocus placeholder="Search..."
             class="flex-1 min-w-0 px-4 py-3 rounded-lg bg-gray-900 border border-gray-700
                    text-white text-lg focus:outline-none focus:ring-2 focus:ring-blue-500
                    placeholder-gray-500">
      <button id="cancel-btn" class="hidden px-3 py-3 rounded-lg bg-gray-800 border border-gray-600
                    text-gray-300 hover:text-white hover:bg-gray-700 text-sm shrink-0">Cancel</button>
    </div>
    <div id="status" class="mt-2 text-sm text-gray-400 hidden"></div>
    <div id="error-popup" class="hidden fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div class="bg-gray-900 border border-red-500 rounded-lg shadow-2xl max-w-lg w-full mx-4">
        <div class="flex items-center justify-between px-4 py-3 border-b border-gray-700">
          <span class="text-red-400 font-semibold">Error</span>
          <button id="error-close" class="text-gray-400 hover:text-white text-xl leading-none">&times;</button>
        </div>
        <pre id="error-msg" class="px-4 py-3 text-sm text-red-300 whitespace-pre-wrap break-all max-h-64 overflow-auto select-all"></pre>
        <div class="px-4 py-3 border-t border-gray-700 flex justify-end">
          <button id="error-copy" class="px-3 py-1 text-sm bg-gray-800 hover:bg-gray-700 text-gray-200 rounded">Copy</button>
        </div>
      </div>
    </div>
    <ul id="results" class="mt-1 bg-gray-900 border border-gray-700 rounded-lg overflow-y-auto shadow-xl hidden" style="max-height: 60vh;">
    </ul>
  </div>

<script>
const input = document.getElementById("q");
const list = document.getElementById("results");
const statusEl = document.getElementById("status");
const cancelBtn = document.getElementById("cancel-btn");

let timer = null;
let items = [];       // {type: "result"|"index-url"|"index-prompt", ...}
let selectedIndex = -1;
let mode = "search";  // "search" | "index-input"

function isUrl(s) {
  return /^(https?:\/\/|file:\/\/)/.test(s.trim());
}

function parseKeywordUrl(s) {
  const m = s.match(/^(.+?)\s+(https?:\/\/\S+|file:\/\/\S+)$/);
  if (!m) return null;
  return { keywords: m[1].trim(), uri: m[2].trim() };
}

input.addEventListener("input", () => {
  if (mode === "index-input") return;
  clearTimeout(timer);
  timer = setTimeout(doSearch, 150);
});

input.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (mode === "index-input") {
      exitIndexMode();
    } else {
      hideResults();
    }
    return;
  }

  if (mode === "index-input" && e.key === "Enter") {
    e.preventDefault();
    const uri = input.value.trim();
    if (uri) doIndex(uri);
    return;
  }

  if (e.key === "ArrowDown") {
    e.preventDefault();
    if (items.length === 0) return;
    selectedIndex = Math.min(selectedIndex + 1, items.length - 1);
    updateSelection();
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    if (items.length === 0) return;
    selectedIndex = Math.max(selectedIndex - 1, 0);
    updateSelection();
  } else if (e.key === "Enter") {
    e.preventDefault();
    if (selectedIndex >= 0 && selectedIndex < items.length) {
      activateItem(selectedIndex);
    }
  }
});

async function doSearch() {
  const q = input.value.trim();
  if (!q) { hideResults(); return; }

  const res = await fetch("/api/search?q=" + encodeURIComponent(q));
  const data = await res.json();

  items = [];
  const urlLike = isUrl(q);
  const kwUrl = parseKeywordUrl(q);

  if (kwUrl) {
    items.push({ type: "index-keyword", uri: kwUrl.uri, keywords: kwUrl.keywords });
  } else if (urlLike) {
    items.push({ type: "index-url", uri: q.trim() });
  }

  data.forEach(r => {
    items.push({ type: "result", uri: r.uri, title: r.title, snip: r.snip });
  });

  if (!urlLike && !kwUrl) {
    items.push({ type: "index-prompt" });
  }

  selectedIndex = items.length > 0 ? 0 : -1;
  renderItems();
}

function renderItems() {
  if (items.length === 0) { hideResults(); return; }
  list.innerHTML = "";
  list.classList.remove("hidden");

  items.forEach((item, i) => {
    const li = document.createElement("li");
    li.dataset.index = i;
    li.className = "cursor-pointer transition-colors duration-75";

    if (item.type === "result") {
      const wrapper = document.createElement("div");
      wrapper.className = "flex items-start hover:bg-gray-800";

      const a = document.createElement("a");
      a.href = item.uri;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.className = "block px-4 py-3 flex-1 min-w-0";
      a.addEventListener("click", (e) => e.stopPropagation());

      const titleDiv = document.createElement("div");
      titleDiv.className = "font-semibold text-blue-400 truncate";
      titleDiv.textContent = item.title || item.uri;

      const uriDiv = document.createElement("div");
      uriDiv.className = "text-xs text-gray-500 truncate mt-0.5";
      uriDiv.textContent = item.uri;

      const snipDiv = document.createElement("div");
      snipDiv.className = "text-sm text-gray-300 mt-1 line-clamp-2";
      snipDiv.innerHTML = item.snip || "";

      a.append(titleDiv, uriDiv, snipDiv);

      const delBtn = document.createElement("button");
      delBtn.className = "px-3 py-3 text-gray-500 hover:text-red-400 shrink-0";
      delBtn.innerHTML = "&times;";
      delBtn.title = "Delete";
      delBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        doDelete(item.uri, item.title || item.uri);
      });

      wrapper.append(a, delBtn);
      li.appendChild(wrapper);
    } else if (item.type === "index-keyword") {
      const div = document.createElement("div");
      div.className = "px-4 py-3 flex items-center gap-2";
      div.innerHTML = '<span class="text-green-400 text-lg">+</span>' +
        '<span class="text-gray-200">Index <span class="text-green-400 font-medium">' +
        escapeHtml(item.uri) + '</span> with keyword <span class="text-yellow-400 font-medium">' +
        escapeHtml(item.keywords) + '</span></span>';
      li.appendChild(div);
      li.addEventListener("click", () => doIndexWithKeywords(item.uri, item.keywords));
    } else if (item.type === "index-url") {
      const div = document.createElement("div");
      div.className = "px-4 py-3 flex items-center gap-2";
      div.innerHTML = '<span class="text-green-400 text-lg">+</span>' +
        '<span class="text-gray-200">Index <span class="text-green-400 font-medium">' +
        escapeHtml(item.uri) + '</span></span>';
      li.appendChild(div);
      li.addEventListener("click", () => doIndex(item.uri));
    } else if (item.type === "index-prompt") {
      const div = document.createElement("div");
      div.className = "px-4 py-3 flex items-center gap-2";
      div.innerHTML = '<span class="text-green-400 text-lg">+</span>' +
        '<span class="text-gray-400">Index a URL...</span>';
      li.appendChild(div);
      li.addEventListener("click", () => enterIndexMode());
    }

    li.addEventListener("mouseenter", () => {
      selectedIndex = i;
      updateSelection();
    });

    list.appendChild(li);
  });
  updateSelection();
}

function updateSelection() {
  const children = list.children;
  for (let i = 0; i < children.length; i++) {
    children[i].classList.toggle("bg-gray-800", i === selectedIndex);
  }
  if (selectedIndex >= 0 && children[selectedIndex]) {
    children[selectedIndex].scrollIntoView({ block: "nearest" });
  }
}

function openExternal(url) {
  window.open(url, "_blank", "noopener");
}

function activateItem(idx) {
  const item = items[idx];
  if (!item) return;
  if (item.type === "result") {
    openExternal(item.uri);
  } else if (item.type === "index-keyword") {
    doIndexWithKeywords(item.uri, item.keywords);
  } else if (item.type === "index-url") {
    doIndex(item.uri);
  } else if (item.type === "index-prompt") {
    enterIndexMode();
  }
}

function enterIndexMode() {
  mode = "index-input";
  input.value = "";
  input.placeholder = "URL to index...";
  input.classList.add("ring-2", "ring-green-500");
  input.classList.remove("focus:ring-blue-500");
  cancelBtn.classList.remove("hidden");
  hideResults();
}

function exitIndexMode() {
  mode = "search";
  input.value = "";
  input.placeholder = "Search...";
  input.classList.remove("ring-2", "ring-green-500");
  input.classList.add("focus:ring-blue-500");
  cancelBtn.classList.add("hidden");
  hideResults();
}

async function doIndex(uri) {
  showStatus("Indexing...");
  hideResults();
  try {
    const res = await fetch("/api/index", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ uri })
    });
    const data = await res.json();
    if (!res.ok) {
      showError(data.error || "Unknown error");
      return;
    }
    if (data.status === "unchanged") {
      showStatus("Unchanged: " + (data.title || uri));
    } else if (data.status === "bookmarked") {
      showStatus("Bookmarked: " + (data.title || uri) + " (" + data.error + ")");
    } else {
      showStatus("Indexed: " + (data.title || uri) + " (" + data.chunks + " chunks)");
    }
    if (mode === "index-input") exitIndexMode();
    else { input.value = ""; }
  } catch (e) {
    showError(e.message);
  }
}

async function doIndexWithKeywords(uri, keywords) {
  showStatus("Indexing with keywords...");
  hideResults();
  try {
    const res = await fetch("/api/index", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ uri, keywords: keywords.split(/\s+/) })
    });
    const data = await res.json();
    if (!res.ok) {
      showError(data.error || "Unknown error");
      return;
    }
    if (data.status === "keywords_updated") {
      showStatus("Keywords updated: " + (data.title || uri));
    } else if (data.status === "unchanged") {
      showStatus("Unchanged: " + (data.title || uri));
    } else if (data.status === "bookmarked") {
      showStatus("Bookmarked: " + (data.title || uri) + " (" + data.error + ")");
    } else {
      showStatus("Indexed: " + (data.title || uri) + " (" + data.chunks + " chunks)");
    }
    input.value = "";
  } catch (e) {
    showError(e.message);
  }
}

async function doDelete(uri, title) {
  if (!confirm("Delete " + title + "?")) return;
  try {
    const res = await fetch("/api/index", {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ uri })
    });
    const data = await res.json();
    if (!res.ok) {
      showError(data.error || "Unknown error");
      return;
    }
    showStatus("Deleted: " + title);
    doSearch();
  } catch (e) {
    showError(e.message);
  }
}

const errorPopup = document.getElementById("error-popup");
const errorMsg = document.getElementById("error-msg");
document.getElementById("error-close").addEventListener("click", () => errorPopup.classList.add("hidden"));
errorPopup.addEventListener("click", (e) => { if (e.target === errorPopup) errorPopup.classList.add("hidden"); });
document.getElementById("error-copy").addEventListener("click", () => {
  navigator.clipboard.writeText(errorMsg.textContent);
});

function showError(msg) {
  errorMsg.textContent = msg;
  errorPopup.classList.remove("hidden");
}

let hideTimer = null;
function showStatus(msg) {
  clearTimeout(hideTimer);
  if (!msg) { statusEl.classList.add("hidden"); return; }
  statusEl.textContent = msg;
  statusEl.className = "mt-2 text-sm text-green-400";
  statusEl.classList.remove("hidden");
  hideTimer = setTimeout(() => statusEl.classList.add("hidden"), 4000);
}

function hideResults() {
  list.classList.add("hidden");
  items = [];
  selectedIndex = -1;
}

function escapeHtml(s) {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}

cancelBtn.addEventListener("click", () => exitIndexMode());

document.addEventListener("click", (e) => {
  if (!list.classList.contains("hidden") && !list.contains(e.target) && e.target !== input) {
    hideResults();
  }
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js");
}
</script>
  <footer class="fixed bottom-2 right-3 text-xs text-gray-600">
    <a href="https://github.com/hogelog/doko" target="_blank" rel="noopener noreferrer" class="hover:text-gray-400">doko</a>
    <span class="ml-1"><%= GIT_REVISION %></span>
  </footer>
</body>
</html>
