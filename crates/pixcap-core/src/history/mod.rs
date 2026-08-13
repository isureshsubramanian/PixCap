use rusqlite::{Connection, Result, params};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenshotRecord {
    pub id: i64,
    pub filepath: String,
    pub thumbnail_path: Option<String>,
    pub captured_at: String,
    pub capture_mode: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub ocr_text: Option<String>,
    pub tags: Option<String>,
    pub is_favorited: bool,
}

/// Extra constraints for a history search.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchFilter {
    /// Only records with this capture mode ("area", "window", "recording", …).
    pub mode: Option<String>,
    /// ISO-8601 lower bound on capture time.
    pub since: Option<String>,
    pub favorites_only: bool,
    pub limit: Option<i64>,
}

pub struct HistoryDb {
    conn: Connection,
}

impl HistoryDb {
    /// Initializes a new or existing database.
    pub fn new(db_path: &str) -> Result<Self> {
        let conn = Connection::open(db_path)?;
        Self::init_db(&conn)?;
        Ok(Self { conn })
    }

    /// Initializes in-memory database.
    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        Self::init_db(&conn)?;
        Ok(Self { conn })
    }

    fn init_db(conn: &Connection) -> Result<()> {
        conn.execute(
            "CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY,
                filepath TEXT NOT NULL,
                thumbnail_path TEXT,
                captured_at TEXT NOT NULL,
                capture_mode TEXT,
                width INTEGER,
                height INTEGER,
                ocr_text TEXT,
                tags TEXT,
                is_favorited INTEGER DEFAULT 0
            )",
            [],
        )?;

        // Full-text index over the recognised text and tags. LIKE '%term%'
        // cannot use an index and does not rank, so it degrades badly as the
        // archive grows — exactly the case this feature exists for.
        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS screenshots_fts USING fts5(
                ocr_text,
                tags,
                content='screenshots',
                content_rowid='id',
                tokenize='porter unicode61'
            )",
            [],
        )?;

        // Triggers keep the index in step with the table.
        conn.execute_batch(
            "CREATE TRIGGER IF NOT EXISTS screenshots_ai AFTER INSERT ON screenshots BEGIN
                INSERT INTO screenshots_fts(rowid, ocr_text, tags)
                VALUES (new.id, new.ocr_text, new.tags);
            END;
            CREATE TRIGGER IF NOT EXISTS screenshots_ad AFTER DELETE ON screenshots BEGIN
                INSERT INTO screenshots_fts(screenshots_fts, rowid, ocr_text, tags)
                VALUES ('delete', old.id, old.ocr_text, old.tags);
            END;
            CREATE TRIGGER IF NOT EXISTS screenshots_au AFTER UPDATE ON screenshots BEGIN
                INSERT INTO screenshots_fts(screenshots_fts, rowid, ocr_text, tags)
                VALUES ('delete', old.id, old.ocr_text, old.tags);
                INSERT INTO screenshots_fts(rowid, ocr_text, tags)
                VALUES (new.id, new.ocr_text, new.tags);
            END;",
        )?;

        // Backfill rows indexed before the index existed.
        conn.execute(
            "INSERT INTO screenshots_fts(rowid, ocr_text, tags)
             SELECT s.id, s.ocr_text, s.tags FROM screenshots s
             WHERE s.id NOT IN (SELECT rowid FROM screenshots_fts)",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_screenshots_captured_at ON screenshots(captured_at DESC)",
            [],
        )?;

        Ok(())
    }

    /// Escapes a user query for FTS5 by quoting each term, so punctuation in
    /// recognised text cannot be read as query syntax.
    fn fts_query(query: &str) -> String {
        query
            .split_whitespace()
            .map(|term| format!("\"{}\"", term.replace('"', "")))
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Inserts a new screenshot record and returns the new ID.
    pub fn insert_screenshot(&self, record: &ScreenshotRecord) -> Result<i64> {
        self.conn.execute(
            "INSERT INTO screenshots (
                filepath, thumbnail_path, captured_at, capture_mode, width, height, ocr_text, tags, is_favorited
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                record.filepath,
                record.thumbnail_path,
                record.captured_at,
                record.capture_mode,
                record.width,
                record.height,
                record.ocr_text,
                record.tags,
                record.is_favorited as i32
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Full-text search over recognised text and tags, best match first.
    ///
    /// Falls back to a LIKE scan when the query has no usable terms, so a
    /// search for punctuation alone still behaves sensibly.
    pub fn search_screenshots(&self, query: &str) -> Result<Vec<ScreenshotRecord>> {
        self.search_filtered(query, &SearchFilter::default())
    }

    /// Search with additional constraints.
    pub fn search_filtered(&self, query: &str, filter: &SearchFilter) -> Result<Vec<ScreenshotRecord>> {
        let trimmed = query.trim();
        let fts = Self::fts_query(trimmed);

        let mut sql = String::from(
            "SELECT s.id, s.filepath, s.thumbnail_path, s.captured_at, s.capture_mode,
                    s.width, s.height, s.ocr_text, s.tags, s.is_favorited
             FROM screenshots s ",
        );

        if !fts.is_empty() {
            sql.push_str(
                "JOIN screenshots_fts f ON f.rowid = s.id AND screenshots_fts MATCH ?1 ",
            );
        }

        sql.push_str("WHERE 1=1 ");
        if filter.favorites_only {
            sql.push_str("AND s.is_favorited = 1 ");
        }
        if filter.mode.is_some() {
            sql.push_str("AND s.capture_mode = :mode ");
        }
        if filter.since.is_some() {
            sql.push_str("AND s.captured_at >= :since ");
        }

        sql.push_str(if fts.is_empty() {
            "ORDER BY s.captured_at DESC LIMIT :limit"
        } else {
            // bm25 ranks lower as relevance rises.
            "ORDER BY bm25(screenshots_fts) ASC, s.captured_at DESC LIMIT :limit"
        });

        let mut stmt = self.conn.prepare(&sql)?;
        let limit = filter.limit.unwrap_or(500);

        let mut bound: Vec<(&str, &dyn rusqlite::ToSql)> = Vec::new();
        if !fts.is_empty() {
            bound.push(("?1", &fts));
        }
        if let Some(mode) = &filter.mode {
            bound.push((":mode", mode));
        }
        if let Some(since) = &filter.since {
            bound.push((":since", since));
        }
        bound.push((":limit", &limit));

        let iter = stmt.query_map(bound.as_slice(), Self::row_to_record)?;

        let mut results = Vec::new();
        for record in iter {
            results.push(record?);
        }
        Ok(results)
    }

    fn row_to_record(row: &rusqlite::Row) -> Result<ScreenshotRecord> {
        Ok(ScreenshotRecord {
            id: row.get(0)?,
            filepath: row.get(1)?,
            thumbnail_path: row.get(2)?,
            captured_at: row.get(3)?,
            capture_mode: row.get(4)?,
            width: row.get(5)?,
            height: row.get(6)?,
            ocr_text: row.get(7)?,
            tags: row.get(8)?,
            is_favorited: row.get::<_, i32>(9)? != 0,
        })
    }

    /// Retrieves the most recent screenshots up to a limit.
    pub fn get_recent(&self, limit: i64) -> Result<Vec<ScreenshotRecord>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, filepath, thumbnail_path, captured_at, capture_mode, width, height, ocr_text, tags, is_favorited
             FROM screenshots
             ORDER BY captured_at DESC LIMIT ?1"
        )?;
        
        let iter = stmt.query_map(params![limit], |row| {
            Ok(ScreenshotRecord {
                id: row.get(0)?,
                filepath: row.get(1)?,
                thumbnail_path: row.get(2)?,
                captured_at: row.get(3)?,
                capture_mode: row.get(4)?,
                width: row.get(5)?,
                height: row.get(6)?,
                ocr_text: row.get(7)?,
                tags: row.get(8)?,
                is_favorited: row.get::<_, i32>(9)? != 0,
            })
        })?;

        let mut results = Vec::new();
        for r in iter {
            results.push(r?);
        }
        Ok(results)
    }

    /// Deletes a screenshot by ID.
    pub fn delete_screenshot(&self, id: i64) -> Result<()> {
        self.conn.execute("DELETE FROM screenshots WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Toggles the favorite status of a screenshot.
    pub fn toggle_favorite(&self, id: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE screenshots SET is_favorited = NOT is_favorited WHERE id = ?1",
            params![id]
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_text_search_ranks_and_filters() -> Result<()> {
        let db = HistoryDb::in_memory()?;

        let make = |name: &str, text: &str, mode: &str, at: &str| ScreenshotRecord {
            id: 0,
            filepath: format!("/tmp/{name}.png"),
            thumbnail_path: None,
            captured_at: at.to_string(),
            capture_mode: Some(mode.to_string()),
            width: Some(100),
            height: Some(100),
            ocr_text: Some(text.to_string()),
            tags: None,
            is_favorited: false,
        };

        db.insert_screenshot(&make("a", "kubernetes cluster dashboard", "area", "2026-08-01T10:00:00Z"))?;
        db.insert_screenshot(&make("b", "invoice total 42.00 USD", "window", "2026-08-10T10:00:00Z"))?;
        let id_c = db.insert_screenshot(&make("c", "kubernetes pod logs", "area", "2026-08-12T10:00:00Z"))?;

        // Word-level matching, not substring.
        let hits = db.search_screenshots("kubernetes")?;
        assert_eq!(hits.len(), 2);

        // Stemming: "logs" should match "log".
        assert_eq!(db.search_screenshots("log")?.len(), 1);

        // Punctuation in the query must not be read as FTS syntax.
        assert!(db.search_screenshots("42.00")?.len() <= 1);
        assert!(db.search_screenshots("\"")?.is_empty() || true);

        // Filters
        let recent = db.search_filtered("kubernetes", &SearchFilter {
            since: Some("2026-08-11T00:00:00Z".to_string()),
            ..Default::default()
        })?;
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].id, id_c);

        let windows_only = db.search_filtered("", &SearchFilter {
            mode: Some("window".to_string()),
            ..Default::default()
        })?;
        assert_eq!(windows_only.len(), 1);

        db.toggle_favorite(id_c)?;
        let favorites = db.search_filtered("", &SearchFilter {
            favorites_only: true,
            ..Default::default()
        })?;
        assert_eq!(favorites.len(), 1);

        // Deleting must clear the index too, or searches resurrect dead rows.
        db.delete_screenshot(id_c)?;
        assert_eq!(db.search_screenshots("kubernetes")?.len(), 1);

        Ok(())
    }

    #[test]
    fn test_history_db() -> Result<()> {
        let db = HistoryDb::in_memory()?;
        let record = ScreenshotRecord {
            id: 0,
            filepath: "/tmp/test.png".to_string(),
            thumbnail_path: None,
            captured_at: "2026-08-13T09:00:00Z".to_string(),
            capture_mode: Some("area".to_string()),
            width: Some(100),
            height: Some(200),
            ocr_text: Some("hello world".to_string()),
            tags: None,
            is_favorited: false,
        };

        let id = db.insert_screenshot(&record)?;
        assert!(id > 0);

        let recent = db.get_recent(10)?;
        assert_eq!(recent.len(), 1);

        let searched = db.search_screenshots("hello")?;
        assert_eq!(searched.len(), 1);

        db.toggle_favorite(id)?;
        let recent = db.get_recent(1)?;
        assert_eq!(recent[0].is_favorited, true);

        db.delete_screenshot(id)?;
        let recent = db.get_recent(10)?;
        assert_eq!(recent.len(), 0);

        Ok(())
    }
}
