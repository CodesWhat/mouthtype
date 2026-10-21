import { DAILY_WRITING_MINUTES, MAX_WPM, MIN_ELAPSED_MS } from "./wpm-constants.js";

export function countWords(text) {
  const words = text.trim().split(/\s+/);
  return words[0] === "" ? 0 : words.length;
}

// Standard typing WPM: five characters make a word.
export function grossWpm(characters, elapsedMs) {
  if (elapsedMs <= 0) return 0;
  return characters / 5 / (elapsedMs / 60000);
}

// Net WPM is gross scaled by accuracy (1 minus misses per keystroke).
export function accuracy(keystrokes, misses) {
  if (keystrokes <= 0) return 1;
  return Math.max(0, 1 - misses / keystrokes);
}

export function netWpm(characters, elapsedMs, keystrokes, misses) {
  return grossWpm(characters, elapsedMs) * accuracy(keystrokes, misses);
}

export function speakingWpm(words, elapsedMs) {
  if (elapsedMs <= 0) return 0;
  return words / (elapsedMs / 60000);
}

// Under one second or over 400 WPM is not a real attempt.
export function isPlausible(wpm, elapsedMs) {
  return elapsedMs >= MIN_ELAPSED_MS && Number.isFinite(wpm) && wpm <= MAX_WPM;
}

export function speedup(speaking, typing) {
  return typing > 0 ? speaking / typing : 0;
}

// Minutes of a day's writing that speaking gives back.
export function minutesSaved(speaking, typing, dailyMinutes = DAILY_WRITING_MINUTES) {
  if (speaking <= 0 || typing <= 0) return 0;
  return Math.max(0, dailyMinutes * (1 - typing / speaking));
}
