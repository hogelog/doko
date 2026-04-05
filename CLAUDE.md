# doko

Personal omnisearch tool. A single-file Sinatra web app that indexes local files and web pages into SQLite FTS5 for full-text search.

## Tech Stack

- **Ruby / Sinatra** - Web framework (single-file `app.rb` with inline ERB template)
- **SQLite3 + FTS5** - Storage and full-text search
- **Nokogiri** - HTML/XML text extraction
- **Tailwind CSS** (CDN) - Frontend styling
- **PWA** - Service worker for offline support

## Setup & Run

```bash
bundle install
ruby app.rb
```

Data is stored in `~/.local/share/doko/data.sqlite3`.

## Architecture

Everything lives in `app.rb`:

- **Database schema** - `sources` and `docs` tables, `docs_fts` FTS5 virtual table
- **Indexing** - Fetches content from file:// or http(s):// URIs, extracts text, chunks it (~1200 chars), and inserts into FTS
- **Search** - FTS5 MATCH query with BM25 ranking, plus LIKE fallback for partial matches
- **Keywords** - Optional keyword tagging on sources, boosted in FTS via title field
- **Frontend** - Inline ERB template with vanilla JS, search-as-you-type UI

### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/search?q=` | Full-text search |
| POST | `/api/index` | Index a URI (with optional keywords) |
| POST | `/api/click` | Boost keyword counts on click |
| DELETE | `/api/index` | Remove a source and its docs |

## Development Notes

- Single-file app: all backend code, migrations, routes, and the HTML template are in `app.rb`
- Migrations are applied inline at startup (idempotent `CREATE TABLE IF NOT EXISTS` + `ALTER TABLE` rescue pattern)
- Text is chunked at ~1200 characters on newline boundaries before indexing
- FTS delete/reinsert is done in transactions to keep the index consistent
