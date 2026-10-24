'use strict';

(function expose(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.DemiConversation = api;
})(typeof globalThis === 'object' ? globalThis : this, () => {
  const RESPONSE_TYPES = new Set(['RESPONSE', 'DIRECT RESPONSE', 'ACKNOWLEDGMENT', 'RECOVERED RESPONSE']);

  function stableDomId(entryId) {
    return `entry-${String(entryId || '').replace(/[^A-Za-z0-9_-]/g, '-')}`;
  }

  function plainText(markdown) {
    return String(markdown || '')
      .replace(/```[\s\S]*?```/g, ' ')
      .replace(/`([^`]*)`/g, '$1')
      .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
      .replace(/<[^>]+>/g, ' ')
      .replace(/^\s{0,3}(?:#{1,6}|>|[-+*]|\d+[.)])\s+/gm, '')
      .replace(/[*_~]/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function summarizeStatement(markdown, maxLength = 100) {
    const text = plainText(markdown);
    if (!text) return 'Untitled statement';
    const sentence = text.match(/^.*?(?:[.!?](?=\s|$)|$)/)?.[0] || text;
    const candidate = sentence.length >= 32 ? sentence : text;
    if (candidate.length <= maxLength) return candidate;
    const slice = candidate.slice(0, maxLength + 1);
    const boundary = slice.lastIndexOf(' ');
    return `${slice.slice(0, boundary >= Math.floor(maxLength * .65) ? boundary : maxLength).trim()}…`;
  }

  function isAdministrativeMiloEntry(entry) {
    if (!entry?.author || entry.author === 'System') return false;
    if (!['CONTINUE', 'STOP'].includes(String(entry.type || '').toUpperCase())) return false;
    const text = plainText(entry.body);
    if (!text) return true;
    const boilerplate = entry.type === 'CONTINUE'
      ? /^continue the current discussion for \d+ additional agent responses?[.!]*$/i
      : /^stop the current agent discussion and wait for (?:the )?human[.!]*$/i;
    return boilerplate.test(text);
  }

  function isSubstantiveMiloEntry(entry) {
    return Boolean(entry?.author) && entry.author !== 'System' && !RESPONSE_TYPES.has(String(entry.type || '').toUpperCase()) && String(entry.type || '').toUpperCase() !== 'GENERATED IMAGE' && Boolean(plainText(entry.body)) && !isAdministrativeMiloEntry(entry);
  }

  function isAgentResponse(entry) {
    const generatedImage = String(entry?.type || '').toUpperCase() === 'GENERATED IMAGE' &&
      (entry.attachments || []).some(attachment => attachment?.image);
    return entry?.author !== 'System' && Boolean(entry?.author) &&
      (RESPONSE_TYPES.has(entry?.type) || generatedImage) &&
      (Boolean(plainText(entry.body)) || generatedImage) &&
      !/required [`']?demi respond|could not append|workspace denied creation|no project files were modified/i.test(entry.body);
  }

  function groupConversation(entries) {
    const groups = [];
    const byId = new Map();
    const substantive = [];
    for (const entry of entries || []) {
      if (isSubstantiveMiloEntry(entry)) {
        const group = { statement: entry, summary: summarizeStatement(entry.body), responses: [] };
        groups.push(group);
        byId.set(entry.id, group);
        substantive.push(group);
        continue;
      }
      if (!isAgentResponse(entry)) continue;
      const respondingTo = entry.metadata?.['Responding to'] || entry.metadata?.['Requested by'];
      let group = respondingTo ? byId.get(respondingTo) : null;
      if (!group) {
        const round = entry.metadata?.Round;
        group = [...substantive].reverse().find(candidate =>
          !round || candidate.statement.metadata?.Round === round) || null;
      }
      if (group) group.responses.push(entry);
    }
    return groups;
  }

  function elapsedLabel(timestamp, now = Date.now()) {
    const then = new Date(timestamp).getTime();
    if (!Number.isFinite(then)) return '';
    const seconds = Math.max(0, Math.floor((Number(now) - then) / 1000));
    if (seconds >= 86400) return `${Math.floor(seconds / 86400)}d ${Math.floor((seconds % 86400) / 3600)}h`;
    if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
    if (seconds >= 60) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
    return `${seconds}s`;
  }

  function sessionFiles(entries) {
    const files = new Map();
    for (const entry of entries || []) {
      if (String(entry?.type || '').toUpperCase() === 'GENERATED IMAGE') {
        for (const attachment of entry.attachments || []) {
          const imagePath = String(attachment?.path || '').trim().replace(/\\/g, '/');
          if (!/^inbox\/attachments\/session-\d{3}\/[\p{L}\p{N}._-]+\.(?:png|jpe?g|webp|gif)$/iu.test(imagePath)) continue;
          const parts = imagePath.split('/');
          files.set(imagePath.toLowerCase(), {
            destination: imagePath,
            name: String(attachment.name || parts.at(-1)),
            timestamp: entry.timestamp || null,
            entryId: entry.id,
            format: imagePath.split('.').at(-1).toUpperCase(),
            url: attachment.url || `/api/attachment?path=${encodeURIComponent(imagePath)}`,
            generatedImage: true
          });
        }
      }
      const destination = String(entry?.metadata?.Destination || '').trim().replace(/\\/g, '/');
      if (!destination || destination.toLowerCase() === 'preview only') continue;
      if (destination.startsWith('/') || destination.includes('..') || destination.includes(':')) continue;
      if (!/\.(?:md|txt|docx|epub)$/i.test(destination)) continue;
      const parts = destination.split('/');
      files.set(destination.toLowerCase(), {
        destination,
        name: parts.at(-1),
        timestamp: entry.timestamp || null,
        entryId: entry.id,
        format: destination.split('.').at(-1).toUpperCase()
      });
    }
    return [...files.values()];
  }

  function sessionActions(session) {
    const actions = ['Open', 'Rename'];
    if (session?.capacityMode === 'database') {
      actions.push(session?.current ? 'Extend' : 'Activate');
      return actions;
    }
    if (Number(session?.percent) < 90 && !session?.current) actions.push('Activate');
    if (session?.current || Number(session?.percent) >= 90) actions.push('Extend');
    return actions;
  }

  return {
    stableDomId, plainText, summarizeStatement, isAdministrativeMiloEntry,
    isSubstantiveMiloEntry, isAgentResponse, groupConversation, elapsedLabel, sessionFiles, sessionActions
  };
});
