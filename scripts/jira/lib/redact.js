/**
 * Credential redaction utility.
 * Uses safe string replacement (split/join) instead of RegExp
 * to avoid issues with Base64 metacharacters (+, /, =).
 */

/**
 * Redact an auth string from text, including its URL-encoded form.
 * @param {string} text - The text to redact from
 * @param {string} authString - The credential string to remove
 * @returns {string} Text with all occurrences of authString replaced with [REDACTED]
 */
export function redactAuth(text, authString) {
  if (!authString) return text;
  if (typeof text !== 'string') return text;

  // First pass: redact raw auth string
  let result = text.split(authString).join('[REDACTED]');

  // Second pass: redact URL-encoded form (handles credential reflection in redirect URLs / error bodies)
  const encoded = encodeURIComponent(authString);
  if (encoded !== authString) {
    result = result.split(encoded).join('[REDACTED]');
  }

  return result;
}
