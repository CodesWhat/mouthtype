-- Synthetic database as the v0.10.0 release left it: migrations v1, v2, v3, v4-history-search. No personal data.
-- Interrupted row (unfinished, inside the recovery window): 00000000-0000-0000-0000-000000000027

CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);

-- migration v1
CREATE TABLE dictation (
    id TEXT PRIMARY KEY NOT NULL,
    started_at REAL NOT NULL,
    utc_offset_s INTEGER NOT NULL,
    local_day TEXT NOT NULL,
    mode TEXT NOT NULL,
    trigger TEXT NOT NULL,
    status TEXT NOT NULL,
    error_message TEXT,

    capture_start_ms INTEGER, first_sample_ms INTEGER, first_nonzero_ms INTEGER,
    speech_onset_ms INTEGER, key_up_ms INTEGER, asr_done_ms INTEGER,
    cleanup_done_ms INTEGER, insert_done_ms INTEGER,

    audio_ms INTEGER, voiced_ms INTEGER, audio_path TEXT, audio_expires_at REAL,
    input_device_uid TEXT, input_device_name TEXT, input_transport TEXT, sample_rate_hz INTEGER,
    rms_db REAL, peak_db REAL, noise_floor_db REAL,

    asr_engine_id TEXT, asr_model_rev TEXT, asr_ms INTEGER, asr_confidence REAL, language TEXT,
    word_timings_json TEXT, boost_terms_applied_json TEXT,

    raw_text TEXT, det_text TEXT, final_text TEXT,
    words_raw INTEGER, words_final INTEGER, chars_final INTEGER,

    cleaner_id TEXT, cleaner_rev TEXT, cleanup_level TEXT, style TEXT,
    cleanup_ms INTEGER, cleanup_outcome TEXT, prompt_sha TEXT,

    app_bundle_id TEXT, app_name TEXT, url_domain TEXT, window_title TEXT,
    category TEXT, field_role TEXT, is_secure INTEGER,

    insert_method TEXT, insert_outcome TEXT, focus_moved INTEGER, paste_receipt_ms INTEGER,

    retry_of TEXT, app_version TEXT, os_version TEXT
);
CREATE INDEX dictation_local_day ON dictation(local_day);
CREATE INDEX dictation_started_at ON dictation(started_at);
CREATE INDEX dictation_status ON dictation(status);

CREATE TABLE edit_op (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dictation_id TEXT NOT NULL REFERENCES dictation(id) ON DELETE CASCADE,
    stage TEXT NOT NULL,
    kind TEXT NOT NULL,
    from_text TEXT,
    to_text TEXT,
    word_delta INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX edit_op_dictation_id ON edit_op(dictation_id);

-- migration v2
CREATE TABLE correction (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dictation_id TEXT NOT NULL REFERENCES dictation(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'remember',
    heard TEXT NOT NULL,
    corrected TEXT NOT NULL,
    accepted INTEGER,
    created_at REAL NOT NULL
);
CREATE INDEX correction_dictation_id ON correction(dictation_id);

-- migration v3
CREATE INDEX dictation_stats ON dictation(local_day, words_final, started_at, voiced_ms, audio_ms, is_secure)
WHERE words_final > 0 AND COALESCE(is_secure, 0) = 0;

-- migration v4-history-search
CREATE VIRTUAL TABLE take_search USING fts5(raw_text, final_text, app_name);
INSERT INTO take_search(rowid, raw_text, final_text, app_name)
    SELECT rowid, raw_text, final_text, app_name FROM dictation
    WHERE final_text IS NOT NULL AND TRIM(final_text) != '' AND COALESCE(is_secure, 0) = 0;
CREATE TRIGGER take_search_insert AFTER INSERT ON dictation BEGIN
    INSERT INTO take_search(rowid, raw_text, final_text, app_name)
        SELECT new.rowid, new.raw_text, new.final_text, new.app_name
        WHERE new.final_text IS NOT NULL AND TRIM(new.final_text) != '' AND COALESCE(new.is_secure, 0) = 0;
END;
CREATE TRIGGER take_search_update AFTER UPDATE OF raw_text, final_text, app_name, is_secure ON dictation BEGIN
    DELETE FROM take_search WHERE rowid = old.rowid;
    INSERT INTO take_search(rowid, raw_text, final_text, app_name)
        SELECT new.rowid, new.raw_text, new.final_text, new.app_name
        WHERE new.final_text IS NOT NULL AND TRIM(new.final_text) != '' AND COALESCE(new.is_secure, 0) = 0;
END;
CREATE TRIGGER take_search_delete AFTER DELETE ON dictation BEGIN
    DELETE FROM take_search WHERE rowid = old.rowid;
END;

INSERT INTO grdb_migrations (identifier) VALUES ('v1');
INSERT INTO grdb_migrations (identifier) VALUES ('v2');
INSERT INTO grdb_migrations (identifier) VALUES ('v3');
INSERT INTO grdb_migrations (identifier) VALUES ('v4-history-search');

INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000001', 1791720100.0, 0, '2026-10-11', 'hold', 'fn', 'started', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000002', 1791720200.0, 0, '2026-10-11', 'hold', 'fn', 'recorded', NULL, 2000, 1500, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000003', 1791720300.0, 0, '2026-10-11', 'hold', 'fn', 'transcribed', NULL, NULL, NULL, NULL, 'synthetic transcribed words', NULL, NULL, 3, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000004', 1791720400.0, 0, '2026-10-11', 'hold', 'fn', 'inserted', NULL, 3000, 2400, NULL, 'hello synthetic world', NULL, 'Hello synthetic world.', 3, 3, 22, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000005', 1791720500.0, 0, '2026-10-11', 'hold', 'fn', 'cancelled', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000006', 1791720600.0, 0, '2026-10-11', 'hold', 'fn', 'too_short', NULL, 200, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000007', 1791720700.0, 0, '2026-10-11', 'hold', 'fn', 'empty', NULL, 1200, NULL, NULL, '', NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000008', 1791720800.0, 0, '2026-10-11', 'hold', 'fn', 'failed', 'synthetic failure', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000009', 1791721090.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 9', NULL, NULL, 3, 0, NULL, 'App9', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000010', 1791721100.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 10', NULL, '', 3, 0, NULL, 'App10', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000011', 1791721110.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 11', NULL, '   ', 3, 2, 3, 'App11', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000012', 1791721120.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'alpha raw 12', NULL, 'matrix text', 3, 2, 11, 'App12', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000013', 1791721130.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 13', NULL, NULL, 3, 0, NULL, 'App13', 0, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000014', 1791721140.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 14', NULL, '', 3, 0, NULL, 'App14', 0, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000015', 1791721150.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 15', NULL, '   ', 3, 2, 3, 'App15', 0, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000016', 1791721160.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'alpha raw 16', NULL, 'matrix text', 3, 2, 11, 'App16', 0, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000017', 1791721170.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 17', NULL, NULL, 3, 0, NULL, 'App17', 1, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000018', 1791721180.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 18', NULL, '', 3, 0, NULL, 'App18', 1, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000019', 1791721190.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'omega raw 19', NULL, '   ', 3, 2, 3, 'App19', 1, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000020', 1791721200.0, 0, '2026-10-12', 'hold', 'fn', 'inserted', NULL, 1800, 1400, NULL, 'alpha raw 20', NULL, 'matrix text', 3, 2, 11, 'App20', 1, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000021', 1791722000.0, 0, '2026-10-13', 'hold', 'fn', 'transcribed', NULL, NULL, NULL, NULL, 'raw only nothing inserted', NULL, NULL, 4, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000022', 1791722100.0, 0, '2026-10-13', 'hold', 'fn', 'failed', 'insert failed', NULL, NULL, NULL, 'raw only after failure', NULL, NULL, 4, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000023', 1791723000.0, 0, '2026-10-14', 'hold', 'fn', 'inserted', NULL, 2500, 2000, NULL, 'streak day 0', NULL, 'Streak day 0', 3, 3, 12, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000024', 1791723100.0, 0, '2026-10-15', 'hold', 'fn', 'inserted', NULL, 2500, 2000, NULL, 'streak day 1', NULL, 'Streak day 1', 3, 3, 12, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000025', 1791723200.0, 0, '2026-10-16', 'hold', 'fn', 'inserted', NULL, 2500, 2000, NULL, 'streak day 2', NULL, 'Streak day 2', 3, 3, 12, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000026', 1791723500.0, 0, '2026-10-16', 'hold', 'fn', 'failed', 'interrupted', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');
INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, error_message, audio_ms, voiced_ms, audio_path, raw_text, det_text, final_text, words_raw, words_final, chars_final, app_name, is_secure, language) VALUES ('00000000-0000-0000-0000-000000000027', 1791805800.0, 0, '2026-10-12', 'hold', 'fn', 'recorded', NULL, 4000, 3000, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Notes', NULL, 'en');

INSERT INTO edit_op (dictation_id, stage, kind, from_text, to_text, word_delta, position) VALUES ('00000000-0000-0000-0000-000000000004', 'dictionary', 'replace', 'synthetic', 'Synthetic', 0, 0);
INSERT INTO edit_op (dictation_id, stage, kind, from_text, to_text, word_delta, position) VALUES ('00000000-0000-0000-0000-000000000004', 'punctuation', 'insert', NULL, '.', 0, 1);
INSERT INTO edit_op (dictation_id, stage, kind, from_text, to_text, word_delta, position) VALUES ('00000000-0000-0000-0000-000000000013', 'filler', 'remove', 'um', NULL, -1, 0);
INSERT INTO edit_op (dictation_id, stage, kind, from_text, to_text, word_delta, position) VALUES ('00000000-0000-0000-0000-000000000014', 'dictionary', 'replace', 'omega', 'Omega', 0, 0);

INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at) VALUES ('00000000-0000-0000-0000-000000000004', 'remember', 'synthetic', 'Synthetic', 1, 1791720450.0);
INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at) VALUES ('00000000-0000-0000-0000-000000000004', 'remember', 'worled', 'world', 0, 1791720460.0);
INSERT INTO correction (dictation_id, kind, heard, corrected, accepted, created_at) VALUES ('00000000-0000-0000-0000-000000000013', 'remember', 'omga', 'omega', NULL, 1791721300.0);
