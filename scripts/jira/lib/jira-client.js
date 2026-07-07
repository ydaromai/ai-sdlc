/**
 * Shared JIRA API client with retry logic and credential redaction.
 * Consolidated from jira-import.js and cleanup-import.js implementations.
 */

import { retryWithBackoff } from './retry.js';
import { redactAuth } from './redact.js';

/**
 * JIRA REST API client.
 * Auth credentials are stored as a private field (#auth) to prevent
 * accidental leakage through JSON.stringify() or console.log().
 */
export class JiraClient {
  #auth;

  /**
   * @param {Object} config
   * @param {string} config.apiUrl - JIRA instance URL (e.g., https://yourcompany.atlassian.net)
   * @param {string} config.email - JIRA user email
   * @param {string} config.apiToken - JIRA API token
   */
  constructor(config) {
    this.config = config;
    this.baseUrl = `${config.apiUrl}/rest/api/3`;
    this.#auth = Buffer.from(`${config.email}:${config.apiToken}`).toString('base64');
    this.userCache = new Map();
  }

  /**
   * Make an authenticated JIRA API request with retry on 429/503.
   * Error messages are automatically redacted to remove credentials.
   */
  async makeRequest(method, endpoint, body = null) {
    return await retryWithBackoff(async () => {
      const url = `${this.baseUrl}${endpoint}`;
      const options = {
        method,
        headers: {
          'Authorization': `Basic ${this.#auth}`,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      };

      if (body) {
        options.body = JSON.stringify(body);
      }

      const response = await fetch(url, options);

      if (!response.ok) {
        let errorText = await response.text();
        errorText = redactAuth(errorText, this.#auth);
        throw new Error(`JIRA API error (${response.status}): ${errorText}`);
      }

      // Handle 204 No Content (e.g., successful DELETE)
      if (response.status === 204) {
        return null;
      }

      return await response.json();
    });
  }

  async createIssue(issueData) {
    return await this.makeRequest('POST', '/issue', issueData);
  }

  async getIssue(issueKey) {
    return await this.makeRequest('GET', `/issue/${issueKey}`);
  }

  async deleteIssue(issueKey) {
    await this.makeRequest('DELETE', `/issue/${issueKey}`);
  }

  async getTransitions(issueKey) {
    const result = await this.makeRequest('GET', `/issue/${issueKey}/transitions`);
    return result.transitions || [];
  }

  async transitionIssue(issueKey, transitionId) {
    await this.makeRequest('POST', `/issue/${issueKey}/transitions`, {
      transition: { id: transitionId },
    });
  }

  async addComment(issueKey, commentBody) {
    return await this.makeRequest('POST', `/issue/${issueKey}/comment`, commentBody);
  }

  async searchIssuesByLabel(label) {
    const jql = `labels = "${label}"`;
    const result = await this.makeRequest('GET', `/search?jql=${encodeURIComponent(jql)}&maxResults=1000`);
    return result.issues || [];
  }

  /**
   * Look up a JIRA user by email. Results are cached.
   */
  async getUserByEmail(email) {
    if (this.userCache.has(email)) {
      return this.userCache.get(email);
    }

    try {
      const result = await this.makeRequest('GET', `/user/search?query=${encodeURIComponent(email)}`);

      if (result && result.length > 0) {
        const accountId = result[0].accountId;
        this.userCache.set(email, accountId);
        return accountId;
      }

      console.log(`⚠️  User not found for email: ${email}`);
      return null;
    } catch (error) {
      console.log(`⚠️  Failed to lookup user ${email}: ${error.message}`);
      return null;
    }
  }

  /**
   * Get the auth string for redaction purposes (e.g., in top-level catch blocks).
   * Returns the raw Base64 auth string.
   */
  getAuthForRedaction() {
    return this.#auth;
  }
}
