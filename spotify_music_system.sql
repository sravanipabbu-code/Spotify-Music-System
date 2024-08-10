
-- =============================================================
-- Project: Spotify-like Music System (MySQL 8+)
-- Author: ChatGPT
-- Description: Full schema, constraints, triggers, views,
--              stored procedures, and analytics queries.
-- =============================================================

DROP DATABASE IF EXISTS spotify_system;
CREATE DATABASE spotify_system;
USE spotify_system;

-- =============================================================
-- 1) CORE SCHEMA
-- =============================================================

-- Users of the platform
CREATE TABLE users (
  user_id INT PRIMARY KEY AUTO_INCREMENT,
  email VARCHAR(120) NOT NULL UNIQUE,
  display_name VARCHAR(80) NOT NULL,
  country CHAR(2),
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Artists
CREATE TABLE artists (
  artist_id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(120) NOT NULL,
  bio TEXT,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uniq_artist_name (name)
);

-- Albums
CREATE TABLE albums (
  album_id INT PRIMARY KEY AUTO_INCREMENT,
  artist_id INT NOT NULL,
  title VARCHAR(160) NOT NULL,
  release_date DATE,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (artist_id) REFERENCES artists(artist_id),
  INDEX (artist_id, release_date)
);

-- Tracks
CREATE TABLE tracks (
  track_id INT PRIMARY KEY AUTO_INCREMENT,
  album_id INT NOT NULL,
  title VARCHAR(160) NOT NULL,
  duration_sec INT NOT NULL CHECK (duration_sec > 0),
  explicit TINYINT(1) NOT NULL DEFAULT 0,
  popularity INT NOT NULL DEFAULT 0 CHECK (popularity >= 0),
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (album_id) REFERENCES albums(album_id),
  INDEX (album_id),
  FULLTEXT KEY ft_track_title (title)
) ENGINE=InnoDB;

-- Track ↔ Artist (for collabs)
CREATE TABLE track_artists (
  track_id INT NOT NULL,
  artist_id INT NOT NULL,
  role ENUM('PRIMARY','FEATURED') NOT NULL DEFAULT 'PRIMARY',
  PRIMARY KEY (track_id, artist_id),
  FOREIGN KEY (track_id) REFERENCES tracks(track_id),
  FOREIGN KEY (artist_id) REFERENCES artists(artist_id)
);

-- Genres
CREATE TABLE genres (
  genre_id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(60) NOT NULL UNIQUE
);

-- Track ↔ Genre
CREATE TABLE track_genres (
  track_id INT NOT NULL,
  genre_id INT NOT NULL,
  PRIMARY KEY (track_id, genre_id),
  FOREIGN KEY (track_id) REFERENCES tracks(track_id),
  FOREIGN KEY (genre_id) REFERENCES genres(genre_id)
);

-- Playlists
CREATE TABLE playlists (
  playlist_id INT PRIMARY KEY AUTO_INCREMENT,
  owner_user_id INT NOT NULL,
  name VARCHAR(120) NOT NULL,
  is_public TINYINT(1) NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (owner_user_id) REFERENCES users(user_id),
  INDEX (owner_user_id)
);

-- Playlist tracks (ordered)
CREATE TABLE playlist_tracks (
  playlist_id INT NOT NULL,
  track_id INT NOT NULL,
  position INT NOT NULL,
  added_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (playlist_id, track_id),
  FOREIGN KEY (playlist_id) REFERENCES playlists(playlist_id),
  FOREIGN KEY (track_id) REFERENCES tracks(track_id)
);

-- Follows: user follows artist or playlist
CREATE TABLE follows_artists (
  user_id INT NOT NULL,
  artist_id INT NOT NULL,
  followed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, artist_id),
  FOREIGN KEY (user_id) REFERENCES users(user_id),
  FOREIGN KEY (artist_id) REFERENCES artists(artist_id)
);

CREATE TABLE follows_playlists (
  user_id INT NOT NULL,
  playlist_id INT NOT NULL,
  followed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, playlist_id),
  FOREIGN KEY (user_id) REFERENCES users(user_id),
  FOREIGN KEY (playlist_id) REFERENCES playlists(playlist_id)
);

-- Likes (user likes a track)
CREATE TABLE likes_tracks (
  user_id INT NOT NULL,
  track_id INT NOT NULL,
  liked_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, track_id),
  FOREIGN KEY (user_id) REFERENCES users(user_id),
  FOREIGN KEY (track_id) REFERENCES tracks(track_id)
);

-- Listening history (fact table)
CREATE TABLE listening_history (
  listen_id BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id INT NOT NULL,
  track_id INT NOT NULL,
  played_at DATETIME NOT NULL,
  source ENUM('SEARCH','PLAYLIST','ALBUM','RADIO','RECS') NOT NULL,
  ms_played INT NOT NULL CHECK (ms_played >= 0),
  device ENUM('MOBILE','DESKTOP','WEB','TV') NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(user_id),
  FOREIGN KEY (track_id) REFERENCES tracks(track_id),
  INDEX (user_id, played_at),
  INDEX (track_id, played_at)
);

-- Materialized stats table (optional aggregate)
CREATE TABLE track_stats_daily (
  track_id INT NOT NULL,
  play_date DATE NOT NULL,
  plays INT NOT NULL,
  unique_listeners INT NOT NULL,
  PRIMARY KEY (track_id, play_date),
  FOREIGN KEY (track_id) REFERENCES tracks(track_id)
);

-- =============================================================
-- 2) BUSINESS LOGIC
-- =============================================================

-- When a like is added, nudge track popularity
DROP TRIGGER IF EXISTS trg_like_inc_popularity;
DELIMITER $$
CREATE TRIGGER trg_like_inc_popularity
AFTER INSERT ON likes_tracks
FOR EACH ROW
BEGIN
  UPDATE tracks SET popularity = popularity + 1 WHERE track_id = NEW.track_id;
END$$
DELIMITER ;

-- Procedure to refresh daily track stats
DROP PROCEDURE IF EXISTS sp_refresh_track_stats_daily;
DELIMITER $$
CREATE PROCEDURE sp_refresh_track_stats_daily(p_day DATE)
BEGIN
  REPLACE INTO track_stats_daily (track_id, play_date, plays, unique_listeners)
  SELECT
    lh.track_id,
    p_day AS play_date,
    COUNT(*) AS plays,
    COUNT(DISTINCT lh.user_id) AS unique_listeners
  FROM listening_history lh
  WHERE DATE(lh.played_at) = p_day
  GROUP BY lh.track_id;
END$$
DELIMITER ;

-- Simple "people also listen to" recommendations:
-- For a given user, find tracks frequently co-listened by similar users.
DROP PROCEDURE IF EXISTS sp_recommend_tracks;
DELIMITER $$
CREATE PROCEDURE sp_recommend_tracks(p_user INT, p_limit INT)
BEGIN
  WITH user_tracks AS (
    SELECT DISTINCT track_id FROM listening_history WHERE user_id = p_user
  ),
  similar_users AS (
    SELECT lh.user_id, COUNT(*) overlap
    FROM listening_history lh
    JOIN user_tracks ut ON ut.track_id = lh.track_id
    WHERE lh.user_id <> p_user
    GROUP BY lh.user_id
    HAVING overlap >= 2
  ),
  candidate_tracks AS (
    SELECT lh.track_id, SUM(su.overlap) score
    FROM listening_history lh
    JOIN similar_users su ON su.user_id = lh.user_id
    WHERE lh.track_id NOT IN (SELECT track_id FROM user_tracks)
    GROUP BY lh.track_id
  )
  SELECT t.track_id, t.title, a.name AS artist, c.score
  FROM candidate_tracks c
  JOIN tracks t ON t.track_id = c.track_id
  JOIN track_artists ta ON ta.track_id = t.track_id AND ta.role='PRIMARY'
  JOIN artists a ON a.artist_id = ta.artist_id
  ORDER BY c.score DESC, t.popularity DESC
  LIMIT p_limit;
END$$
DELIMITER ;

-- Search view (denormalized)
CREATE OR REPLACE VIEW v_search AS
SELECT
  t.track_id,
  t.title AS track_title,
  a.name AS artist_name,
  al.title AS album_title,
  t.duration_sec,
  t.popularity
FROM tracks t
JOIN albums al ON al.album_id = t.album_id
JOIN track_artists ta ON ta.track_id = t.track_id AND ta.role='PRIMARY'
JOIN artists a ON a.artist_id = ta.artist_id;

-- Top tracks by country (based on listening history)
CREATE OR REPLACE VIEW v_top_tracks_country AS
SELECT
  u.country,
  t.track_id,
  t.title,
  COUNT(*) AS plays
FROM listening_history lh
JOIN users u ON u.user_id = lh.user_id
JOIN tracks t ON t.track_id = lh.track_id
GROUP BY u.country, t.track_id, t.title;

-- =============================================================
-- 3) SAMPLE DATA
-- =============================================================

INSERT INTO users (email, display_name, country) VALUES
('sravani@example.com','Sravani','US'),
('alex@example.com','Alex','US'),
('priya@example.com','Priya','IN'),
('diego@example.com','Diego','MX'),
('mia@example.com','Mia','US');

INSERT INTO artists (name) VALUES
('The Quantum Keys'),
('Neon Avenue'),
('Desert Bloom');

INSERT INTO albums (artist_id, title, release_date) VALUES
(1, 'Entangled Dreams', '2025-01-10'),
(2, 'City Lights', '2024-11-05'),
(3, 'Cactus Flower', '2024-06-20');

INSERT INTO tracks (album_id, title, duration_sec, explicit, popularity) VALUES
(1, 'Superposition', 212, 0, 15),
(1, 'Quantum Waltz', 189, 0, 8),
(2, 'Midnight Drive', 240, 0, 21),
(2, 'Neon Skies', 206, 0, 10),
(3, 'Oasis', 198, 0, 7);

INSERT INTO track_artists (track_id, artist_id, role) VALUES
(1,1,'PRIMARY'),
(2,1,'PRIMARY'),
(3,2,'PRIMARY'),
(4,2,'PRIMARY'),
(5,3,'PRIMARY');

INSERT INTO genres (name) VALUES
('Electronic'),('Synthwave'),('Indie'),('Ambient');

INSERT INTO track_genres VALUES
(1,1),(1,4),
(2,1),
(3,2),
(4,2),(4,1),
(5,3);

INSERT INTO playlists (owner_user_id, name, is_public) VALUES
(1,'Focus Mode',1),
(2,'Night Ride',1),
(3,'Chill Vibes',0);

INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES
(1,1,1),(1,2,2),
(2,3,1),(2,4,2),
(3,5,1);

INSERT INTO likes_tracks VALUES
(1,1,NOW()), (1,3,NOW()), (2,3,NOW()), (3,5,NOW());

-- Listening history (spread across time)
INSERT INTO listening_history (user_id, track_id, played_at, source, ms_played, device) VALUES
(1,1,'2025-08-01 09:01:00','PLAYLIST',200000,'MOBILE'),
(1,2,'2025-08-01 09:05:00','PLAYLIST',180000,'MOBILE'),
(1,3,'2025-08-02 21:10:00','SEARCH',230000,'DESKTOP'),
(2,3,'2025-08-02 21:12:00','PLAYLIST',230000,'WEB'),
(2,4,'2025-08-03 18:00:00','PLAYLIST',200000,'WEB'),
(3,5,'2025-08-03 07:45:00','ALBUM',190000,'MOBILE'),
(4,1,'2025-08-04 10:00:00','RADIO',210000,'MOBILE'),
(5,4,'2025-08-05 12:30:00','RECS',200000,'DESKTOP'),
(5,3,'2025-08-05 12:35:00','RECS',230000,'DESKTOP');

-- Seed daily stats for yesterday/today
CALL sp_refresh_track_stats_daily(CURRENT_DATE - INTERVAL 1 DAY);
CALL sp_refresh_track_stats_daily(CURRENT_DATE);

-- =============================================================
-- 4) QUICK QUERIES
-- =============================================================

-- Search tracks
-- SELECT * FROM v_search WHERE track_title LIKE '%Drive%';

-- Top tracks in US
-- SELECT * FROM v_top_tracks_country WHERE country='US' ORDER BY plays DESC;

-- Recommend tracks for user_id=1
-- CALL sp_recommend_tracks(1, 5);

-- Refresh stats for a specific day
-- CALL sp_refresh_track_stats_daily('2025-08-05');

-- Show daily plays for 'Midnight Drive'
-- SELECT * FROM track_stats_daily tsd JOIN tracks t ON t.track_id=tsd.track_id
-- WHERE t.title='Midnight Drive' ORDER BY play_date;
