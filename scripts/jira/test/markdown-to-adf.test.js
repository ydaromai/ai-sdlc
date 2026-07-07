import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { markdownToADF, prependAuditTrail } from '../lib/markdown-to-adf.js';

describe('markdownToADF', () => {
  describe('empty input', () => {
    it('returns empty doc for null input', () => {
      const result = markdownToADF(null);
      assert.equal(result.type, 'doc');
      assert.equal(result.version, 1);
      assert.equal(result.content.length, 1);
      assert.equal(result.content[0].type, 'paragraph');
    });

    it('returns empty doc for empty string', () => {
      const result = markdownToADF('');
      assert.equal(result.type, 'doc');
      assert.equal(result.content[0].content[0].text, 'No description provided');
    });

    it('returns empty doc for whitespace-only string', () => {
      const result = markdownToADF('   \n  \n  ');
      assert.equal(result.type, 'doc');
    });
  });

  describe('headings', () => {
    it('converts h1 heading', () => {
      const result = markdownToADF('# Title');
      const heading = result.content[0];
      assert.equal(heading.type, 'heading');
      assert.equal(heading.attrs.level, 1);
      assert.equal(heading.content[0].text, 'Title');
    });

    it('converts h2 heading', () => {
      const result = markdownToADF('## Subtitle');
      assert.equal(result.content[0].attrs.level, 2);
    });

    it('converts h3 heading', () => {
      const result = markdownToADF('### Sub-subtitle');
      assert.equal(result.content[0].attrs.level, 3);
    });
  });

  describe('inline formatting', () => {
    it('converts bold text', () => {
      const result = markdownToADF('**bold text**');
      const tokens = result.content[0].content;
      const boldToken = tokens.find(t => t.marks && t.marks.some(m => m.type === 'strong'));
      assert.ok(boldToken, 'Should have a bold token');
      assert.equal(boldToken.text, 'bold text');
    });

    it('converts italic text', () => {
      const result = markdownToADF('*italic text*');
      const tokens = result.content[0].content;
      const italicToken = tokens.find(t => t.marks && t.marks.some(m => m.type === 'em'));
      assert.ok(italicToken, 'Should have an italic token');
      assert.equal(italicToken.text, 'italic text');
    });

    it('converts inline code', () => {
      const result = markdownToADF('use `npm test` command');
      const tokens = result.content[0].content;
      const codeToken = tokens.find(t => t.marks && t.marks.some(m => m.type === 'code'));
      assert.ok(codeToken, 'Should have a code token');
      assert.equal(codeToken.text, 'npm test');
    });

    it('converts links', () => {
      const result = markdownToADF('[click here](https://example.com)');
      const tokens = result.content[0].content;
      const linkToken = tokens.find(t => t.marks && t.marks.some(m => m.type === 'link'));
      assert.ok(linkToken, 'Should have a link token');
      assert.equal(linkToken.text, 'click here');
      assert.equal(linkToken.marks[0].attrs.href, 'https://example.com');
    });
  });

  describe('lists', () => {
    it('converts ordered list', () => {
      const result = markdownToADF('1. First\n2. Second\n3. Third');
      const list = result.content[0];
      assert.equal(list.type, 'orderedList');
      assert.equal(list.content.length, 3);
      assert.equal(list.content[0].type, 'listItem');
    });

    it('converts bullet list', () => {
      const result = markdownToADF('- Alpha\n- Beta\n- Gamma');
      const list = result.content[0];
      assert.equal(list.type, 'bulletList');
      assert.equal(list.content.length, 3);
    });

    it('converts checkboxes to a bullet list with status-prefixed items', () => {
      // taskList/taskItem ADF nodes are not supported in all JIRA project types,
      // so the converter renders checkboxes as a bulletList with a ☐/☑ status prefix.
      const result = markdownToADF('- [ ] Todo\n- [x] Done');
      const list = result.content[0];
      const itemText = (li) => li.content[0].content.map((n) => n.text || '').join('');
      assert.equal(list.type, 'bulletList');
      assert.equal(list.content.length, 2);
      assert.equal(itemText(list.content[0]), '☐ Todo');
      assert.equal(itemText(list.content[1]), '☑ Done');
    });
  });

  describe('code blocks', () => {
    it('converts code block with language', () => {
      const result = markdownToADF('```javascript\nconst x = 1;\n```');
      const block = result.content[0];
      assert.equal(block.type, 'codeBlock');
      assert.equal(block.attrs.language, 'javascript');
      assert.equal(block.content[0].text, 'const x = 1;');
    });

    it('converts code block without language', () => {
      const result = markdownToADF('```\nplain code\n```');
      const block = result.content[0];
      assert.equal(block.type, 'codeBlock');
      assert.deepEqual(block.attrs, {});
    });
  });

  describe('horizontal rule', () => {
    it('converts --- to rule', () => {
      const result = markdownToADF('---');
      assert.equal(result.content[0].type, 'rule');
    });
  });

  describe('paragraphs', () => {
    it('converts plain text to paragraph', () => {
      const result = markdownToADF('Just some text');
      assert.equal(result.content[0].type, 'paragraph');
      assert.equal(result.content[0].content[0].text, 'Just some text');
    });

    it('joins continuation lines into one paragraph', () => {
      const result = markdownToADF('Line one\nLine two');
      assert.equal(result.content[0].type, 'paragraph');
      assert.equal(result.content[0].content[0].text, 'Line one Line two');
    });
  });
});

describe('prependAuditTrail', () => {
  it('prepends audit trail to ADF document', () => {
    const doc = markdownToADF('Hello');
    const result = prependAuditTrail(doc, 'test/file.md', 'batch-123');
    assert.equal(result.type, 'doc');
    // Audit trail adds 5 nodes before the original content
    assert.ok(result.content.length > doc.content.length);
    // First node should be a rule
    assert.equal(result.content[0].type, 'rule');
  });
});
