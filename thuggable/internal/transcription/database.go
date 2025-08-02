// internal/transcription/database.go
package transcription

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// TranscriptionDB manages word-timestamped transcriptions
type TranscriptionDB struct {
	db *sql.DB
}

// WordTimestamp represents a word with its timing information
type WordTimestamp struct {
	ID          int64
	RecordingID int64
	Word        string
	StartTime   float64 // seconds from start
	EndTime     float64
	Confidence  float64
}

// Recording represents a recording session
type Recording struct {
	ID         int64
	Artist     string
	Song       string
	Ticker     string
	StartTime  time.Time
	Duration   float64
	BattleID   string // Links to casa.rs battle
}

// NewTranscriptionDB creates a new transcription database
func NewTranscriptionDB(dbPath string) (*TranscriptionDB, error) {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, err
	}

	tdb := &TranscriptionDB{db: db}
	if err := tdb.createTables(); err != nil {
		return nil, err
	}

	return tdb, nil
}

// createTables creates the database schema
func (tdb *TranscriptionDB) createTables() error {
	schema := `
	CREATE TABLE IF NOT EXISTS recordings (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		artist TEXT NOT NULL,
		song TEXT NOT NULL,
		ticker TEXT NOT NULL,
		start_time DATETIME NOT NULL,
		duration REAL NOT NULL,
		battle_id TEXT,
		UNIQUE(artist, song)
	);

	CREATE TABLE IF NOT EXISTS word_timestamps (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		recording_id INTEGER NOT NULL,
		word TEXT NOT NULL,
		start_time REAL NOT NULL,
		end_time REAL NOT NULL,
		confidence REAL NOT NULL,
		FOREIGN KEY(recording_id) REFERENCES recordings(id)
	);

	CREATE INDEX IF NOT EXISTS idx_word_timestamps_recording 
		ON word_timestamps(recording_id);
	
	CREATE INDEX IF NOT EXISTS idx_word_timestamps_time 
		ON word_timestamps(recording_id, start_time);
	
	CREATE INDEX IF NOT EXISTS idx_recordings_artist_song 
		ON recordings(artist, song);
	
	CREATE INDEX IF NOT EXISTS idx_recordings_ticker 
		ON recordings(ticker);
	`

	_, err := tdb.db.Exec(schema)
	return err
}

// CreateRecording creates a new recording entry
func (tdb *TranscriptionDB) CreateRecording(artist, song, ticker string, battleID string) (*Recording, error) {
	// Check if recording already exists
	var existingID int64
	err := tdb.db.QueryRow(
		"SELECT id FROM recordings WHERE artist = ? AND song = ?",
		artist, song,
	).Scan(&existingID)

	if err == nil {
		// Recording exists, return it
		return tdb.GetRecording(existingID)
	}

	// Create new recording
	result, err := tdb.db.Exec(
		`INSERT INTO recordings (artist, song, ticker, start_time, duration, battle_id) 
		 VALUES (?, ?, ?, ?, 0, ?)`,
		artist, song, ticker, time.Now(), battleID,
	)
	if err != nil {
		return nil, err
	}

	id, err := result.LastInsertId()
	if err != nil {
		return nil, err
	}

	return tdb.GetRecording(id)
}

// GetRecording retrieves a recording by ID
func (tdb *TranscriptionDB) GetRecording(id int64) (*Recording, error) {
	rec := &Recording{}
	err := tdb.db.QueryRow(
		`SELECT id, artist, song, ticker, start_time, duration, battle_id 
		 FROM recordings WHERE id = ?`,
		id,
	).Scan(&rec.ID, &rec.Artist, &rec.Song, &rec.Ticker, &rec.StartTime, &rec.Duration, &rec.BattleID)

	if err != nil {
		return nil, err
	}
	return rec, nil
}

// GetRecordingByArtistSong retrieves a recording by artist and song
func (tdb *TranscriptionDB) GetRecordingByArtistSong(artist, song string) (*Recording, error) {
	rec := &Recording{}
	err := tdb.db.QueryRow(
		`SELECT id, artist, song, ticker, start_time, duration, battle_id 
		 FROM recordings WHERE artist = ? AND song = ?`,
		artist, song,
	).Scan(&rec.ID, &rec.Artist, &rec.Song, &rec.Ticker, &rec.StartTime, &rec.Duration, &rec.BattleID)

	if err != nil {
		return nil, err
	}
	return rec, nil
}

// AddWordTimestamp adds a word with timestamp to the database
func (tdb *TranscriptionDB) AddWordTimestamp(recordingID int64, word string, startTime, endTime, confidence float64) error {
	_, err := tdb.db.Exec(
		`INSERT INTO word_timestamps (recording_id, word, start_time, end_time, confidence) 
		 VALUES (?, ?, ?, ?, ?)`,
		recordingID, word, startTime, endTime, confidence,
	)
	return err
}

// AddWordTimestamps adds multiple word timestamps in a transaction
func (tdb *TranscriptionDB) AddWordTimestamps(recordingID int64, words []WordTimestamp) error {
	tx, err := tdb.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(
		`INSERT INTO word_timestamps (recording_id, word, start_time, end_time, confidence) 
		 VALUES (?, ?, ?, ?, ?)`,
	)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, w := range words {
		_, err = stmt.Exec(recordingID, w.Word, w.StartTime, w.EndTime, w.Confidence)
		if err != nil {
			return err
		}
	}

	// Update recording duration
	if len(words) > 0 {
		lastWord := words[len(words)-1]
		_, err = tx.Exec(
			"UPDATE recordings SET duration = ? WHERE id = ?",
			lastWord.EndTime, recordingID,
		)
		if err != nil {
			return err
		}
	}

	return tx.Commit()
}

// GetWordsInTimeRange retrieves words within a time range
func (tdb *TranscriptionDB) GetWordsInTimeRange(recordingID int64, startTime, endTime float64) ([]WordTimestamp, error) {
	rows, err := tdb.db.Query(
		`SELECT id, recording_id, word, start_time, end_time, confidence 
		 FROM word_timestamps 
		 WHERE recording_id = ? AND start_time >= ? AND end_time <= ?
		 ORDER BY start_time`,
		recordingID, startTime, endTime,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var words []WordTimestamp
	for rows.Next() {
		var w WordTimestamp
		err := rows.Scan(&w.ID, &w.RecordingID, &w.Word, &w.StartTime, &w.EndTime, &w.Confidence)
		if err != nil {
			return nil, err
		}
		words = append(words, w)
	}

	return words, nil
}

// GetTranscript retrieves the full transcript for a recording
func (tdb *TranscriptionDB) GetTranscript(recordingID int64) (string, error) {
	rows, err := tdb.db.Query(
		`SELECT word FROM word_timestamps 
		 WHERE recording_id = ? 
		 ORDER BY start_time`,
		recordingID,
	)
	if err != nil {
		return "", err
	}
	defer rows.Close()

	transcript := ""
	for rows.Next() {
		var word string
		if err := rows.Scan(&word); err != nil {
			return "", err
		}
		if transcript != "" {
			transcript += " "
		}
		transcript += word
	}

	return transcript, nil
}

// GetRecordingsByTicker retrieves all recordings for a ticker
func (tdb *TranscriptionDB) GetRecordingsByTicker(ticker string) ([]Recording, error) {
	rows, err := tdb.db.Query(
		`SELECT id, artist, song, ticker, start_time, duration, battle_id 
		 FROM recordings 
		 WHERE ticker = ? 
		 ORDER BY start_time DESC`,
		ticker,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var recordings []Recording
	for rows.Next() {
		var rec Recording
		err := rows.Scan(&rec.ID, &rec.Artist, &rec.Song, &rec.Ticker, 
			&rec.StartTime, &rec.Duration, &rec.BattleID)
		if err != nil {
			return nil, err
		}
		recordings = append(recordings, rec)
	}

	return recordings, nil
}

// SearchWords searches for words across all recordings
func (tdb *TranscriptionDB) SearchWords(searchTerm string) ([]struct {
	Recording Recording
	Words     []WordTimestamp
}, error) {
	// First, find all recordings with matching words
	rows, err := tdb.db.Query(
		`SELECT DISTINCT r.id, r.artist, r.song, r.ticker, r.start_time, r.duration, r.battle_id
		 FROM recordings r
		 JOIN word_timestamps w ON r.id = w.recording_id
		 WHERE w.word LIKE ?
		 ORDER BY r.start_time DESC`,
		"%"+searchTerm+"%",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []struct {
		Recording Recording
		Words     []WordTimestamp
	}

	for rows.Next() {
		var rec Recording
		err := rows.Scan(&rec.ID, &rec.Artist, &rec.Song, &rec.Ticker,
			&rec.StartTime, &rec.Duration, &rec.BattleID)
		if err != nil {
			return nil, err
		}

		// Get matching words for this recording
		wordRows, err := tdb.db.Query(
			`SELECT id, recording_id, word, start_time, end_time, confidence
			 FROM word_timestamps
			 WHERE recording_id = ? AND word LIKE ?
			 ORDER BY start_time`,
			rec.ID, "%"+searchTerm+"%",
		)
		if err != nil {
			return nil, err
		}

		var words []WordTimestamp
		for wordRows.Next() {
			var w WordTimestamp
			err := wordRows.Scan(&w.ID, &w.RecordingID, &w.Word,
				&w.StartTime, &w.EndTime, &w.Confidence)
			if err != nil {
				wordRows.Close()
				return nil, err
			}
			words = append(words, w)
		}
		wordRows.Close()

		results = append(results, struct {
			Recording Recording
			Words     []WordTimestamp
		}{Recording: rec, Words: words})
	}

	return results, nil
}

// Close closes the database connection
func (tdb *TranscriptionDB) Close() error {
	return tdb.db.Close()
}