'use strict';

const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { getCredential } = require('./credential-store');

function findCommand(command, candidates = []) {
  const probe = spawnSync(process.platform === 'win32' ? 'where.exe' : 'which', [command], { encoding: 'utf8', windowsHide: true });
  const found = probe.status === 0 ? String(probe.stdout).split(/\r?\n/).find(Boolean) : null;
  if (found) return found.trim();
  const candidate = candidates.find(item => item && fs.existsSync(item));
  if (candidate) return candidate;
  throw new Error(`${command} was not found.`);
}

function codexCandidates() {
  const candidates = [];
  const desktopBin = path.join(process.env.LOCALAPPDATA || '', 'OpenAI', 'Codex', 'bin');
  try {
    for (const directory of fs.readdirSync(desktopBin, { withFileTypes: true })) {
      if (directory.isDirectory()) candidates.push(path.join(desktopBin, directory.name, 'codex.exe'));
    }
  } catch {}
  candidates.push(path.join(process.env.APPDATA || '', 'npm', 'codex.cmd'));
  return candidates;
}

function loadAgents(root, includeDisabled = false) {
  const file = path.join(root, 'config', 'agents.json');
  const agents = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')).agents || [] : [];
  return agents.filter(agent => includeDisabled || agent.enabled !== false);
}

function resolveAgent(root, token) {
  const wanted = String(token || '').toLowerCase();
  return loadAgents(root).find(agent => [agent.name, agent.handle, ...(agent.aliases || [])].some(value => String(value).toLowerCase() === wanted)) || null;
}

function antigravityInput(prompt) {
  return `${JSON.stringify({ event: 'user', message: { role: 'user', content: [{ type: 'text', text: prompt }] } })}\n`;
}

function antigravityOutput(output) {
  let response = '';
  for (const line of String(output).split(/\r?\n/)) {
    if (!line.trim().startsWith('{')) continue;
    try { const item = JSON.parse(line); if (item.event === 'result' && item.result?.status === 'SUCCESS') response = String(item.result.response || ''); } catch {}
  }
  if (!response.trim()) throw new Error('Antigravity stream output did not contain a successful result response.');
  return response;
}

function invocationFor(root, agent, prompt, options = {}) {
  const turns = Number(options.maxTurns || 10);
  switch (agent.kind) {
    case 'Claude': return { executable: findCommand('claude'), args: ['-p','--model',agent.model || 'sonnet','--output-format','text','--max-turns',String(turns),'--tools','Read','--permission-mode','dontAsk','--no-session-persistence'], input: prompt, output: text => text };
    case 'Codex': return { executable: findCommand('codex.exe', codexCandidates()), args: ['--ask-for-approval','never','exec','--sandbox','read-only','--cd',root,'--ephemeral','-'], input: prompt, output: text => text };
    // Plan mode already prevents project edits. Antigravity's additional Windows
    // terminal sandbox starts a short-lived helper console, which visibly flashes
    // whenever Gem is invoked, so it is intentionally omitted here.
    case 'Antigravity': return { executable: findCommand('agy', [path.join(process.env.LOCALAPPDATA || '', 'agy', 'bin', 'agy.exe')]), args: ['--input-format','stream-json','--output-format','stream-json','--mode','plan','--disable-slash-commands','--print='], input: antigravityInput(prompt), output: antigravityOutput };
    case 'Ollama': {
      if (!agent.model) throw new Error(`Agent '${agent.name}' needs an Ollama model.`);
      return { executable: findCommand('ollama', [path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Ollama', 'ollama.exe'), path.join(process.env.LOCALAPPDATA || '', 'Ollama', 'ollama.exe')]), args: ['run',agent.model,'--think=false','--hidethinking','--nowordwrap'], input: prompt, output: text => text };
    }
    default: throw new Error(`Agent adapter '${agent.kind}' is not implemented.`);
  }
}

function joinedUrl(baseUrl, suffix) {
  return `${String(baseUrl || '').replace(/\/$/, '')}/${String(suffix || '').replace(/^\//, '')}`;
}

function pricingFor(agent) {
  const configuredInput = Number(agent.inputCostPerMillion);
  const configuredOutput = Number(agent.outputCostPerMillion);
  if (Number.isFinite(configuredInput) && Number.isFinite(configuredOutput) && configuredInput >= 0 && configuredOutput >= 0) {
    return { inputPerMillion: configuredInput, outputPerMillion: configuredOutput, source: 'agent configuration' };
  }
  const model = String(agent.model || '').toLowerCase();
  if (agent.httpProvider === 'mistral') {
    if (/mistral-medium(?:-3-5|-latest)/.test(model)) return { inputPerMillion: 1.5, outputPerMillion: 7.5, source: 'Mistral standard pricing' };
    if (/mistral-large(?:-3|-latest)/.test(model)) return { inputPerMillion: 0.5, outputPerMillion: 1.5, source: 'Mistral standard pricing' };
    if (/mistral-small(?:-4|-latest)/.test(model)) return { inputPerMillion: 0.15, outputPerMillion: 0.6, source: 'Mistral standard pricing' };
  }
  return null;
}

function responseUsage(data, agent) {
  const raw = data?.usage;
  if (!raw) return null;
  const inputTokens = Number(raw.input_tokens ?? raw.prompt_tokens ?? 0);
  const outputTokens = Number(raw.output_tokens ?? raw.completion_tokens ?? 0);
  const totalTokens = Number(raw.total_tokens ?? (inputTokens + outputTokens));
  const pricing = pricingFor(agent);
  const costUsd = pricing ? ((inputTokens * pricing.inputPerMillion) + (outputTokens * pricing.outputPerMillion)) / 1000000 : null;
  return { inputTokens, outputTokens, totalTokens, costUsd, pricing };
}

async function runHttpAgent(agent, prompt, options = {}) {
  const apiKey = getCredential(agent.credentialId || `agent:${agent.handle}`);
  if (!apiKey) throw new Error(`${agent.name} does not have a saved API key.`);
  if (!agent.baseUrl || !agent.model) throw new Error(`${agent.name} needs an API URL and model.`);
  const style = agent.apiStyle || 'openai-chat';
  let url, headers = { 'content-type': 'application/json' }, body;
  if (style === 'anthropic-messages') {
    url = joinedUrl(agent.baseUrl, 'v1/messages');
    headers['x-api-key'] = apiKey;
    headers['anthropic-version'] = '2023-06-01';
    body = { model: agent.model, max_tokens: Number(agent.maxOutputTokens || 4096), messages: [{ role: 'user', content: prompt }] };
  } else if (style === 'openai-responses') {
    url = joinedUrl(agent.baseUrl, 'responses');
    headers.authorization = `Bearer ${apiKey}`;
    body = { model: agent.model, input: prompt };
  } else {
    url = joinedUrl(agent.baseUrl, 'chat/completions');
    headers.authorization = `Bearer ${apiKey}`;
    body = { model: agent.model, messages: [{ role: 'user', content: prompt }] };
  }
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (options.signal?.aborted) controller.abort();
  else options.signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => controller.abort(), Number(options.timeoutMilliseconds || 300000));
  let response;
  try { response = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal: controller.signal }); }
  catch (error) { throw new Error(error.name === 'AbortError' ? `${agent.name} timed out.` : `${agent.name} could not connect: ${error.message}`); }
  finally { clearTimeout(timer); options.signal?.removeEventListener('abort', abort); }
  const raw = await response.text();
  let data; try { data = JSON.parse(raw); } catch { data = null; }
  if (!response.ok) throw new Error(data?.error?.message || data?.message || `${agent.name} returned HTTP ${response.status}.`);
  const text = style === 'anthropic-messages'
    ? (data?.content || []).filter(item => item.type === 'text').map(item => item.text).join('\n')
    : style === 'openai-responses'
      ? (data?.output_text || (data?.output || []).flatMap(item => item.content || []).filter(item => item.type === 'output_text').map(item => item.text).join('\n'))
      : data?.choices?.[0]?.message?.content;
  if (!String(text || '').trim()) throw new Error(`${agent.name} returned no text response.`);
  return { agent, text: String(text).trim(), stderr: '', usage: responseUsage(data, agent) };
}

function runAgent(root, agentToken, prompt, options = {}) {
  const agent = typeof agentToken === 'object' ? agentToken : resolveAgent(root, agentToken);
  if (!agent) return Promise.reject(new Error(`Unknown Demi agent '${agentToken}'.`));
  if (agent.kind === 'HTTP') return runHttpAgent(agent, prompt, options);
  const invocation = invocationFor(root, agent, prompt, options);
  const timeoutMilliseconds = Number(options.timeoutMilliseconds || 300000);
  return new Promise((resolve, reject) => {
    // npm-installed Windows CLIs commonly resolve to .cmd/.bat shims. Node cannot
    // CreateProcess those files directly (it fails with spawn EINVAL), so let the
    // Windows command processor unwrap trusted provider shims. Prompts still travel
    // over stdin and are never interpolated into the command line.
    const needsCommandShell = process.platform === 'win32' && /\.(?:cmd|bat)$/i.test(invocation.executable);
    const child = spawn(invocation.executable, invocation.args, { cwd: root, windowsHide: true, shell: needsCommandShell, stdio: ['pipe','pipe','pipe'], env: process.env });
    let stdout = '', stderr = '', settled = false;
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => { stdout += chunk; }); child.stderr.on('data', chunk => { stderr += chunk; });
    const timer = setTimeout(() => { if (!settled) child.kill(); }, timeoutMilliseconds);
    const abort = () => { if (!settled) child.kill(); };
    if (options.signal?.aborted) abort(); else options.signal?.addEventListener('abort', abort, { once: true });
    child.on('error', error => { clearTimeout(timer); options.signal?.removeEventListener('abort', abort); settled = true; reject(error); });
    child.on('close', code => {
      clearTimeout(timer); options.signal?.removeEventListener('abort', abort); settled = true;
      if (options.signal?.aborted) return reject(new Error(`${agent.name} was stopped.`));
      if (code !== 0) return reject(new Error((stderr || stdout || `${agent.name} exited with code ${code}.`).trim()));
      try { const text = invocation.output(stdout).trim(); if (!text) throw new Error(`${agent.name} returned no response.`); resolve({ agent, text, stderr }); }
      catch (error) { reject(error); }
    });
    child.stdin.end(invocation.input, 'utf8');
  });
}

async function checkIn(root, token, timeoutSeconds = 60) {
  const agent = resolveAgent(root, token);
  if (!agent) throw new Error(`Unknown Demi agent '${token}'.`);
  const expected = `DEMI_CHECKIN_OK ${agent.name}`;
  const started = Date.now();
  try {
    const result = await runAgent(root, agent, `This is a private availability check from Demi. Do not read project files, use tools, or discuss the manuscript. Reply with exactly: ${expected}`, { maxTurns: 1, timeoutMilliseconds: Math.min(Number(timeoutSeconds || 60), 60) * 1000 });
    const online = result.text.trim() === expected;
    return { agent: agent.name, online, checkedAt: new Date().toISOString(), elapsedMs: Date.now() - started, reason: online ? null : 'did not return the check-in confirmation', resetHint: null, diagnostics: null };
  } catch (error) {
    return { agent: agent.name, online: false, checkedAt: new Date().toISOString(), elapsedMs: Date.now() - started, reason: error.message, resetHint: null, diagnostics: null };
  }
}

module.exports = { loadAgents, resolveAgent, invocationFor, runAgent, runHttpAgent, checkIn, antigravityInput, antigravityOutput };
