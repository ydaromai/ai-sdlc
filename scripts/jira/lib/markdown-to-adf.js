/**
 * Markdown to Atlassian Document Format (ADF) Converter
 * 
 * Converts Markdown text to ADF JSON for proper rendering in JIRA.
 * 
 * Supported Markdown:
 * - Headers (# → h1, ## → h2, ### → h3)
 * - Bold (**text**), Italic (*text*), Inline code (`code`)
 * - Lists (numbered and bulleted, including nested)
 * - Code blocks with language (```js)
 * - Links ([text](url))
 * - Checkboxes (- [ ] and - [x])
 * 
 * Usage:
 *   import { markdownToADF } from './lib/markdown-to-adf.js';
 *   const adf = markdownToADF('**Bold** and *italic* text');
 */

/**
 * Convert Markdown string to ADF JSON structure
 * @param {string} markdown - Markdown text
 * @returns {object} ADF document object
 */
export function markdownToADF(markdown) {
  if (!markdown || markdown.trim() === '') {
    return createEmptyDoc();
  }

  const parser = new MarkdownParser(markdown);
  return parser.parse();
}

class MarkdownParser {
  constructor(markdown) {
    this.markdown = markdown;
    this.lines = markdown.split('\n');
    this.content = [];
    this.currentLine = 0;
  }

  parse() {
    while (this.currentLine < this.lines.length) {
      const line = this.lines[this.currentLine];
      
      // Code block
      if (line.startsWith('```')) {
        this.parseCodeBlock();
        continue;
      }

      // Heading
      if (line.match(/^#{1,6} /)) {
        this.parseHeading(line);
        this.currentLine++;
        continue;
      }

      // Ordered list
      if (line.match(/^\d+\. /)) {
        this.parseOrderedList();
        continue;
      }

      // Bullet list or checkbox
      if (line.match(/^[-*] /)) {
        this.parseBulletList();
        continue;
      }

      // Horizontal rule
      if (line.match(/^---+$/)) {
        this.content.push(createRule());
        this.currentLine++;
        continue;
      }

      // Empty line
      if (line.trim() === '') {
        this.currentLine++;
        continue;
      }

      // Paragraph
      this.parseParagraph();
    }

    return {
      type: 'doc',
      version: 1,
      content: this.content.length > 0 ? this.content : [createEmptyParagraph()],
    };
  }

  parseHeading(line) {
    const match = line.match(/^(#{1,6}) (.+)/);
    if (!match) return;

    const level = match[1].length;
    const text = match[2];
    
    this.content.push({
      type: 'heading',
      attrs: { level: Math.min(level, 6) },
      content: this.parseInlineText(text),
    });
  }

  parseCodeBlock() {
    const startLine = this.currentLine;
    const firstLine = this.lines[startLine];
    const language = firstLine.slice(3).trim() || null;
    
    this.currentLine++;
    const codeLines = [];

    while (this.currentLine < this.lines.length) {
      const line = this.lines[this.currentLine];
      if (line.startsWith('```')) {
        this.currentLine++;
        break;
      }
      codeLines.push(line);
      this.currentLine++;
    }

    this.content.push({
      type: 'codeBlock',
      attrs: language ? { language } : {},
      content: [
        {
          type: 'text',
          text: codeLines.join('\n'),
        },
      ],
    });
  }

  parseOrderedList() {
    const items = [];
    
    while (this.currentLine < this.lines.length) {
      const line = this.lines[this.currentLine];
      
      if (!line.match(/^\d+\. /)) {
        break;
      }

      const text = line.replace(/^\d+\. /, '');
      items.push({
        type: 'listItem',
        content: [
          {
            type: 'paragraph',
            content: this.parseInlineText(text),
          },
        ],
      });
      
      this.currentLine++;
    }

    if (items.length > 0) {
      this.content.push({
        type: 'orderedList',
        content: items,
      });
    }
  }

  parseBulletList() {
    const items = [];

    while (this.currentLine < this.lines.length) {
      const line = this.lines[this.currentLine];

      // Check for checkbox — render as regular bullet with status prefix
      // (taskList/taskItem ADF nodes are not supported in all JIRA project types)
      const checkboxMatch = line.match(/^[-*] \[([ x])\] (.+)/);
      if (checkboxMatch) {
        const checked = checkboxMatch[1] === 'x';
        const text = checkboxMatch[2];
        const statusPrefix = checked ? '\u2611 ' : '\u2610 ';

        items.push({
          type: 'listItem',
          content: [
            {
              type: 'paragraph',
              content: this.parseInlineText(statusPrefix + text),
            },
          ],
        });

        this.currentLine++;
        continue;
      }

      // Regular bullet
      if (!line.match(/^[-*] /)) {
        break;
      }

      const text = line.replace(/^[-*] /, '');
      items.push({
        type: 'listItem',
        content: [
          {
            type: 'paragraph',
            content: this.parseInlineText(text),
          },
        ],
      });

      this.currentLine++;
    }

    if (items.length > 0) {
      this.content.push({
        type: 'bulletList',
        content: items,
      });
    }
  }

  parseParagraph() {
    const paragraphLines = [];
    
    while (this.currentLine < this.lines.length) {
      const line = this.lines[this.currentLine];
      
      // Stop at special line types
      if (
        line.startsWith('#') ||
        line.startsWith('```') ||
        line.match(/^\d+\. /) ||
        line.match(/^[-*] /) ||
        line.match(/^---+$/) ||
        line.trim() === ''
      ) {
        break;
      }

      paragraphLines.push(line);
      this.currentLine++;
    }

    if (paragraphLines.length > 0) {
      const text = paragraphLines.join(' ');
      this.content.push({
        type: 'paragraph',
        content: this.parseInlineText(text),
      });
    }
  }

  parseInlineText(text) {
    const tokens = [];
    let currentPos = 0;

    // Regex patterns for inline elements
    const patterns = [
      { type: 'link', regex: /\[([^\]]+)\]\(([^)]+)\)/g },
      { type: 'bold', regex: /\*\*([^*]+)\*\*/g },
      { type: 'italic', regex: /\*([^*]+)\*/g },
      { type: 'code', regex: /`([^`]+)`/g },
    ];

    // Find all matches
    const matches = [];
    for (const { type, regex } of patterns) {
      let match;
      while ((match = regex.exec(text)) !== null) {
        matches.push({
          type,
          start: match.index,
          end: regex.lastIndex,
          match: match[0],
          content: match[1],
          url: match[2], // for links
        });
      }
    }

    // Sort matches by position
    matches.sort((a, b) => a.start - b.start);

    // Build token stream, handling overlaps
    let lastEnd = 0;
    for (const m of matches) {
      // Skip overlapping matches
      if (m.start < lastEnd) continue;

      // Add plain text before this match
      if (m.start > lastEnd) {
        const plainText = text.slice(lastEnd, m.start);
        if (plainText) {
          tokens.push({ type: 'text', text: plainText });
        }
      }

      // Add formatted token
      if (m.type === 'link') {
        tokens.push({
          type: 'text',
          text: m.content,
          marks: [
            {
              type: 'link',
              attrs: { href: m.url },
            },
          ],
        });
      } else if (m.type === 'bold') {
        tokens.push({
          type: 'text',
          text: m.content,
          marks: [{ type: 'strong' }],
        });
      } else if (m.type === 'italic') {
        tokens.push({
          type: 'text',
          text: m.content,
          marks: [{ type: 'em' }],
        });
      } else if (m.type === 'code') {
        tokens.push({
          type: 'text',
          text: m.content,
          marks: [{ type: 'code' }],
        });
      }

      lastEnd = m.end;
    }

    // Add remaining plain text
    if (lastEnd < text.length) {
      const plainText = text.slice(lastEnd);
      if (plainText) {
        tokens.push({ type: 'text', text: plainText });
      }
    }

    return tokens.length > 0 ? tokens : [{ type: 'text', text }];
  }
}

// Helper functions
function createEmptyDoc() {
  return {
    type: 'doc',
    version: 1,
    content: [createEmptyParagraph()],
  };
}

function createEmptyParagraph() {
  return {
    type: 'paragraph',
    content: [
      {
        type: 'text',
        text: 'No description provided',
      },
    ],
  };
}

function createRule() {
  return {
    type: 'rule',
  };
}

/**
 * Create audit trail header for JIRA issues
 * @param {string} filePath - Path to dev plan file
 * @param {string} batchId - Batch ID for this import
 * @returns {Array} ADF content nodes for audit trail
 */
export function createAuditTrailHeader(filePath, batchId) {
  const now = new Date().toISOString();
  
  return [
    {
      type: 'rule',
    },
    {
      type: 'paragraph',
      content: [
        {
          type: 'text',
          text: 'Created by ',
        },
        {
          type: 'text',
          text: 'dp2j',
          marks: [{ type: 'code' }],
        },
        {
          type: 'text',
          text: ' from: ',
        },
        {
          type: 'text',
          text: filePath,
          marks: [{ type: 'code' }],
        },
      ],
    },
    {
      type: 'paragraph',
      content: [
        {
          type: 'text',
          text: 'Batch ID: ',
        },
        {
          type: 'text',
          text: batchId,
          marks: [{ type: 'code' }],
        },
      ],
    },
    {
      type: 'paragraph',
      content: [
        {
          type: 'text',
          text: 'Import date: ',
        },
        {
          type: 'text',
          text: now,
          marks: [{ type: 'code' }],
        },
      ],
    },
    {
      type: 'rule',
    },
  ];
}

/**
 * Prepend audit trail to existing ADF content
 * @param {object} adfDoc - Existing ADF document
 * @param {string} filePath - Path to dev plan file
 * @param {string} batchId - Batch ID
 * @returns {object} Modified ADF document with audit trail
 */
export function prependAuditTrail(adfDoc, filePath, batchId) {
  const auditTrail = createAuditTrailHeader(filePath, batchId);
  
  return {
    ...adfDoc,
    content: [...auditTrail, ...adfDoc.content],
  };
}
