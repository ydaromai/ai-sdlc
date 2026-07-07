/**
 * Shared parsing utilities for JIRA import scripts.
 */

/**
 * Parse a time estimate string into JIRA time tracking format.
 * Handles formats like "8 hours", "2 days", "30 minutes", "~4 hours", "2-3 days".
 * For ranges, takes the lower bound.
 *
 * @param {string|null|undefined} text - The time estimate text
 * @returns {string|null} Parsed estimate (e.g., "8h", "2d", "30m") or null
 */
export function parseTimeEstimate(text) {
  if (!text) return null;

  let estimate = text;

  // Remove approximation symbols and ranges (take lower bound)
  estimate = estimate.replace(/^~/, '').replace(/(\d+)-\d+/, '$1');

  const parsed = estimate
    .match(/(\d+)\s*(hour|week|day|minute)/i)?.[0]
    ?.replace(/\s*(hours?|h)\b/i, 'h')
    .replace(/\s*(weeks?|w)\b/i, 'w')
    .replace(/\s*(days?|d)\b/i, 'd')
    .replace(/\s*(minutes?|m)\b/i, 'm')
    .replace(/\s+/g, '') || null;

  return parsed;
}
