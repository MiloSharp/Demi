'use strict';

const fs = require('fs');
const path = require('path');
const { parseEntries } = require('./session-lifecycle');

function readJson(file, fallback) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } }
function storageUsesDatabase(root) { return String(readJson(path.join(root, 'config', 'storage.json'), {}).backend || 'files').toLowerCase() === 'postgresql'; }
function policy(root) { return { recentEntryCount:20, modelSizedRecentWindows:true, modelWindowEntries:{ under14B:8, '14BTo19B':14, '20BAndAbove':20, cloudOrUnknown:20 }, agentOverrides:{}, recentContextMaximumCharacters:30000, earlierSummaryMaximumCharacters:6000, retrievedOlderEntryCount:6, databaseSessionsUnlimited:true, ...readJson(path.join(root, 'config', 'session-context.json'), {}) }; }

function bounded(value, maximum) { const text = String(value || '').trim(); return text.length <= maximum ? text : `${text.slice(0, maximum).trimEnd()}\n[context shortened by Demi]`; }
function metadataSummary(root, sessionName) { return String(readJson(path.join(root, 'state', 'session-metadata.json'), { sessions:{} }).sessions?.[sessionName]?.summary || '').trim(); }

function resolveAgent(root, token) {
  const wanted = String(token || '').toLowerCase();
  const agents = readJson(path.join(root, 'config', 'agents.json'), { agents:[] }).agents || [];
  return agents.find(agent => [agent.name,agent.handle,...(agent.aliases || [])].some(value => String(value).toLowerCase() === wanted)) || null;
}
function inferredRecentCount(root, agentToken, settings = policy(root)) {
  const agent = resolveAgent(root, agentToken);
  const override = settings.agentOverrides?.[agent?.handle] ?? settings.agentOverrides?.[agent?.name];
  if (Number.isInteger(Number(override)) && Number(override) > 0) return Number(override);
  if (!settings.modelSizedRecentWindows || !agent) return Number(settings.recentEntryCount || 20);
  if (String(agent.kind).toLowerCase() !== 'ollama') return Number(settings.modelWindowEntries?.cloudOrUnknown || 20);
  const match = String(agent.model || '').match(/(?:^|[:_-])(\d+(?:\.\d+)?)b(?:$|[-_])/i);
  if (!match) return Number(settings.modelWindowEntries?.cloudOrUnknown || 20);
  const billions = Number(match[1]);
  if (billions < 14) return Number(settings.modelWindowEntries?.under14B || 8);
  if (billions < 20) return Number(settings.modelWindowEntries?.['14BTo19B'] || 14);
  return Number(settings.modelWindowEntries?.['20BAndAbove'] || 20);
}

function renderDatabaseContext(root, sessionFile, agentToken = '') {
  if (!storageUsesDatabase(root)) return '';
  const settings = policy(root);
  const text = fs.readFileSync(sessionFile, 'utf8');
  const entries = parseEntries(text);
  const recentCount = Math.max(1, inferredRecentCount(root, agentToken, settings));
  const split = Math.max(0, entries.length - recentCount);
  const recent = entries.slice(split);
  const summary = metadataSummary(root, path.basename(sessionFile, '.md')) || (split ? `Earlier discussion contains ${split} entries. Retrieve older entries from PostgreSQL when the active request requires their details.` : 'No earlier-session summary is needed yet.');
  const renderedRecent = recent.map(entry => `[${entry.id} - ${entry.author}]\n${entry.body}`).join('\n\n');
  return `DATABASE-BACKED SESSION CONTEXT\nThe complete transcript remains stored and searchable. Do not reread the complete Markdown transcript unless explicitly required.\n\nEARLIER DISCUSSION SUMMARY (entries before the recent window; summary may be supplemented by database retrieval)\n${bounded(summary, Number(settings.earlierSummaryMaximumCharacters || 6000))}\n\nRECENT CONTEXT (most recent ${recent.length} of ${entries.length} entries; earlier context is not discarded)\n${bounded(renderedRecent, Number(settings.recentContextMaximumCharacters || 30000))}\n\nSUMMARY CHECKPOINT\nRecent window begins at ${recent[0]?.id || 'the start of the session'}; ${split} earlier entries remain available for retrieval.`;
}

if (require.main === module && process.argv[2] === '--render') {
  const root = path.resolve(process.argv[3]);
  const file = path.resolve(process.argv[4]);
  process.stdout.write(renderDatabaseContext(root, file, process.argv[5] || ''));
}

module.exports = { storageUsesDatabase, policy, resolveAgent, inferredRecentCount, renderDatabaseContext };
