'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const { spawnSync } = require('child_process');

function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2), 'utf8');
  fs.renameSync(temporary, file);
}

function withSessionLock(root, action, timeoutMilliseconds = 10000) {
  const lockFile = path.join(root, 'state', 'session.lock.exclusive-lock');
  const deadline = Date.now() + timeoutMilliseconds;
  let descriptor;
  while (true) {
    try {
      descriptor = fs.openSync(lockFile, 'wx', 0o600);
      fs.writeFileSync(descriptor, JSON.stringify({ pid: process.pid, acquiredAt: new Date().toISOString() }), 'utf8');
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        if (Date.now() - fs.statSync(lockFile).mtimeMs > 600000) { fs.unlinkSync(lockFile); continue; }
      } catch (statError) { if (statError.code !== 'ENOENT') throw statError; }
      if (Date.now() >= deadline) throw new Error('Timed out waiting for the collaboration state lock.');
      sleepSync(50);
    }
  }
  try { return action(); }
  finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try { fs.unlinkSync(lockFile); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}

function clone(value) { return value == null ? value : JSON.parse(JSON.stringify(value)); }
function pad(value, width) { return String(value).padStart(width, '0'); }

function statePaths(root) {
  return { state: path.join(root, 'state', 'collaboration.json'), agents: path.join(root, 'config', 'agents.json') };
}

function automaticSequence(root) {
  const configured = JSON.parse(fs.readFileSync(statePaths(root).agents, 'utf8')).agents || [];
  const enabled = configured.filter(agent => agent.enabled !== false);
  const ordinary = enabled.filter(agent => agent.participationMode === 'automatic').map(agent => String(agent.name));
  const synthesis = enabled.filter(agent => agent.synthesisEnabled === true).map(agent => String(agent.name));
  return [...ordinary, ...synthesis];
}

function synthesisAgents(root) {
  const configured = JSON.parse(fs.readFileSync(statePaths(root).agents, 'utf8')).agents || [];
  return configured.filter(agent => agent.enabled !== false && agent.synthesisEnabled === true).map(agent => String(agent.name));
}

function resolveAgent(root, token) {
  const value = String(token || '').toLowerCase();
  const configured = JSON.parse(fs.readFileSync(statePaths(root).agents, 'utf8')).agents || [];
  return configured.find(agent => agent.enabled !== false && (
    String(agent.name).toLowerCase() === value || String(agent.handle).toLowerCase() === value ||
    (agent.aliases || []).some(alias => String(alias).toLowerCase() === value)
  )) || null;
}

function resolveHuman(root, token) {
  const value = String(token || '').trim().toLowerCase();
  let configured = [];
  try { configured = JSON.parse(fs.readFileSync(path.join(root, 'config', 'humans.json'), 'utf8')).humans || []; }
  catch {}
  const enabled = configured.filter(human => human.enabled !== false);
  const fallback = enabled.find(human => human.canSetCanon === true) || enabled[0] || { id: 'owner', sourceAuthor: 'Owner', displayName: 'Owner' };
  if (!value) return fallback;
  return enabled.find(human => [human.id, human.sourceAuthor, human.displayName].some(item => String(item || '').trim().toLowerCase() === value)) || null;
}

function activeRoundParticipants(root, state) {
  if (state.round?.status !== 'open') return [];
  if (Array.isArray(state.round.sequence) && state.round.sequence.length) return [...new Set(state.round.sequence.map(String))];
  const configured = JSON.parse(fs.readFileSync(statePaths(root).agents, 'utf8')).agents || [];
  return configured.filter(agent => agent.enabled !== false && (agent.participationMode === 'automatic' || agent.synthesisEnabled === true)).map(agent => String(agent.name));
}

function entryCode(author, root) {
  const fixed = { System: 'S' };
  const human = resolveHuman(root, author);
  if (human && [human.sourceAuthor, human.displayName].includes(author)) return human.canSetCanon === true ? 'M' : 'H';
  if (fixed[author]) return fixed[author];
  const agent = resolveAgent(root, author);
  return String(agent?.handle || author || 'G').slice(0, 1).toUpperCase().replace(/[^A-Z]/, 'G');
}

function databaseSessionMode(root) {
  try { return String(JSON.parse(fs.readFileSync(path.join(root, 'config', 'storage.json'), 'utf8')).backend || '').toLowerCase() === 'postgresql'; }
  catch { return false; }
}

function persistDatabaseEntry(root, payload) {
  if (!databaseSessionMode(root)) return false;
  const payloadFile = path.join(os.tmpdir(), `demi-entry-${process.pid}-${crypto.randomBytes(6).toString('hex')}.json`);
  try {
    fs.writeFileSync(payloadFile, JSON.stringify(payload), 'utf8');
    const powershell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    const result = spawnSync(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tools', 'demi-session-store.ps1'), 'append-file', '-Root', root, '-PayloadFile', payloadFile], { cwd: root, encoding: 'utf8', windowsHide: true, timeout: 30000 });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error((result.stderr || result.stdout || 'PostgreSQL session write failed.').trim());
    return true;
  } finally { try { fs.unlinkSync(payloadFile); } catch {} }
}

function addEntry(root, state, author, type, body, metadata = {}) {
  state.entryCounter = Number(state.entryCounter || 0) + 1;
  const id = `S${pad(state.sessionNumber, 3)}-${entryCode(author, root)}${pad(state.entryCounter, 4)}`;
  const timestamp = new Date().toISOString();
  const lines = [`## ${id} - ${author}`, `Timestamp: ${timestamp}`, `Type: ${type}`];
  for (const [key, value] of Object.entries(metadata)) if (value !== null && value !== undefined && String(value) !== '') lines.push(`${key}: ${value}`);
  lines.push('', String(body || '').replace(/\r\n?|\n/g, '\r\n'), '');
  const sessionPath = path.join(root, String(state.currentSession).replace(/[\\/]/g, path.sep));
  persistDatabaseEntry(root, { session:path.basename(sessionPath, '.md'), entryId:id, sequence:Number(state.entryCounter), author, entryType:type, body:String(body || ''), metadata, createdAt:timestamp });
  fs.appendFileSync(sessionPath, `${lines.join('\r\n')}\r\n`, 'utf8');
  state.lastEntry = id; state.lastAuthor = author; state.lastUpdated = timestamp;
  return id;
}

function appendIndependentEntry(root, author, type, body, metadata = {}) {
  return withSessionLock(root, () => {
    const stateFile = statePaths(root).state;
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    const id = addEntry(root, state, author, type, body, metadata);
    writeJsonAtomic(stateFile, state);
    return { id, state };
  });
}

function clearReviewPause(state) { if (state.miloReviewPause) state.miloReviewPause = null; }

function addRoundEntry(root, author, body, target = 'Both') {
  return withSessionLock(root, () => {
    const stateFile = statePaths(root).state;
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    clearReviewPause(state);
    if (state.round?.status === 'open') {
      const id = addEntry(root, state, author, resolveHuman(root, author)?.canSetCanon === true ? 'INTERJECTION' : 'GUEST CONTRIBUTION', body, { Round: state.round.id });
      state.round.openedBy = id;
      writeJsonAtomic(stateFile, state);
      return `Added ${author === 'Alice' ? `Alice contribution ${id}` : id} to ${state.round.id}. Response allowance unchanged at ${state.round.remainingResponses}.`;
    }
    const sequence = target === 'Both' ? automaticSequence(root) : [target, target, target];
    if (!sequence.length) {
      const id = addEntry(root, state, author, resolveHuman(root, author)?.canSetCanon === true ? 'HUMAN ENTRY' : 'GUEST CONTRIBUTION', body);
      writeJsonAtomic(stateFile, state);
      return `Added ${id}. No automatic agents are configured.`;
    }
    state.roundCounter = Number(state.roundCounter || 0) + 1;
    const roundId = `R${pad(state.sessionNumber, 3)}-${pad(state.roundCounter, 3)}`;
    state.round = { id: roundId, status: 'open', remainingResponses: sequence.length, nextSpeaker: sequence[0], target,
      openedBy: null, sequence, sequenceIndex: 0, synthesisAgents: target === 'Both' ? synthesisAgents(root) : [], focus: clone(state.focus || null) };
    const id = addEntry(root, state, author, resolveHuman(root, author)?.canSetCanon === true ? 'PROPOSAL ROUND' : 'GUEST CONTRIBUTION', body, {
      Round: roundId, Target: target, 'Default agent responses': sequence.length, 'Response sequence': sequence.join(' -> ')
    });
    state.round.openedBy = id;
    writeJsonAtomic(stateFile, state);
    return `Added ${author === 'Alice' ? `Alice contribution ${id}` : id}. Opened ${roundId}: ${sequence.join(' -> ')} (${sequence.length} responses).`;
  });
}

function addNote(root, body, acknowledgements = true, author = resolveHuman(root, '')?.sourceAuthor || 'Owner') {
  return withSessionLock(root, () => {
    const stateFile = statePaths(root).state;
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    if (!Array.isArray(state.acknowledgements)) state.acknowledgements = [];
    const pause = clone(state.miloReviewPause || null);
    const id = addEntry(root, state, author, 'NOTE', body);
    if (acknowledgements) state.acknowledgements.push({ noteEntryId: id, pending: ['Claude','Rowan'], completed: [],
      resumeState: { round: clone(state.round), miloReviewPause: pause }, createdAt: new Date().toISOString() });
    writeJsonAtomic(stateFile, state);
    return `Added ${id}. ${acknowledgements ? 'Queued acknowledgments from Claude and Rowan.' : 'No acknowledgments requested.'}`;
  });
}

function nextGroupAgent(root, current) {
  const base = automaticSequence(root);
  const unique = [...new Set(base)];
  if (!unique.length) return current;
  const index = unique.indexOf(current);
  return unique[(index + 1 + unique.length) % unique.length];
}

function continueRound(root, count) {
  if (!Number.isInteger(count) || count < 1 || count > 50) throw new Error('Continuation count must be between 1 and 50.');
  return withSessionLock(root, () => {
    const stateFile = statePaths(root).state;
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    clearReviewPause(state);
    if (!state.round?.id) throw new Error('There is no current round to continue.');
    let previousSequenceCount = 0;
    if (state.round.target === 'Both' && Array.isArray(state.round.sequence)) {
      previousSequenceCount = state.round.sequence.length;
      let last = state.round.sequence.at(-1) || automaticSequence(root).at(-2) || 'Gem';
      for (let index = 0; index < count; index += 1) { last = nextGroupAgent(root, last); state.round.sequence.push(last); }
    }
    state.round.remainingResponses = Number(state.round.remainingResponses || 0) + count;
    state.round.status = 'open';
    if (!state.round.nextSpeaker || Boolean(resolveHuman(root, state.round.nextSpeaker))) {
      if (state.round.target === 'Both' && Array.isArray(state.round.sequence)) {
        state.round.sequenceIndex = previousSequenceCount; state.round.nextSpeaker = state.round.sequence[previousSequenceCount];
      } else state.round.nextSpeaker = state.lastAuthor === 'Claude' ? 'Rowan' : 'Claude';
    }
    const id = addEntry(root, state, resolveHuman(root, '')?.sourceAuthor || 'Owner', 'CONTINUE', `Continue the current discussion for ${count} additional agent responses.`, {
      Round: state.round.id, 'Additional agent responses': count
    });
    writeJsonAtomic(stateFile, state);
    return `Added ${id}. ${state.round.id} now permits ${state.round.remainingResponses} responses; next: ${state.round.nextSpeaker}.`;
  });
}

function addDirect(root, agentToken, body, author = resolveHuman(root, '')?.sourceAuthor || 'Owner') {
  return withSessionLock(root, () => {
    const agent = resolveAgent(root, agentToken);
    if (!agent || agent.directEnabled === false) throw new Error(`Unknown or unavailable direct agent '${agentToken}'.`);
    const stateFile = statePaths(root).state;
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    if (state.directTurn?.active) throw new Error(`A direct turn for ${state.directTurn.agent} is already active.`);
    const participants = activeRoundParticipants(root, state);
    if (participants.includes(agent.name)) throw new Error(`${agent.name} is participating in the active collaboration round. Wait for the round to finish before addressing ${agent.name} directly.`);
    const id = addEntry(root, state, author, 'DIRECT QUESTION', body, { Agent: agent.name, 'Response allowance': 1, 'Suspended round': state.round?.id });
    state.directTurn = { active: true, agent: agent.name, openedBy: id, remainingResponses: 1,
      suspendedRound: clone(state.round), createdAt: new Date().toISOString() };
    writeJsonAtomic(stateFile, state);
    return `Added ${id}. Direct ${agent.name} allowance is exactly one; normal round suspended unchanged.`;
  });
}

const nativeCommands = new Set(['say','alice','note','continue','direct','new-session','session']);

function runNativeCommand(root, command, args = []) {
  const authorMarker = args.findIndex(value => String(value).toLowerCase() === '-author');
  const requestedAuthor = authorMarker >= 0 ? args[authorMarker + 1] : '';
  const human = resolveHuman(root, requestedAuthor);
  if (!human) throw new Error(`Unknown or disabled human identity '${requestedAuthor}'.`);
  const author = String(human.sourceAuthor || human.displayName || human.id);
  const withoutAuthor = authorMarker >= 0 ? [...args.slice(0, authorMarker), ...args.slice(authorMarker + 2)] : [...args];
  if (command === 'say') {
    const marker = withoutAuthor.findIndex(value => String(value).toLowerCase() === '-to');
    const targetToken = marker >= 0 ? withoutAuthor[marker + 1] : 'Both';
    const body = (marker >= 0 ? withoutAuthor.slice(0, marker) : withoutAuthor).join(' ');
    const target = String(targetToken).toLowerCase() === 'both' ? 'Both' : resolveAgent(root, targetToken)?.name;
    if (!target) throw new Error(`Unknown Demi agent '${targetToken}'.`);
    return addRoundEntry(root, author, body, target);
  }
  if (command === 'alice') return addRoundEntry(root, 'Alice', args.join(' '), 'Both');
  if (command === 'note') return addNote(root, withoutAuthor.filter(value => String(value).toLowerCase() !== '-noack').join(' '), !withoutAuthor.some(value => String(value).toLowerCase() === '-noack'), author);
  if (command === 'continue') return continueRound(root, Number(args[0]));
  if (command === 'direct') return addDirect(root, withoutAuthor[0], withoutAuthor.slice(1).filter(value => String(value).toLowerCase() !== '-nodispatch').join(' '), author);
  if (command === 'new-session') {
    const result = require('./session-lifecycle').openContinuation(root, args[0]);
    return result.warning ? `${result.message}\nWARNING: ${result.warning}` : result.message;
  }
  if (command === 'session') {
    const lifecycle = require('./session-lifecycle');
    const verb = String(args[0] || 'list').toLowerCase();
    if (verb === 'list') return JSON.stringify(lifecycle.listSessions(root), null, 2);
    if (verb === 'activate' && args[1]) {
      const result = lifecycle.activateSession(root, args[1]);
      return result.warning ? `${result.message}\nWARNING: ${result.warning}` : result.message;
    }
    throw new Error('Usage: demi session [list|activate session-NNN]');
  }
  throw new Error(`Command '${command}' has not yet migrated to the Node runtime.`);
}

module.exports = { nativeCommands, runNativeCommand, addEntry, appendIndependentEntry, writeJsonAtomic, withSessionLock, automaticSequence, resolveAgent, resolveHuman, databaseSessionMode, persistDatabaseEntry };
