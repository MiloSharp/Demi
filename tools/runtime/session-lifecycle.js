'use strict';

const fs = require('fs');
const path = require('path');
const { withSessionLock, writeJsonAtomic, addEntry } = require('./session-runtime');

const MAX_SESSION_BYTES = 1024 * 1024;
const ACTIVATION_LIMIT = MAX_SESSION_BYTES * 0.9;
function databaseSessionsUnlimited(root) {
  const storage = readJson(path.join(root, 'config', 'storage.json'), {});
  const policy = readJson(path.join(root, 'config', 'session-context.json'), {});
  return String(storage.backend || 'files').toLowerCase() === 'postgresql' && policy.databaseSessionsUnlimited !== false;
}

function readJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (fallback !== null && error.code === 'ENOENT') return fallback; throw error; }
}

function normalizeSession(value) {
  const match = String(value || '').match(/(?:^|[\\/])?session-(\d{3})(?:\.md)?$/i);
  if (!match) throw new Error('Session must be named session-NNN.');
  return { number: Number(match[1]), name: `session-${match[1]}`, relative: path.join('sessions', `session-${match[1]}.md`) };
}

function sessionPath(root, relative) {
  const resolved = path.resolve(root, String(relative).replace(/[\\/]/g, path.sep));
  if (!resolved.startsWith(`${path.resolve(root)}${path.sep}`)) throw new Error('Session path resolves outside the project.');
  return resolved;
}

function loadMetadata(root) {
  return readJson(path.join(root, 'state', 'session-metadata.json'), { schemaVersion: 1, sessions: {} });
}

function focusFor(root, name) { return loadMetadata(root).sessions?.[name]?.focus || null; }

function refreshMetadata(root, file) {
  try {
    const { generateSessionSummary, generateSessionTitle } = require('../web/server');
    const metadataFile = path.join(root, 'state', 'session-metadata.json');
    const metadata = loadMetadata(root);
    const key = path.basename(file, '.md');
    const existing = metadata.sessions?.[key] || {};
    const stat = fs.statSync(file);
    const transcript = fs.readFileSync(file, 'utf8');
    const updated = { ...existing, summary: generateSessionSummary(transcript), summaryVersion: 3,
      summaryUpdatedAt: new Date().toISOString(), sourceBytes: stat.size, sourceMtimeMs: stat.mtimeMs };
    if (!existing.label) { updated.generatedTitle = generateSessionTitle(transcript); updated.titleVersion = 2; }
    if (!metadata.sessions) metadata.sessions = {};
    metadata.sessions[key] = updated;
    writeJsonAtomic(metadataFile, metadata);
    return updated;
  } catch (error) {
    return { warning: `Session deactivated, but its card metadata could not be refreshed: ${error.message}. The previous summary was preserved.` };
  }
}

function parseEntries(text) {
  return [...String(text).matchAll(/^## (S\d{3}-[A-Z]\d{4}) - ([^\r\n]+)\r?\n([\s\S]*?)(?=^## S\d{3}-[A-Z]\d{4} - |(?![\s\S]))/gm)].map(match => {
    const split = match[3].search(/\r?\n\r?\n/);
    const header = split >= 0 ? match[3].slice(0, split) : match[3];
    const body = split >= 0 ? match[3].slice(split).trim() : '';
    const timestamp = header.match(/^Timestamp:\s*(.+)$/mi)?.[1]?.trim() || null;
    return { id: match[1], author: match[2].trim(), timestamp, body };
  });
}

function nextSessionNumber(root) {
  const numbers = fs.readdirSync(path.join(root, 'sessions')).map(name => name.match(/^session-(\d+)\.md$/i)?.[1]).filter(Boolean).map(Number);
  return numbers.length ? Math.max(...numbers) + 1 : 1;
}

function handoffFor(root, sourceFile) {
  const name = path.basename(sourceFile, '.md');
  const metadata = loadMetadata(root).sessions?.[name] || {};
  const entries = parseEntries(fs.readFileSync(sourceFile, 'utf8')).slice(-14);
  const parts = [`Linked continuation of ${path.basename(sourceFile)}. The complete predecessor is available at sessions/archive/${path.basename(sourceFile)} and may be consulted when details beyond this handoff are needed.`];
  if (metadata.summary) parts.push(`FINAL SESSION SUMMARY\n${metadata.summary}`);
  if (entries.length) parts.push(`RECENT CONTEXT\n${entries.map(entry => `[${entry.id} · ${entry.author}]\n${entry.body.slice(0, 1600)}${entry.body.length > 1600 ? ' ...' : ''}`).join('\n\n')}`);
  return parts.join('\n\n').slice(0, 24000);
}

function dispatcherActive(root) {
  const lock = path.join(root, 'state', 'dispatch', 'dispatcher.lock');
  if (!fs.existsSync(lock)) return false;
  const pid = Number(fs.readFileSync(lock, 'utf8').trim().split(/\s+/)[0]);
  try { process.kill(pid, 0); return true; }
  catch { try { fs.unlinkSync(lock); } catch {} return false; }
}

function openContinuation(root, sourceToken) {
  return withSessionLock(root, () => {
    const stateFile = path.join(root, 'state', 'collaboration.json');
    const state = readJson(stateFile);
    if (dispatcherActive(root)) throw new Error('Cannot open a new session while an agent dispatch or run is active. No work was cancelled.');
    if (state.directTurn?.active) throw new Error(`Cannot open a new session while the direct ${state.directTurn.agent} turn is active. No work was cancelled.`);
    const extended = Boolean(sourceToken);
    const source = extended ? normalizeSession(sourceToken) : normalizeSession(state.currentSession);
    const sourceFile = sessionPath(root, source.relative);
    if (!fs.existsSync(sourceFile)) throw new Error(`${source.name} does not exist.`);
    const refreshed = refreshMetadata(root, sourceFile);
    const focus = extended ? (focusFor(root, source.name) || state.focus || null) : null;
    const archive = path.join(root, 'sessions', 'archive');
    fs.mkdirSync(archive, { recursive: true });
    fs.copyFileSync(sourceFile, path.join(archive, path.basename(sourceFile)));
    const handoff = extended ? handoffFor(root, sourceFile) : null;
    const number = nextSessionNumber(root);
    state.sessionNumber = number; state.entryCounter = 0; state.roundCounter = 0;
    state.currentSession = path.join('sessions', `session-${String(number).padStart(3, '0')}.md`);
    state.focus = focus;
    state.lastEntry = null; state.lastAuthor = 'System'; state.lastUpdated = new Date().toISOString();
    state.round = { id: null, status: 'waiting_for_milo', remainingResponses: 0, nextSpeaker: 'Milo', target: 'Both', openedBy: null, focus };
    state.directTurn = null;
    const destination = sessionPath(root, state.currentSession);
    fs.writeFileSync(destination, `# Session ${String(number).padStart(3, '0')}\r\n\r\n`, 'utf8');
    if (extended) addEntry(root, state, 'System', 'SESSION CONTINUATION', handoff, { 'Continues from': path.basename(sourceFile) });
    writeJsonAtomic(stateFile, state);
    return { message: extended ? `Opened ${state.currentSession}, continuing ${path.basename(sourceFile)}.` : `Opened clean ${state.currentSession}.`, warning: refreshed?.warning || null };
  });
}

function activateSession(root, token) {
  return withSessionLock(root, () => {
    const requested = normalizeSession(token);
    const file = sessionPath(root, requested.relative);
    if (!fs.existsSync(file)) throw new Error(`${requested.name} does not exist.`);
    if (!databaseSessionsUnlimited(root) && fs.statSync(file).size >= ACTIVATION_LIMIT) throw new Error('That session is at least 90% full and can only be read. Use Continue in new session.');
    const stateFile = path.join(root, 'state', 'collaboration.json');
    const state = readJson(stateFile);
    if (state.directTurn?.active || state.round?.status === 'open' || dispatcherActive(root)) throw new Error('Finish the current work before activating another session.');
    const oldFile = sessionPath(root, state.currentSession);
    let warning = null;
    if (oldFile.toLowerCase() !== file.toLowerCase()) warning = refreshMetadata(root, oldFile)?.warning || null;
    const entries = parseEntries(fs.readFileSync(file, 'utf8'));
    const last = entries.at(-1);
    const focus = focusFor(root, requested.name);
    state.sessionNumber = requested.number; state.currentSession = requested.relative; state.focus = focus;
    state.entryCounter = Number(last?.id.match(/(\d{4})$/)?.[1] || 0); state.roundCounter = 0;
    state.round = { id: null, status: 'waiting_for_milo', remainingResponses: 0, nextSpeaker: 'Milo', target: 'Both', openedBy: null, focus };
    state.directTurn = null;
    if (last) { state.lastEntry = last.id; state.lastAuthor = last.author; state.lastUpdated = last.timestamp || state.lastUpdated; }
    writeJsonAtomic(stateFile, state);
    return { message: `Activated ${state.currentSession}.`, warning };
  });
}

function listSessions(root) {
  const state = readJson(path.join(root, 'state', 'collaboration.json'));
  return fs.readdirSync(path.join(root, 'sessions')).filter(name => /^session-\d{3}\.md$/i.test(name)).sort().map(name => {
    const bytes = fs.statSync(path.join(root, 'sessions', name)).size;
    const unlimited = databaseSessionsUnlimited(root);
    return { session: path.basename(name, '.md'), bytes, percent: unlimited ? 0 : Math.round(bytes / MAX_SESSION_BYTES * 1000) / 10,
      full: unlimited ? false : bytes >= MAX_SESSION_BYTES, activatable: unlimited || bytes < ACTIVATION_LIMIT, capacityMode: unlimited ? 'database' : 'files',
      active: String(state.currentSession).replace(/\\/g, '/').toLowerCase() === `sessions/${name}`.toLowerCase() };
  });
}

module.exports = { MAX_SESSION_BYTES, ACTIVATION_LIMIT, normalizeSession, openContinuation, activateSession, listSessions, parseEntries };
