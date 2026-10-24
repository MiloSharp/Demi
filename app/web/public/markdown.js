(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.DemiMarkdown = api;
}(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, character => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[character]);
  }

  function inline(text) {
    let value = escapeHtml(text);
    const code = [];
    value = value.replace(/`([^`\n]+)`/g, (_, content) => {
      code.push(`<code>${content}</code>`);
      return `\u0000CODE${code.length - 1}\u0000`;
    });
    value = value.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    value = value.replace(/(^|[\s(])\*([^*\n]+)\*(?=$|[\s).,!?:;])/g, '$1<em>$2</em>');
    value = value.replace(/(^|[\s(])_([^_\n]+)_(?=$|[\s).,!?:;])/g, '$1<em>$2</em>');
    return value.replace(/\u0000CODE(\d+)\u0000/g, (_, index) => code[Number(index)]);
  }

  function renderMarkdown(source) {
    const lines = String(source || '').replace(/\r\n?/g, '\n').split('\n');
    const output = [];
    let paragraph = [];
    let list = null;
    const flushParagraph = () => {
      if (paragraph.length) output.push(`<p>${inline(paragraph.join('\n')).replace(/\n/g, '<br>')}</p>`);
      paragraph = [];
    };
    const flushList = () => {
      if (list) output.push(`<${list.type}>${list.items.map(item => `<li>${inline(item)}</li>`).join('')}</${list.type}>`);
      list = null;
    };
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      if (/^```/.test(line)) {
        flushParagraph(); flushList();
        const language = line.slice(3).trim();
        const codeLines = [];
        index++;
        while (index < lines.length && !/^```\s*$/.test(lines[index])) codeLines.push(lines[index++]);
        output.push(`<pre><code${language ? ` data-language="${escapeHtml(language)}"` : ''}>${escapeHtml(codeLines.join('\n'))}</code></pre>`);
      } else if (/^\s*>\s?/.test(line)) {
        flushParagraph(); flushList();
        const quote = [];
        while (index < lines.length && /^\s*>\s?/.test(lines[index])) quote.push(lines[index++].replace(/^\s*>\s?/, ''));
        index--;
        output.push(`<blockquote>${inline(quote.join('\n')).replace(/\n/g, '<br>')}</blockquote>`);
      } else {
        const bullet = line.match(/^\s*[-+*]\s+(.+)$/);
        const numbered = line.match(/^\s*\d+[.)]\s+(.+)$/);
        if (bullet || numbered) {
          flushParagraph();
          const type = bullet ? 'ul' : 'ol';
          if (list && list.type !== type) flushList();
          if (!list) list = { type, items: [] };
          list.items.push((bullet || numbered)[1]);
        } else if (!line.trim()) {
          flushParagraph(); flushList();
        } else {
          flushList();
          paragraph.push(line);
        }
      }
    }
    flushParagraph(); flushList();
    return output.join('');
  }

  return { escapeHtml, renderMarkdown };
}));
