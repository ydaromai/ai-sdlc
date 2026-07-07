/**
 * Shared retry logic with exponential backoff for JIRA API calls.
 */

/** Maximum number of retry attempts */
export const MAX_RETRIES = 3;

/** Base delay in milliseconds for exponential backoff */
export const RETRY_BASE_DELAY_MS = 1000;

/**
 * Sleep for a given number of milliseconds.
 * @param {number} ms - Milliseconds to sleep
 * @returns {Promise<void>}
 */
export function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Retry a function with exponential backoff on 429 (rate limit) and 503 (service unavailable).
 * @param {Function} fn - Async function to retry
 * @param {number} [maxRetries=MAX_RETRIES] - Maximum number of attempts
 * @returns {Promise<*>} Result of the function call
 */
export async function retryWithBackoff(fn, maxRetries = MAX_RETRIES) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn();
    } catch (err) {
      const is429 = err.message && (err.message.includes('429') || err.message.includes('rate limit'));
      const is503 = err.message && err.message.includes('503');

      if ((is429 || is503) && i < maxRetries - 1) {
        const delay = Math.pow(2, i) * RETRY_BASE_DELAY_MS;
        console.log(`⏳ Rate limited, retrying in ${delay}ms...`);
        await sleep(delay);
      } else {
        throw err;
      }
    }
  }
}
