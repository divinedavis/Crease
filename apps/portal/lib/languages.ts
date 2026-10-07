/**
 * Languages a shop can read its customer notes in.
 *
 * The customer's iPhone translates the note on the device with Apple's
 * Translation framework before sending it, keeping the original underneath,
 * so this list is limited to languages that framework supports. The value is
 * a BCP-47 code stored in cleaners.notes_language (checked by migration 0049).
 */
export const NOTE_LANGUAGES: ReadonlyArray<{ code: string; label: string }> = [
  { code: 'en', label: 'English' },
  { code: 'es', label: 'Spanish (Español)' },
  { code: 'zh-Hans', label: 'Chinese, Simplified (简体中文)' },
  { code: 'zh-Hant', label: 'Chinese, Traditional (繁體中文)' },
  { code: 'ko', label: 'Korean (한국어)' },
  { code: 'ru', label: 'Russian (Русский)' },
  { code: 'uk', label: 'Ukrainian (Українська)' },
  { code: 'ar', label: 'Arabic (العربية)' },
  { code: 'fr', label: 'French (Français)' },
  { code: 'pt', label: 'Portuguese (Português)' },
  { code: 'it', label: 'Italian (Italiano)' },
  { code: 'pl', label: 'Polish (Polski)' },
  { code: 'tr', label: 'Turkish (Türkçe)' },
  { code: 'vi', label: 'Vietnamese (Tiếng Việt)' },
  { code: 'hi', label: 'Hindi (हिन्दी)' },
  { code: 'ja', label: 'Japanese (日本語)' },
];

/** The stored code for a submitted value, or null when it is not on the list. */
export function noteLanguage(value: unknown): string | null {
  const v = String(value ?? '').trim();
  return NOTE_LANGUAGES.some((l) => l.code === v) ? v : null;
}
