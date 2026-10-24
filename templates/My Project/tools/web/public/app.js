'use strict';

const elements = Object.fromEntries([
  'messages', 'load-earlier', 'composer', 'send', 'stop', 'continue', 'continue-count', 'activity', 'activity-details', 'status-clocks',
  'notice', 'new-messages', 'connection', 'session-name', 'settings',
  'settings-button', 'theme', 'view', 'message-font-size', 'show-ids', 'show-time', 'show-status',
  'show-dispatch', 'show-counts', 'help-button', 'help-dialog', 'help-content', 'help-search', 'close-help', 'draft-button',
  'new-session', 'new-session-dialog', 'new-session-summary', 'new-session-open-round',
  'cancel-new-session', 'confirm-new-session', 'sessions-button', 'sessions-dialog', 'sessions-list', 'close-sessions', 'close-sessions-top',
  'agents-button', 'agents-dialog', 'agents-list', 'humans-list', 'security-form', 'require-lan-pairing', 'security-warning', 'security-form-status', 'add-human', 'add-agent', 'close-agents', 'close-agents-top', 'agent-form', 'agent-form-title',
  'agent-original-handle', 'agent-name', 'agent-handle', 'agent-kind', 'agent-model', 'agent-icon-picker', 'agent-icon', 'agent-color',
  'agent-aliases', 'agent-role', 'agent-instruction-file', 'agent-direct', 'agent-automatic', 'agent-synthesis', 'agent-form-status', 'agent-host-note', 'save-agent', 'cancel-agent',
  'agent-http-fields', 'agent-http-provider', 'agent-api-style', 'agent-base-url', 'agent-api-key', 'agent-form-help',
  'draft-dialog', 'draft-form', 'draft-request', 'draft-file', 'draft-format', 'draft-agent', 'draft-reviewer', 'draft-model-label', 'draft-form-status', 'draft-generate',
  'close-draft', 'draft-preview', 'draft-title', 'draft-content',
  'draft-save-file', 'draft-save-md', 'draft-save-docx', 'draft-revise',
  'draft-rowan', 'draft-discard', 'draft-created'
  , 'conversation-sidebar', 'conversation-list', 'conversation-collapse', 'last-response',
  'conversation-order', 'connection-qr-dialog', 'connection-qr', 'connection-qr-url', 'close-connection-qr',
  'session-files', 'session-files-toggle', 'session-file-list', 'session-file-count', 'close-session-files', 'copy-composer', 'paste-composer',
  'attach-image', 'attachment-input', 'attachment-preview', 'composer-drop-feedback',
  'timeline-dialog', 'timeline-form', 'timeline-form-title', 'timeline-id', 'timeline-date', 'timeline-start', 'timeline-end',
  'timeline-title', 'timeline-summary', 'timeline-focus', 'timeline-references', 'timeline-status', 'timeline-confidence',
  'timeline-date-system', 'timeline-date-basis', 'timeline-impact', 'timeline-source-label', 'timeline-source-claim',
  'timeline-form-status', 'close-timeline', 'delete-timeline',
  'drawer-backdrop', 'mobile-conversation', 'mobile-files',
  'agent-presence-list', 'checkin-all', 'mobile-agent-menu', 'mobile-agent-icon', 'mobile-agent-name',
  'session-capacity', 'session-capacity-fill', 'session-capacity-label',
  'project-links-label', 'project-links-panel'
  , 'project-dialog', 'project-form', 'project-name', 'project-description', 'project-goals', 'project-authority',
  'project-instructions', 'project-sources', 'project-form-status', 'close-project', 'open-storage',
  'storage-dialog', 'storage-form', 'close-storage', 'storage-current', 'storage-host', 'storage-port', 'storage-database',
  'storage-admin', 'storage-schema', 'storage-owner', 'storage-user', 'storage-fallback', 'storage-export', 'storage-save',
  'storage-test', 'storage-provision', 'storage-migrate', 'storage-preview', 'storage-import', 'storage-files', 'storage-output'
  , 'image-confirm-dialog', 'image-confirm-prompt', 'image-confirm-provider', 'image-confirm-model', 'image-confirm-resolution',
  'image-confirm-aspect', 'image-confirm-references', 'image-confirm-cost', 'image-confirm-credits', 'cancel-image-generation-top',
  'cancel-image-generation', 'confirm-image-generation'
  , 'agent-image-fields', 'agent-image-provider', 'agent-image-resolution', 'agent-image-api-key'
  , 'identity-dialog', 'identity-form', 'identity-id', 'identity-title', 'identity-explanation', 'identity-password', 'identity-remember', 'identity-status', 'close-identity'
  , 'human-dialog', 'human-form', 'human-name', 'human-color', 'human-role', 'human-canon', 'human-password', 'human-switch', 'human-form-status', 'save-human', 'close-human'
].map(id => [id, document.getElementById(id)]));

const defaultPreferences = {
  theme: 'dark', view: 'compact', showIds: true, showTime: true,
  showStatus: true, showDispatch: true, showCounts: true, conversationOpen: true,
  conversationNewestFirst: true, messageFontSize: 17
};
const preferences = { ...defaultPreferences, ...JSON.parse(localStorage.getItem('demi-web-preferences') || '{}') };
let token = null;
let current = null;
let eventSource = null;
let connectedOnce = false;
let pendingDraft = null;
let draftReviewerInitialized = false;
let dismissedNoticeMessage = null;
let pendingAttachments = [];
let presenceSupported = false;
let dispatcherRestartPromptActive = false;
let humanIdentityId = localStorage.getItem('demi-human-identity') || '';
const agentCreditCache = new Map();
const MESSAGE_PAGE_SIZE = 20;
let renderedEntries = [];
let renderedStart = 0;
const HTTP_PRESETS = Object.freeze({
  openai: { baseUrl: 'https://api.openai.com/v1', apiStyle: 'openai-responses', model: 'gpt-5-mini' },
  anthropic: { baseUrl: 'https://api.anthropic.com', apiStyle: 'anthropic-messages', model: 'claude-sonnet-4-6' },
  gemini: { baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai', apiStyle: 'openai-chat', model: 'gemini-2.5-flash' },
  mistral: { baseUrl: 'https://api.mistral.ai/v1', apiStyle: 'openai-chat', model: 'mistral-large-latest' },
  deepseek: { baseUrl: 'https://api.deepseek.com', apiStyle: 'openai-chat', model: 'deepseek-flash' },
  other: { baseUrl: '', apiStyle: '', model: '' }
});
const ATTACHMENT_MAX_BYTES = 25 * 1024 * 1024;
const compactViewport = () => matchMedia('(max-width: 620px), (max-height: 620px) and (pointer: coarse)').matches;
const providerConfigurationAllowed = () => current?.canConfigureProviders ?? ['localhost', '127.0.0.1', '[::1]', '::1'].includes(location.hostname);
let headerMenusCompact = null;
function syncHeaderMenus() {
  const compact = compactViewport();
  if (headerMenusCompact === compact) return;
  for (const menu of document.querySelectorAll('.agent-presence-menu, .mobile-actions-menu')) menu.toggleAttribute('open', !compact);
  headerMenusCompact = compact;
}
const ATTACHMENT_MIME = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif']);
const ATTACHMENT_EXTENSIONS = new Set(['.png','.jpg','.jpeg','.webp','.gif','.md','.pdf','.docx','.epub']);

function savePreferences() {
  localStorage.setItem('demi-web-preferences', JSON.stringify(preferences));
  applyPreferences();
}

function applyPreferences() {
  document.documentElement.dataset.theme = preferences.theme;
  const messageFontSize = [15, 17, 19, 21].includes(Number(preferences.messageFontSize)) ? Number(preferences.messageFontSize) : 17;
  document.documentElement.style.setProperty('--message-font-size', `${messageFontSize}px`);
  document.body.classList.toggle('hide-ids', !preferences.showIds);
  document.body.classList.toggle('hide-time', !preferences.showTime);
  document.body.classList.toggle('hide-counts', !preferences.showCounts);
  document.body.classList.toggle('conversation-collapsed', !preferences.conversationOpen);
  elements['conversation-collapse'].setAttribute('aria-expanded', String(preferences.conversationOpen));
  elements['conversation-collapse'].setAttribute('aria-label', `${preferences.conversationOpen ? 'Collapse' : 'Open'} conversation sidebar`);
  elements['conversation-collapse'].textContent = preferences.conversationOpen ? '‹' : '›';
  elements.theme.value = preferences.theme;
  elements.view.value = preferences.view;
  elements['message-font-size'].value = String(messageFontSize);
  elements['show-ids'].checked = preferences.showIds;
  elements['show-time'].checked = preferences.showTime;
  elements['show-status'].checked = preferences.showStatus;
  elements['show-dispatch'].checked = preferences.showDispatch;
  elements['show-counts'].checked = preferences.showCounts;
  for (const message of elements.messages.children) updateMessageDetail(message);
  updateStatus(current);
}

function updateMessageDetail(article) {
  if (!article.dataset.entry) return;
  const entry = JSON.parse(article.dataset.entry);
  let metadata = article.querySelector('.metadata');
  if (preferences.view === 'detailed') {
    if (!metadata) {
      metadata = document.createElement('dl');
      metadata.className = 'metadata';
      for (const [key, value] of Object.entries(entry.metadata || {})) {
        const term = document.createElement('dt');
        const description = document.createElement('dd');
        term.textContent = key;
        description.textContent = value;
        metadata.append(term, description);
      }
      article.querySelector('.message-body').before(metadata);
    }
  } else if (metadata) metadata.remove();
}

function localTime(timestamp, detailed = false, stacked = false) {
  if (!timestamp) return '';
  const value = new Date(timestamp);
  if (Number.isNaN(value.getTime())) return timestamp;
  if (detailed) return value.toLocaleString();
  const now = new Date();
  const time = value.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const today = value.getFullYear() === now.getFullYear() && value.getMonth() === now.getMonth() && value.getDate() === now.getDate();
  if (today) return time;
  const date = value.toLocaleDateString([], { day: 'numeric', month: 'numeric' });
  return stacked ? `${date}\n${time}` : `${date}, ${time}`;
}

function participantAppearance(author) {
  const human = (current?.humans || []).find(item => item.sourceAuthor === author);
  if (human) return { name: human.displayName, color: human.color, human: true };
  const agent = (current?.agents || []).find(item => item.name === author);
  return agent ? { name: agent.name, color: agent.color, human: false } : { name: author, color: null, human: false };
}

function selectedHuman() {
  const humans = current?.humans || [];
  return humans.find(human => human.id === humanIdentityId) || humans.find(human => human.canSetCanon) || humans[0] || null;
}

function updateConnectionLabel() {
  const network = current?.webMode === 'lan' ? 'Home network' : 'Local';
  const human = selectedHuman();
  const signedIn = human && (!human.passwordProtected || current?.authenticatedHumanId === human.id);
  elements.connection.textContent = human ? `${network} · ${signedIn ? human.displayName : `Sign in as ${human.displayName}`}` : network;
  elements.composer.placeholder = human ? `${signedIn ? 'Message Demi as' : 'Sign in to act as'} ${human.displayName}…` : 'Message Demi…';
}

async function authenticateHumanIdentity(human, password = '', remember = false) {
  const response = await fetch('/api/identity', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Demi-Token': token },
    body: JSON.stringify({ id: human.id, password, remember })
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Identity sign-in failed.');
  current.authenticatedHumanId = human.id;
  humanIdentityId = human.id;
  localStorage.setItem('demi-human-identity', humanIdentityId);
  updateConnectionLabel();
  renderHumans();
  return human;
}

function openIdentityDialog(human) {
  elements['identity-id'].value = human.id;
  elements['identity-title'].textContent = `Sign in as ${human.displayName}`;
  elements['identity-explanation'].textContent = human.canSetCanon
    ? 'This identity owns the project and can confirm canon. Enter its password or PIN.'
    : `Enter ${human.displayName}’s password or PIN to switch identities.`;
  elements['identity-password'].value = '';
  elements['identity-remember'].checked = false;
  elements['identity-status'].textContent = '';
  elements['identity-dialog'].showModal();
  elements['identity-password'].focus();
}

async function selectHumanIdentity(value) {
  const requested = String(value || '').trim().toLowerCase();
  const humans = current?.humans || [];
  const human = humans.find(item => [item.id, item.sourceAuthor, item.displayName].some(field => String(field || '').trim().toLowerCase() === requested));
  if (!human) throw new Error(`Unknown human identity “${value}”. Configured people: ${humans.map(item => item.displayName).join(', ') || 'none'}.`);
  if (human.passwordProtected && current?.authenticatedHumanId !== human.id) {
    humanIdentityId = human.id;
    localStorage.setItem('demi-human-identity', humanIdentityId);
    updateConnectionLabel();
    renderHumans();
    openIdentityDialog(human);
    return null;
  }
  return authenticateHumanIdentity(human);
}

function generatedImageAttachment(entry) {
  if (String(entry?.type || '').toUpperCase() !== 'GENERATED IMAGE') return null;
  return (entry.attachments || []).find(attachment => attachment?.image) || null;
}

async function imageBlobAsPng(blob) {
  if (blob.type === 'image/png') return blob;
  const source = URL.createObjectURL(blob);
  try {
    const image = new Image();
    image.src = source;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    canvas.getContext('2d').drawImage(image, 0, 0);
    return await new Promise((resolve, reject) => canvas.toBlob(result => result ? resolve(result) : reject(new Error('Could not convert image for the clipboard.')), 'image/png'));
  } finally { URL.revokeObjectURL(source); }
}

async function copyEntry(entry, button) {
  try {
    const image = generatedImageAttachment(entry);
    if (image) {
      if (!navigator.clipboard?.write || typeof ClipboardItem === 'undefined') throw new Error('image clipboard unavailable');
      const response = await fetch(image.url || `/api/attachment?path=${encodeURIComponent(image.path)}`);
      if (!response.ok) throw new Error('image fetch failed');
      const blob = await imageBlobAsPng(await response.blob());
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
      flashComposerTool(button, 'Image copied');
      return;
    }
    await navigator.clipboard.writeText(entry.body || '');
    flashComposerTool(button, 'Copied');
  } catch {
    showNotice(generatedImageAttachment(entry)
      ? 'The browser blocked image clipboard access. You can still use Save image.'
      : 'Clipboard access was blocked. Use the Save button or select the text manually.');
  }
}

async function saveEntry(entry, button) {
  try {
    const image = generatedImageAttachment(entry);
    if (image) {
      const response = await fetch(image.url || `/api/attachment?path=${encodeURIComponent(image.path)}`);
      if (!response.ok) throw new Error('Could not retrieve the generated image.');
      const blob = await response.blob();
      const suggestedName = image.name || `generated-image.${String(blob.type || 'image/png').split('/').at(-1)}`;
      if (typeof window.showSaveFilePicker === 'function') {
        const extension = `.${suggestedName.split('.').at(-1).toLowerCase()}`;
        const handle = await window.showSaveFilePicker({
          suggestedName,
          types: [{ description: 'Image', accept: { [blob.type || 'image/png']: [extension] } }]
        });
        const writable = await handle.createWritable();
        await writable.write(blob);
        await writable.close();
      } else {
        const download = document.createElement('a');
        const objectUrl = URL.createObjectURL(blob);
        download.href = objectUrl;
        download.download = suggestedName;
        document.body.append(download);
        download.click();
        download.remove();
        setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
      }
      flashComposerTool(button, 'Image saved');
      return;
    }
    const response = await action('entrySave', { entry: entry.id });
    flashComposerTool(button, response.result.existing ? 'Already saved' : 'Saved');
    showNotice(`${response.result.existing ? 'Already saved at' : 'Saved to'} ${response.result.path}.`);
  } catch {}
}

function renderEntry(entry, append = true) {
  const domId = DemiConversation.stableDomId(entry.id);
  const existing = document.getElementById(domId);
  if (existing) existing.remove();
  const article = document.createElement('article');
  article.id = domId;
  article.className = `message ${entry.author.toLowerCase().replace(/[^a-z0-9_-]+/g, '-')}`;
  const appearance = participantAppearance(entry.author);
  if (appearance.color) article.style.setProperty('--message-color', appearance.color);
  article.dataset.entry = JSON.stringify(entry);
  const header = document.createElement('header');
  header.className = 'message-header';
  const author = document.createElement('span');
  author.className = 'message-author';
  author.textContent = appearance.name;
  if (entry.author === 'Claude') {
    const model = document.createElement('span');
    model.className = 'message-model';
    model.textContent = entry.metadata?.Model === 'Fable' ? 'Fable' : 'Sonnet';
    author.append(document.createTextNode('  '), model);
  }
  const id = document.createElement('span');
  id.className = 'entry-id';
  id.textContent = `(${entry.id}),`;
  const time = document.createElement('time');
  time.className = 'entry-time';
  time.dateTime = entry.timestamp || '';
  time.textContent = localTime(entry.timestamp);
  const directTargetName = entry.metadata?.Type === 'DIRECT QUESTION'
    ? (entry.metadata?.Agent || entry.metadata?.To)
    : null;
  const directTarget = document.createElement('span');
  directTarget.className = 'entry-direct-target';
  directTarget.textContent = directTargetName ? `\u2192 ${directTargetName}` : '';
  const directTargetAppearance = directTargetName ? participantAppearance(directTargetName) : null;
  if (directTargetAppearance?.color) directTarget.style.color = directTargetAppearance.color;
  const synthesis = document.createElement('span');
  synthesis.className = 'entry-synthesis';
  synthesis.textContent = 'Synthesis';
  const isSynthesis = String(entry.metadata?.Synthesis || '').toLowerCase() === 'true' || String(entry.type || '').toUpperCase() === 'PARALLEL SYNTHESIS';
  const tools = document.createElement('details');
  tools.className = 'message-entry-actions';
  tools.open = true;
  const toolsSummary = document.createElement('summary');
  toolsSummary.className = 'message-actions-summary';
  toolsSummary.textContent = '•••';
  toolsSummary.setAttribute('aria-label', `Actions for ${entry.id}`);
  const isReviewComparison = entry.author === 'System' && entry.metadata?.Type === 'REVIEW COMPARISON';
  const isGeneratedImage = Boolean(generatedImageAttachment(entry));
  if (isReviewComparison) {
    article.classList.add('review-comparison');
    tools.open = true;
  }
  const copy = document.createElement('button');
  copy.type = 'button';
  copy.className = 'message-entry-tool';
  copy.textContent = isGeneratedImage ? 'Copy image' : (isReviewComparison ? 'Copy all reviews' : 'Copy');
  copy.title = isGeneratedImage ? 'Copy the generated image to the clipboard' : (isReviewComparison ? 'Copy the complete review comparison' : `Copy ${entry.id}`);
  copy.addEventListener('click', () => copyEntry(entry, copy));
  const save = document.createElement('button');
  save.type = 'button';
  save.className = 'message-entry-tool';
  save.textContent = isGeneratedImage ? 'Save image' : (isReviewComparison ? 'Save all reviews' : 'Save');
  save.title = isGeneratedImage ? 'Save the generated image to another location' : (isReviewComparison ? 'Save the complete review comparison as Markdown' : `Save ${entry.id} as Markdown`);
  save.addEventListener('click', () => saveEntry(entry, save));
  tools.append(toolsSummary, copy, save);
  header.append(author, id, time);
  if (isSynthesis) header.append(synthesis);
  if (directTargetName) header.append(directTarget);
  header.append(tools);
  const body = document.createElement('div');
  body.className = 'message-body';
  body.innerHTML = DemiMarkdown.renderMarkdown(entry.displayBody === undefined ? entry.body : entry.displayBody);
  if (entry.attachments?.length) {
    const gallery = document.createElement('div');
    gallery.className = 'message-attachments';
    for (const attachment of entry.attachments) {
      const link = document.createElement('a');
      link.className = 'message-attachment';
      link.href = attachment.url || `/api/attachment?path=${encodeURIComponent(attachment.path)}`;
      link.target = '_blank';
      link.rel = 'noopener';
      link.title = `Open ${attachment.name}`;
      if (attachment.mime?.startsWith('image/')) {
        const image = document.createElement('img'); image.src = link.href; image.alt = `Attached image: ${attachment.name}`; image.loading = 'lazy'; link.append(image);
      } else {
        const file = document.createElement('span'); file.className = 'message-attachment-file'; file.textContent = `${attachment.name.split('.').pop().toUpperCase()} · ${attachment.name}`; link.append(file);
      }
      gallery.append(link);
    }
    body.append(gallery);
  }
  article.append(header, body);
  updateMessageDetail(article);
  if (append) elements.messages.append(article);
  observeMessageLayout(article);
}

function renderEntryWindow(entries, start = Math.max(0, entries.length - MESSAGE_PAGE_SIZE)) {
  renderedEntries = entries;
  renderedStart = Math.max(0, start);
  elements.messages.replaceChildren();
  for (const entry of entries.slice(renderedStart)) renderEntry(entry);
  elements['load-earlier'].hidden = renderedStart === 0;
  if (renderedStart > 0) elements['load-earlier'].textContent = `Load earlier messages (${renderedStart} remaining)`;
}

let messageResizeObserver = null;
let followMessageTail = true;
function observeMessageLayout(article) {
  if (!('ResizeObserver' in window)) return;
  if (!messageResizeObserver) {
    messageResizeObserver = new ResizeObserver(() => {
      if (followMessageTail) requestAnimationFrame(scrollToBottom);
    });
  }
  messageResizeObserver.observe(article);
  for (const image of article.querySelectorAll('img')) image.addEventListener('load', () => {
    if (followMessageTail) requestAnimationFrame(scrollToBottom);
  }, { once: true });
}

function nearBottom() {
  const box = elements.messages;
  return box.scrollHeight - box.scrollTop - box.clientHeight < 150;
}

function receiveEntry(entry) {
  const shouldScroll = nearBottom();
  followMessageTail = shouldScroll;
  if (current) {
    current.entries = [...(current.entries || []).filter(item => item.id !== entry.id), entry];
    if (DemiConversation.isAgentResponse(entry)) {
      current.latestResponse = { id: entry.id, author: entry.author, timestamp: entry.timestamp };
    }
  }
  renderEntry(entry);
  renderConversation(current?.entries || []);
  renderSessionFiles(current?.entries || []);
  renderAgentPresence(current?.agentPresence || {});
  renderLiveClocks();
  if (shouldScroll) scrollToBottom();
  else elements['new-messages'].hidden = false;
}

function scrollToBottom() {
  elements.messages.scrollTop = elements.messages.scrollHeight;
  followMessageTail = true;
  elements['new-messages'].hidden = true;
}

function renderSession(snapshot) {
  renderEntryWindow(snapshot.entries || []);
  renderConversation(snapshot.entries || []);
  renderSessionFiles(snapshot.entries || []);
  updateStatus(snapshot);
  scrollToBottom();
}

function renderViewedSession(data) {
  renderEntryWindow(data.entries || []);
  renderConversation(data.entries || []);
  renderSessionFiles(data.entries || []);
  elements['session-name'].textContent = `${data.viewedSession} · read-only`;
  elements.composer.disabled = true;
  elements.send.disabled = true;
  elements.composer.placeholder = data.full ? 'This session is full and read-only.' : 'Viewing an inactive session. Activate it to continue here.';
  scrollToBottom();
}

function leaveSessionPreview() {
  elements.composer.disabled = false;
  elements.send.disabled = false;
  elements.composer.placeholder = 'Message Demi…';
}

function renderSessionCatalog(sessions = []) {
  const fragment = document.createDocumentFragment();
  for (const item of sessions) {
    const row = document.createElement('div'); row.className = 'session-row';
    const info = document.createElement('div'); info.className = 'session-row-info';
    const heading = document.createElement('div'); heading.className = 'session-row-heading';
    const title = document.createElement('strong'); title.className = 'session-row-title'; title.textContent = item.displayName || item.name;
    heading.append(title);
    if (item.current) { const badge=document.createElement('span');badge.className='session-active-badge';badge.textContent='Active';heading.append(badge); }
    const summary = document.createElement('span'); summary.className = 'session-row-summary'; summary.textContent = item.summary || 'No summary available yet.';
    const summaryToggle=document.createElement('button');summaryToggle.type='button';summaryToggle.className='session-summary-toggle';summaryToggle.textContent='Show more';summaryToggle.addEventListener('click',()=>{const expanded=summary.classList.toggle('expanded');summaryToggle.textContent=expanded?'Show less':'Show more';});
    const focus=document.createElement('div');focus.className='session-row-focus';
    for(const value of [item.focus?.book,item.focus?.story,...(item.focus?.characters||[]),...(item.focus?.keywords||[])].filter(Boolean)){const chip=document.createElement('span');chip.textContent=value;focus.append(chip);}
    const detail = document.createElement('span'); detail.className='session-row-metadata'; detail.textContent = item.capacityMode === 'database'
      ? `${item.name} · Database · ${Math.round(item.bytes / 1024).toLocaleString()} KB`
      : `${item.name} · ${item.percent}% · ${Math.round(item.bytes / 1024).toLocaleString()} KB`;
    info.append(heading, summary, summaryToggle, focus, detail); row.append(info);
    const buttons = document.createElement('div'); buttons.className = 'session-row-actions';
    const open = document.createElement('button'); open.type='button'; open.className='secondary'; open.textContent='Open';
    open.addEventListener('click', async () => {
      if (item.current) { leaveSessionPreview(); const fresh=await action('status'); renderSession(fresh); }
      else { const response=await fetch(`/api/session?name=${encodeURIComponent(item.name)}`,{cache:'no-store'}); renderViewedSession(await response.json()); }
      elements['sessions-dialog'].close();
    }); buttons.append(open);
    const rename=document.createElement('button');rename.type='button';rename.className='secondary';rename.textContent='Rename';rename.addEventListener('click',async()=>{const next=window.prompt('Session label (leave blank to use the fallback name):',item.label || '');if(next===null)return;const fresh=await action('renameSession',{session:item.name,label:next});renderSessionCatalog(fresh.sessions || []);});buttons.append(rename);
    const editFocus=document.createElement('button');editFocus.type='button';editFocus.className='secondary';editFocus.textContent='Edit focus';editFocus.addEventListener('click',async()=>{const book=window.prompt('Active book or project:',item.focus?.book||'');if(book===null)return;const story=window.prompt('Active story or workstream:',item.focus?.story||'');if(story===null)return;const characters=window.prompt('Focus characters/designers (comma-separated):',(item.focus?.characters||[]).join(', '));if(characters===null)return;const keywords=window.prompt('Session keywords (comma-separated):',(item.focus?.keywords||[]).join(', '));if(keywords===null)return;const fresh=await action('updateSessionFocus',{session:item.name,book,story,characters,keywords});renderSessionCatalog(fresh.sessions||[]);});buttons.append(editFocus);
    const resummarize=document.createElement('button');resummarize.type='button';resummarize.className='secondary';resummarize.textContent='Re-summarize';resummarize.addEventListener('click',async()=>{try{resummarize.textContent='Summarizing…';const fresh=await action('resummarizeSession',{session:item.name});renderSessionCatalog(fresh.sessions || []);showNotice(`${item.name} summary updated from the complete transcript.`);}catch{}finally{resummarize.textContent='Re-summarize';}});buttons.append(resummarize);
    const permittedActions = DemiConversation.sessionActions(item);
    if (permittedActions.includes('Activate')) { const activate=document.createElement('button');activate.type='button';activate.textContent='Activate';activate.addEventListener('click',async()=>{leaveSessionPreview();const fresh=await action('activateSession',{session:item.name});renderSession(fresh);elements['sessions-dialog'].close();});buttons.append(activate); }
    if (permittedActions.includes('Extend')) { const cont=document.createElement('button');cont.type='button';cont.textContent='Extend';cont.title='Create a linked successor carrying this session summary and focus';cont.addEventListener('click',async()=>{if(!window.confirm(`Extend ${item.name} into a new linked session? Its summary and focus will be carried forward.`))return;leaveSessionPreview();const fresh=await action('continueSession',{session:item.name});renderSession(fresh);elements['sessions-dialog'].close();});buttons.append(cont); }
    row.append(buttons); fragment.append(row);
  }
  elements['sessions-list'].replaceChildren(fragment);
}

function jumpToEntry(entryId) {
  const domId = DemiConversation.stableDomId(entryId);
  let target = document.getElementById(domId);
  if (!target) {
    const entryIndex = renderedEntries.findIndex(entry => entry.id === entryId);
    if (entryIndex >= 0 && entryIndex < renderedStart) {
      followMessageTail = false;
      renderEntryWindow(renderedEntries, entryIndex);
      target = document.getElementById(domId);
    }
  }
  if (!target) return;
  followMessageTail = false;
  target.scrollIntoView({ behavior: 'smooth', block: 'center' });
  target.classList.remove('jump-highlight');
  void target.offsetWidth;
  target.classList.add('jump-highlight');
  target.tabIndex = -1;
  target.focus({ preventScroll: true });
  setTimeout(() => target.classList.remove('jump-highlight'), 1700);
  if (matchMedia('(max-width: 620px)').matches) closeMobileDrawers();
}

function closeMobileDrawers() {
  document.body.classList.remove('conversation-drawer-open', 'files-drawer-open', 'drawer-open');
  document.querySelector('.feature-menu')?.removeAttribute('open');
  elements['mobile-conversation'].setAttribute('aria-expanded', 'false');
  elements['mobile-files'].setAttribute('aria-expanded', 'false');
}

function toggleMobileDrawer(name) {
  const opening = !document.body.classList.contains(`${name}-drawer-open`);
  closeMobileDrawers();
  if (opening) {
    document.body.classList.add(`${name}-drawer-open`, 'drawer-open');
    elements[name === 'conversation' ? 'mobile-conversation' : 'mobile-files'].setAttribute('aria-expanded', 'true');
    if (name === 'files') {
      elements['session-files-toggle'].setAttribute('aria-expanded', 'true');
      elements['session-file-list'].hidden = false;
    }
  }
}

function conversationButton(entry, label, response = false) {
  const imageAttachment = String(entry?.type || '').toUpperCase() === 'GENERATED IMAGE'
    ? (entry.attachments || []).find(attachment => attachment?.image)
    : null;
  const button = document.createElement(imageAttachment ? 'a' : 'button');
  if (imageAttachment) {
    button.href = imageAttachment.url || `/api/attachment?path=${encodeURIComponent(imageAttachment.path)}`;
    button.target = '_blank';
    button.rel = 'noopener';
    button.title = `Open ${imageAttachment.name || 'generated image'}`;
  } else button.type = 'button';
  button.className = `conversation-item${response ? ' conversation-response' : ''}`;
  const appearance = participantAppearance(entry.author);
  if (appearance.color) button.style.setProperty('--agent-color', appearance.color);
  button.setAttribute('aria-label', `Go to ${appearance.name} entry ${entry.id}: ${label}`);
  const time = document.createElement('time');
  time.dateTime = entry.timestamp || '';
  time.textContent = localTime(entry.timestamp, false, true);
  const summary = document.createElement('span');
  summary.className = 'conversation-summary';
  summary.textContent = label;
  button.append(time, summary);
  if (!imageAttachment) button.addEventListener('click', () => jumpToEntry(entry.id));
  return button;
}

function renderConversation(entries) {
  let groups = DemiConversation.groupConversation(entries);
  // Keep navigation usable if an older helper is still resident during a live
  // server restart. The next reload will use the shared helper normally.
  if (!groups.length && (entries || []).some(entry => entry.author === 'Milo' && entry.body)) {
    groups = (entries || [])
      .filter(entry => entry.author === 'Milo' && entry.body &&
        !(['CONTINUE', 'STOP'].includes(String(entry.type || '').toUpperCase()) &&
          /^(?:continue the current discussion|stop the current agent discussion)/i.test(entry.body)))
      .map(statement => ({
        statement,
        summary: DemiConversation.summarizeStatement(statement.body),
        responses: (entries || []).filter(response =>
          (current?.agents || []).some(agent => agent.name === response.author) &&
          (response.metadata?.['Responding to'] === statement.id ||
            (response.metadata?.Round && response.metadata.Round === statement.metadata?.Round)))
      }));
  }
  if (preferences.conversationNewestFirst) groups = [...groups].reverse();
  elements['conversation-order'].textContent = preferences.conversationNewestFirst ? 'Newest first' : 'Oldest first';
  elements['conversation-order'].setAttribute('aria-pressed', String(preferences.conversationNewestFirst));
  const fragment = document.createDocumentFragment();
  for (const group of groups) {
    const section = document.createElement('section');
    section.className = 'conversation-group';
    section.append(conversationButton(group.statement, group.summary));
    if (group.responses.length) {
      const responses = document.createElement('div');
      responses.className = 'conversation-responses';
      for (const response of group.responses) {
        responses.append(conversationButton(response, participantAppearance(response.author).name, true));
      }
      section.append(responses);
    }
    fragment.append(section);
  }
  elements['conversation-list'].replaceChildren(fragment);
}

function renderSessionFiles(entries) {
  const files = DemiConversation.sessionFiles(entries);
  elements['session-file-count'].textContent = String(files.length);
  const fragment = document.createDocumentFragment();
  if (!files.length) {
    const empty = document.createElement('p');
    empty.className = 'session-files-empty';
    empty.textContent = 'No files created in this session.';
    fragment.append(empty);
  } else {
    for (const file of files) {
      const link = document.createElement('a');
      link.className = 'session-file';
      link.href = file.url || `/api/document?path=${encodeURIComponent(file.destination)}`;
      link.target = '_blank';
      link.rel = 'noopener';
      link.title = file.destination;
      const name = document.createElement('span');
      name.className = 'session-file-name';
      name.textContent = file.name;
      const details = document.createElement('span');
      details.className = 'session-file-details';
      details.textContent = `${file.generatedImage ? 'Generated image · ' : ''}${file.format} · ${localTime(file.timestamp)}`;
      link.append(name, details);
      fragment.append(link);
    }
  }
  elements['session-file-list'].replaceChildren(fragment);
}

function renderLiveClocks(now = Date.now()) {
  if (!current) return;
  if (current.parallelBatches?.length) {
    const batch = current.parallelBatches[0];
    elements['last-response'].textContent = `${batch.completed.length}/${batch.agents.length} independent ${batch.mode === 'review' ? 'reviews' : 'answers'} complete`;
    return updateActivityClock(now);
  }
  if (current.activeAction === 'review') {
    elements['last-response'].textContent = 'Blind reviews remain independent until comparison';
    return updateActivityClock(now);
  }
  const latest = current.latestResponse;
  elements['last-response'].textContent = latest
    ? `${compactViewport() ? '' : 'Last response: '}${latest.author} · ${DemiConversation.elapsedLabel(latest.timestamp, now)} ago`
    : 'Last response: none';
  updateActivityClock(now);
}

function activityText(snapshot, now = Date.now()) {
  if (snapshot?.parallelBatches?.length) {
    const batch = snapshot.parallelBatches[0];
    const elapsed = DemiConversation.elapsedLabel(batch.startedAt, now);
    const pending = batch.pending.length ? ` · waiting for ${batch.pending.join(', ')}` : batch.synthesize ? ' · synthesis phase' : '';
    return `Parallel ${batch.mode} · ${batch.completed.length}/${batch.agents.length} complete${pending} · ${elapsed}`;
  }
  if (snapshot?.activeAction === 'review') {
    const completed = snapshot.reviewProgress?.completed || [];
    const names = { claude: 'Claude', rowan: 'Rowan', gem: 'Gem' };
    const finished = completed.length ? ` · finished: ${completed.map(name => names[name] || name).join(', ')}` : '';
    const elapsed = snapshot.reviewProgress?.since ? ` · ${DemiConversation.elapsedLabel(snapshot.reviewProgress.since, now)}` : '';
    return `Blind /review running · ${completed.length}/3 reviewers complete${finished}${elapsed}`;
  }
  if (snapshot?.activeAction === 'draft') {
    return `Draft generation running · ${DemiConversation.elapsedLabel(snapshot.activeActionSince, now)}`;
  }
  if (!snapshot) return 'Connecting…';
  if (snapshot.state?.miloReviewPause?.active) return "Paused for Milo's review";
  const obligation = snapshot.pending;
  const dispatcher = snapshot.dispatcher || { state: 'inactive' };
  if (obligation) {
    const round = snapshot.state?.round || {};
    const sequence = Array.isArray(round.sequence) ? round.sequence : [];
    const synthesisAgents = Array.isArray(round.synthesisAgents) ? round.synthesisAgents : [];
    const isSynthesis = synthesisAgents.length > 0 && Number(round.sequenceIndex) >= sequence.length - synthesisAgents.length;
    const role = obligation.speaker === 'Rowan' ? 'editorial and prose review' : obligation.speaker === 'Gem' ? 'independent prose and technical review' : isSynthesis ? 'final synthesis' : obligation.speaker === sequence[0] ? 'writing proposal' : 'agent response';
    const stage = Array.isArray(round.sequence) ? ` · stage ${Number(round.sequenceIndex) + 1}/${round.sequence.length}` : '';
    const pendingText = `${obligation.speaker} pending · ${role}${stage} · ${DemiConversation.elapsedLabel(obligation.since, now)}`;
    if (!preferences.showDispatch) return pendingText;
    if (dispatcher.state === 'running') {
      return `${pendingText} · dispatcher running ${dispatcher.agent || obligation.speaker} (${dispatcher.for})`;
    }
    if (dispatcher.state === 'failed/retryable') {
      return `${pendingText} · dispatch failed/retryable ${dispatcher.for} ago`;
    }
    return `${pendingText} · dispatcher inactive`;
  }
  const acknowledgements = (snapshot.state?.acknowledgements || []).reduce((count, item) => count + (item.pending || []).length, 0);
  if (acknowledgements) return `${acknowledgements} acknowledgment${acknowledgements === 1 ? '' : 's'} pending`;
  if (dispatcher.state === 'running' && preferences.showDispatch) {
    return `No agent response pending · dispatcher running ${dispatcher.agent || 'agent'} (${dispatcher.for})`;
  }
  if (snapshot.state?.round?.status === 'waiting_for_milo') {
    return compactViewport() ? 'Waiting for you' : preferences.showDispatch ? 'Waiting for human · no agent pending · dispatcher inactive' : 'Waiting for human · no agent pending';
  }
  return `Next: ${snapshot.state?.round?.nextSpeaker || 'Milo'}`;
}

function compactActivityText(snapshot, now = Date.now()) {
  if (!snapshot) return 'Connecting…';
  if (snapshot.parallelBatches?.length) {
    const batch = snapshot.parallelBatches[0];
    const waiting = batch.pending?.[0] || `Parallel ${batch.mode || 'work'}`;
    return `${waiting} pending · ${DemiConversation.elapsedLabel(batch.startedAt, now)}`;
  }
  if (snapshot.activeAction === 'review') {
    return `Review running · ${DemiConversation.elapsedLabel(snapshot.reviewProgress?.since, now)}`;
  }
  if (snapshot.activeAction === 'draft') {
    return `Draft generation running · ${DemiConversation.elapsedLabel(snapshot.activeActionSince, now)}`;
  }
  if (snapshot.state?.miloReviewPause?.active) return 'Paused for your review';
  if (snapshot.pending) {
    const failed = snapshot.dispatcher?.state === 'failed/retryable' ? ' ⚠' : '';
    return `${snapshot.pending.speaker} pending · ${DemiConversation.elapsedLabel(snapshot.pending.since, now)}${failed}`;
  }
  const acknowledgements = (snapshot.state?.acknowledgements || []).reduce((count, item) => count + (item.pending || []).length, 0);
  if (acknowledgements) return `${acknowledgements} acknowledgment${acknowledgements === 1 ? '' : 's'} pending`;
  if (snapshot.dispatcher?.state === 'running') return `${snapshot.dispatcher.agent || 'Agent'} working · ${snapshot.dispatcher.for}`;
  if (snapshot.dispatcher?.state === 'failed/retryable') return 'Dispatch needs attention ⚠';
  if (snapshot.state?.round?.status === 'waiting_for_milo') return 'Waiting for you';
  return `Next: ${snapshot.state?.round?.nextSpeaker || 'you'}`;
}

function setActivityExpanded(expanded) {
  const show = Boolean(expanded);
  elements.activity.setAttribute('aria-expanded', String(show));
  elements['activity-details'].hidden = !show;
  elements['status-clocks'].classList.toggle('expanded', show);
}

function dispatcherParticipants(snapshot) {
  const round = snapshot.state?.round || {};
  const sequence = Array.isArray(round.sequence) ? round.sequence : [];
  const waiting = round.status === 'waiting_for_milo';
  const index = Math.max(0, Number(round.sequenceIndex) || 0);
  const completed = waiting ? sequence : sequence.slice(0, index);
  const currentAgent = snapshot.pending?.speaker || (!waiting ? sequence[index] : null);
  const next = waiting ? [] : sequence.slice(index + (currentAgent ? 1 : 0));
  return { completed, currentAgent, next };
}

function dispatcherEventLabel(entry) {
  const type = String(entry?.type || '').toUpperCase();
  if (!entry) return '';
  if (type.includes('QUESTION') || entry.author === 'Milo' || entry.author === 'Alice') return `Question received from ${entry.author}`;
  if (type.includes('SKIPPED')) return `${entry.author || 'Agent'} was skipped`;
  if (type.includes('ERROR') || type.includes('FAILED')) return `${entry.author || 'Agent'} reported a problem`;
  if (type.includes('RESPONSE') || type === 'SYNTHESIS') return `${entry.author} response saved`;
  return `${entry.author || 'Demi'} · ${String(entry.type || 'update').toLowerCase()}`;
}

function addDispatcherField(list, label, value) {
  if (!value) return;
  const row = document.createElement('div'); row.className = 'dispatcher-field';
  const term = document.createElement('dt'); term.textContent = label;
  const description = document.createElement('dd'); description.textContent = value;
  row.append(term, description); list.append(row);
}

function dispatcherAction(label, actionName, payload = {}, kind = 'secondary') {
  const button = document.createElement('button');
  button.type = 'button'; button.className = kind; button.textContent = label;
  button.addEventListener('click', async () => {
    button.disabled = true;
    try { await action(actionName, payload); }
    catch {} finally { button.disabled = false; }
  });
  return button;
}

function renderDispatcherPanel(snapshot, now = Date.now()) {
  const panel = elements['activity-details'];
  const diagnosticsWasOpen = panel.querySelector('details')?.open === true;
  panel.replaceChildren();
  const round = snapshot.state?.round || {};
  const dispatcher = snapshot.dispatcher || { state: 'inactive' };
  const batch = snapshot.parallelBatches?.[0];
  const participants = dispatcherParticipants(snapshot);
  const heading = document.createElement('div'); heading.className = 'dispatcher-panel-heading';
  const headingText = document.createElement('div');
  const title = document.createElement('strong'); title.textContent = 'Dispatcher activity';
  const plainStatus = document.createElement('span');
  plainStatus.textContent = batch
    ? batch.pending?.length ? `Calling ${batch.pending.join(', ')} independently.` : 'Independent responses are being collected.'
    : snapshot.activeAction === 'review' ? 'Independent reviews are being collected.'
      : snapshot.activeAction === 'draft' ? 'The drafting agent is generating the document.'
      : snapshot.pending && dispatcher.state === 'running' ? `Calling ${snapshot.pending.speaker} now.`
        : snapshot.pending && dispatcher.state === 'failed/retryable' ? `${snapshot.pending.speaker} could not complete the response. Nothing was cancelled.`
          : snapshot.pending ? `${snapshot.pending.speaker} is next, but the dispatcher is not running. Nothing was cancelled.`
            : round.status === 'waiting_for_milo' ? 'The agents have finished. Demi is waiting for you.'
              : 'No agent is currently working.';
  headingText.append(title, plainStatus);
  const collapse = document.createElement('button'); collapse.type = 'button'; collapse.className = 'dispatcher-collapse'; collapse.textContent = 'Collapse'; collapse.addEventListener('click', () => setActivityExpanded(false));
  heading.append(headingText, collapse); panel.append(heading);

  const facts = document.createElement('dl'); facts.className = 'dispatcher-facts';
  const workflow = batch ? `Parallel ${batch.mode || 'questions'}` : snapshot.activeAction === 'review' ? 'Independent review' : snapshot.activeAction === 'draft' ? 'Document draft' : snapshot.state?.directTurn?.active ? 'Direct question' : round.id ? 'Collaboration round' : 'Idle';
  const openedBy = batch?.requestEntry || snapshot.state?.directTurn?.openedBy || round.openedBy;
  const requestEntry = (snapshot.entries || []).find(entry => entry.id === openedBy);
  addDispatcherField(facts, 'Current task', workflow);
  addDispatcherField(facts, 'Question from', requestEntry?.author || (openedBy ? 'Human participant' : ''));
  addDispatcherField(facts, 'Working now', batch?.pending?.join(', ') || snapshot.pending?.speaker || (snapshot.activeAction === 'review' ? 'Reviewers' : snapshot.activeAction === 'draft' ? 'Drafting agent' : ''));
  addDispatcherField(facts, 'Completed', batch?.completed?.join(', ') || participants.completed.join(', '));
  addDispatcherField(facts, 'Next', participants.next.join(', ') || (round.status === 'waiting_for_milo' ? 'You' : ''));
  addDispatcherField(facts, 'Started', batch?.startedAt ? `${DemiConversation.elapsedLabel(batch.startedAt, now)} ago` : snapshot.activeActionSince ? `${DemiConversation.elapsedLabel(snapshot.activeActionSince, now)} ago` : snapshot.pending?.since ? `${DemiConversation.elapsedLabel(snapshot.pending.since, now)} ago` : '');
  panel.append(facts);

  const actions = document.createElement('div'); actions.className = 'dispatcher-actions';
  if (batch) {
    for (const agent of batch.pending || []) actions.append(dispatcherAction(`Skip ${agent}`, 'stopParallelAgent', { agent }));
    for (const failure of batch.failures || []) actions.append(dispatcherAction(`Retry ${failure.agent}`, 'retryParallelAgent', { agent: failure.agent }));
  } else if (snapshot.pending && dispatcher.state !== 'running') {
    actions.append(dispatcherAction(`Retry ${snapshot.pending.speaker}`, 'restartDispatcher'));
  }
  const workActive = Boolean(snapshot.activeAction || snapshot.pending || snapshot.parallelBatches?.length || dispatcher.state === 'running');
  if (workActive) actions.append(dispatcherAction('End round', 'stop', {}, 'secondary danger'));
  if (actions.childElementCount) panel.append(actions);

  const recent = (snapshot.entries || []).slice(-8).filter(entry => dispatcherEventLabel(entry)).slice(-5);
  if (recent.length) {
    const events = document.createElement('section'); events.className = 'dispatcher-events';
    const eventHeading = document.createElement('strong'); eventHeading.textContent = 'Recent activity'; events.append(eventHeading);
    const list = document.createElement('ol');
    for (const entry of recent) {
      const item = document.createElement('li');
      const time = document.createElement('time');
      const stamp = new Date(entry.timestamp); time.textContent = Number.isNaN(stamp.getTime()) ? '' : stamp.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      const text = document.createElement('span'); text.textContent = dispatcherEventLabel(entry);
      item.append(time, text); list.append(item);
    }
    events.append(list); panel.append(events);
  }

  const diagnostics = document.createElement('details'); diagnostics.className = 'dispatcher-diagnostics'; diagnostics.open = diagnosticsWasOpen;
  const summary = document.createElement('summary'); summary.textContent = 'Diagnostics';
  const code = document.createElement('pre'); code.textContent = [
    `Round: ${round.id || 'none'} (${round.status || 'inactive'})`,
    `Dispatcher: ${dispatcher.state}${dispatcher.agent ? ` · ${dispatcher.agent}` : ''}`,
    `Pending: ${snapshot.pending?.speaker || 'none'}`,
    `Sequence position: ${Number.isInteger(Number(round.sequenceIndex)) ? Number(round.sequenceIndex) + 1 : 'n/a'} / ${Array.isArray(round.sequence) ? round.sequence.length : 0}`,
    `Responses remaining: ${round.remainingResponses ?? 'n/a'}`,
    dispatcher.failure ? `Failure: ${dispatcher.failure}` : ''
  ].filter(Boolean).join('\n');
  diagnostics.append(summary, code); panel.append(diagnostics);
}

function updateActivityClock(now = Date.now()) {
  if (!current) return;
  elements.activity.hidden = !preferences.showStatus;
  elements.activity.textContent = compactActivityText(current, now);
  if (elements.activity.getAttribute('aria-expanded') === 'true') renderDispatcherPanel(current, now);
  const workActive = Boolean(current.activeAction || current.pending || current.parallelBatches?.length || current.dispatcher?.state === 'running');
  elements.stop.hidden = !workActive;
  elements.activity.classList.toggle('has-error', current.dispatcher?.state === 'failed/retryable');
}

function updateStatus(snapshot) {
  if (!snapshot) return;
  current = {
    ...(current || {}), ...snapshot,
    entries: snapshot.entries || current?.entries || [],
    latestResponse: snapshot.latestResponse === undefined ? current?.latestResponse : snapshot.latestResponse
  };
  presenceSupported = Boolean(current.agentPresence);
  updateConnectionLabel();
  renderSecuritySettings();
  elements.connection.className = 'connection online';
  elements['session-name'].textContent = snapshot.state?.currentSession || 'Shared collaboration';
  maybePromptDispatcherRestart(current);
  const capacity = snapshot.sessionCapacity || current.sessionCapacity;
  if (capacity) {
    const bounded = Number.isFinite(capacity.limit) && Number.isFinite(capacity.percent);
    elements['session-capacity-fill'].style.width = bounded ? `${capacity.percent}%` : '0%';
    elements['session-capacity'].dataset.mode = bounded ? 'files' : 'database';
    elements['session-capacity'].dataset.level = bounded && capacity.full ? 'full' : bounded && capacity.percent >= 90 ? 'danger' : bounded && capacity.percent >= 75 ? 'warning' : 'normal';
    elements['session-capacity-label'].textContent = bounded
      ? `${capacity.percent}%`
      : '';
    elements['session-capacity'].title = bounded
      ? `${capacity.percent}% of session capacity · ${Math.max(0,Math.round((capacity.limit-capacity.bytes)/1024)).toLocaleString()} KB remaining`
      : 'Database-backed session with no file-size limit';
  }
  renderSessionCatalog(snapshot.sessions || current.sessions || []);
  renderProjectLinks(current.projectLinks);
  renderAgentPresence(current.agentPresence || {});
  renderLiveClocks();
  if (snapshot.error) showNotice(snapshot.error, false);
}

function renderProjectLinks(configuration) {
  const label = elements['project-links-label'];
  const panel = elements['project-links-panel'];
  if (!label || !panel) return;
  label.textContent = configuration?.menuLabel || 'Project links';
  panel.setAttribute('aria-label', label.textContent);
  panel.replaceChildren();
  const setup = document.createElement('button');
  setup.type = 'button'; setup.className = 'feature-card project-setup-card';
  const setupCategory = document.createElement('span'); setupCategory.className = 'feature-kicker'; setupCategory.textContent = 'Project';
  const setupTitle = document.createElement('strong'); setupTitle.textContent = current?.project?.name || 'Project setup';
  const setupDescription = document.createElement('span'); setupDescription.textContent = 'Edit the shared briefing supplied to every agent.';
  setup.append(setupCategory, setupTitle, setupDescription);
  setup.addEventListener('click', () => { document.querySelector('.feature-menu')?.removeAttribute('open'); openProjectDialog(); });
  panel.append(setup);
  const links = configuration?.links || [];
  if (!links.length && !current?.connectionUrl) {
    const empty = document.createElement('span');
    empty.className = 'feature-empty';
    empty.textContent = 'No project links are configured.';
    panel.append(empty);
  }
  for (const item of links) {
    const card = document.createElement('a');
    card.className = 'feature-card';
    const remoteTarget = /^https?:\/\//i.test(item.target);
    card.href = remoteTarget ? item.target : `/${String(item.target).replace(/^\/+/, '')}`;
    if (remoteTarget) {
      card.target = '_blank';
      card.rel = 'noopener';
    } else {
      card.addEventListener('click', event => {
        event.preventDefault();
        window.location.assign(card.href);
      });
    }
    if (item.category) {
      const category = document.createElement('span');
      category.className = 'feature-kicker';
      category.textContent = item.category;
      card.append(category);
    }
    const title = document.createElement('strong'); title.textContent = item.label; card.append(title);
    if (item.description) { const description = document.createElement('span'); description.textContent = item.description; card.append(description); }
    panel.append(card);
  }
  if (current?.connectionUrl) {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'feature-card connection-qr-card';
    const category = document.createElement('span'); category.className = 'feature-kicker'; category.textContent = 'Connect';
    const title = document.createElement('strong'); title.textContent = 'Phone QR code';
    const description = document.createElement('span'); description.textContent = 'Scan to open this Demi on the home network.';
    card.append(category, title, description);
    card.addEventListener('click', () => {
      if (typeof QRCode !== 'function') return showNotice('The local QR-code component could not be loaded.');
      elements['connection-qr'].replaceChildren();
      elements['connection-qr-url'].textContent = current.connectionUrl;
      new QRCode(elements['connection-qr'], { text: current.connectionUrl, width: 256, height: 256, colorDark: '#000000', colorLight: '#ffffff', correctLevel: QRCode.CorrectLevel.M });
      document.querySelector('.feature-menu')?.removeAttribute('open');
      elements['connection-qr-dialog'].showModal();
    });
    panel.append(card);
  }
  for (const [label, description, target] of [
    ['Draft', 'Create a document draft.', 'draft-button'],
    ['People & Agents', 'Configure participants and models.', 'agents-button'],
    ['Sessions', 'Open, extend, or activate a session.', 'sessions-button'],
    ['New Session', 'Start a separate new session.', 'new-session'],
    ['Display', 'Change theme, detail, and message size.', 'settings-button']
  ]) {
    const card = document.createElement('button'); card.type = 'button'; card.className = 'feature-card mobile-tool-card';
    const category = document.createElement('span'); category.className = 'feature-kicker'; category.textContent = 'Demi';
    const title = document.createElement('strong'); title.textContent = label;
    const detail = document.createElement('span'); detail.textContent = description;
    card.append(category, title, detail);
    card.addEventListener('click', () => { document.querySelector('.feature-menu')?.removeAttribute('open'); elements[target].click(); });
    panel.append(card);
  }
}

function openProjectDialog() {
  const project = current?.project || {};
  elements['project-name'].value = project.name || '';
  elements['project-description'].value = project.description || '';
  elements['project-goals'].value = project.goals || '';
  elements['project-authority'].value = project.authority || '';
  elements['project-instructions'].value = project.sharedInstructions || '';
  elements['project-sources'].value = (project.sourceFiles || []).join('\n');
  elements['project-form-status'].textContent = '';
  elements['project-dialog'].showModal();
}

async function saveProjectForm(event) {
  event.preventDefault();
  const button = event.submitter;
  try {
    if (button) button.disabled = true;
    elements['project-form-status'].textContent = 'Saving…';
    const result = await action('saveProject', { name: elements['project-name'].value, description: elements['project-description'].value,
      goals: elements['project-goals'].value, authority: elements['project-authority'].value,
      sharedInstructions: elements['project-instructions'].value, sourceFiles: elements['project-sources'].value });
    current.project = result.result?.project || result.project || current.project;
    renderProjectLinks(current.projectLinks);
    elements['project-form-status'].textContent = '';
    elements['project-dialog'].close();
    showNotice('Project briefing saved.');
  } catch {} finally { if (button) button.disabled = false; }
}

function storagePayload() {
  return { host: elements['storage-host'].value, port: Number(elements['storage-port'].value), database: elements['storage-database'].value,
    adminUser: elements['storage-admin'].value, schema: elements['storage-schema'].value, ownerRole: elements['storage-owner'].value,
    applicationUser: elements['storage-user'].value, fallback: elements['storage-fallback'].checked ? 'files' : 'none',
    exportMarkdownTranscripts: elements['storage-export'].checked };
}

function renderStorageSetup(setup) {
  const database = setup.database || {}; const storage = setup.storage || {};
  elements['storage-host'].value = database.host || '127.0.0.1'; elements['storage-port'].value = database.port || 5432;
  elements['storage-database'].value = database.database || 'demi'; elements['storage-admin'].value = database.adminUser || 'postgres';
  elements['storage-schema'].value = database.schema || 'demi'; elements['storage-owner'].value = database.ownerRole || 'demi_owner';
  elements['storage-user'].value = database.applicationUser || 'demi_app'; elements['storage-fallback'].checked = storage.fallback === 'files';
  elements['storage-export'].checked = storage.exportMarkdownTranscripts !== false;
  elements['storage-current'].textContent = `Currently using ${storage.backend === 'postgresql' ? 'PostgreSQL' : 'files'}${setup.health?.healthy ? ` · connected to ${setup.health.database} as ${setup.health.user}` : ''}.`;
  elements['storage-output'].textContent = setup.health?.error || 'Settings can be saved without switching storage modes.';
  for (const button of elements['storage-form'].querySelectorAll('button:not(#close-storage)')) button.disabled = !providerConfigurationAllowed();
}

async function openStorageDialog() {
  elements['project-dialog'].close(); elements['storage-output'].textContent = 'Loading storage settings…'; elements['storage-dialog'].showModal();
  try { const result = await action('storageSetup'); renderStorageSetup(result.result || result); }
  catch (error) { elements['storage-output'].textContent = error.message; }
}

async function runStorageAction(name, button, confirmation) {
  if (confirmation && !confirm(confirmation)) return;
  const buttons = [...elements['storage-form'].querySelectorAll('button')];
  try {
    buttons.forEach(item => { item.disabled = true; }); elements['storage-output'].textContent = `${button.textContent}…`;
    const result = await action(name, storagePayload()); const value = result.result || result;
    elements['storage-output'].textContent = value.message || value.output || JSON.stringify(value, null, 2);
    if (value.setup) renderStorageSetup(value.setup); else if (value.storage) renderStorageSetup(value);
    if (value.restartRequired) showNotice('Storage changed. Restart Demi after finishing any current work so every process uses the new backend.');
  } catch (error) { elements['storage-output'].textContent = error.message; }
  finally { buttons.forEach(item => { item.disabled = !providerConfigurationAllowed(); }); elements['close-storage'].disabled = false; }
}

function maybePromptDispatcherRestart(snapshot) {
  const pending = snapshot?.pending;
  const dispatcher = snapshot?.dispatcher;
  if (!pending || dispatcher?.state === 'running' || snapshot?.activeAction || snapshot?.state?.miloReviewPause?.active) return;
  // Sequential runs briefly release the per-agent dispatcher lock while moving
  // to the next speaker. Do not mistake that normal handoff for a stalled run.
  if (dispatcher?.state !== 'failed/retryable' && Number(pending.elapsedMs || 0) < 10000) return;
  const round = snapshot.state?.round || {};
  const key = [snapshot.state?.currentSession, round.id, round.sequenceIndex, pending.speaker, snapshot.state?.lastEntry].join('|');
  if (sessionStorage.getItem('demi-dispatcher-restart-prompt') === key || dispatcherRestartPromptActive) return;
  sessionStorage.setItem('demi-dispatcher-restart-prompt', key);
  const detail = dispatcher?.state === 'failed/retryable' ? 'The last automatic dispatch failed.' : 'The dispatcher is not running.';
  setActivityExpanded(true);
  renderDispatcherPanel(snapshot);
  showNotice(`${detail} ${pending.speaker} is waiting; nothing was cancelled. Use Dispatcher activity to retry, end the round, or inspect details.`);
}

function renderAgentPresence(presence) {
  const agents = current?.agents || [];
  const list = elements['agent-presence-list'];
  list.replaceChildren();
  const latestName = current?.latestResponse?.author;
  const latestAgent = agents.find(agent => agent.name === latestName);
  elements['mobile-agent-icon'].textContent = latestAgent?.icon || '●';
  elements['mobile-agent-icon'].style.color = latestAgent?.color || '';
  elements['mobile-agent-name'].textContent = latestAgent?.name || 'Agents';
  elements['mobile-agent-name'].style.color = latestAgent?.color || '';
  elements['mobile-agent-menu'].setAttribute('aria-label', latestAgent ? `Open agents menu. Last response from ${latestAgent.name}.` : 'Open agents menu');
  elements['mobile-agent-menu'].title = latestAgent ? `Agents · Last response: ${latestAgent.name}` : 'Agents';
  for (const agent of agents) {
    const button = document.createElement('button');
    button.className = 'agent-presence-button'; button.type = 'button'; button.style.color = agent.color; button.dataset.agent = agent.name;
    const connection = ['HTTP','Image'].includes(agent.kind) ? { key: 'api', label: 'API' } : agent.kind === 'Ollama' ? { key: 'local', label: 'Local' } : { key: 'subscription', label: 'Subscription' };
    button.dataset.connection = connection.key;
    const avatar = document.createElement('span'); avatar.className = 'agent-avatar'; avatar.ariaHidden = 'true'; avatar.textContent = agent.icon;
    const name = document.createElement('span'); name.className = 'agent-name'; name.textContent = agent.name;
    const state = document.createElement('span'); state.className = 'agent-state'; state.ariaHidden = 'true';
    const availability = document.createElement('span'); availability.className = 'agent-availability';
    button.append(avatar,name,state,availability);
    if (agent.kind === 'Image') button.addEventListener('click',()=>{ elements.composer.value = `/${agent.handle} `; elements.composer.focus(); resizeComposer(); document.querySelector('.agent-presence-menu')?.removeAttribute('open'); });
    else button.addEventListener('click',()=>{ document.querySelector('.agent-presence-menu')?.removeAttribute('open'); checkIn(agent.name); });
    list.append(button);
    const item = presence[agent.name] || { state: 'idle' };
    button.dataset.state = item.state || 'idle';
    button.querySelector('.agent-availability').textContent = item.resetHint || (item.reason === 'usage limit' ? 'Usage limit reached' : '');
    const labels = { idle: 'No current status', thinking: 'Thinking', responded: 'Response returned', online: 'Online and responding', offline: 'No positive response' };
    const providers = { Claude: 'Anthropic subscription', Codex: 'OpenAI subscription', Antigravity: 'Google Antigravity', Ollama: 'Ollama local', Image: `${agent.imageProvider || 'Replicate'} image generation` };
    const provider = agent.kind === 'HTTP'
      ? `${agent.httpProvider ? agent.httpProvider[0].toUpperCase() + agent.httpProvider.slice(1) : 'Custom'} API`
      : providers[agent.kind] || agent.kind || 'Unspecified';
    const model = agent.model || 'Provider default';
    const providerTitle = `Provider: ${provider}\nModel: ${model}`;
    const presenceTitle = agent.kind === 'Image' ? `${providerTitle}\nClick to start an image request. Every generation requires cost confirmation.` : presenceSupported
      ? `${providerTitle}\n${connection.label} connection · Check in with ${agent.name} · ${labels[item.state] || item.state}${item.reason ? ` · ${item.reason}` : ''}${item.resetHint ? ` · ${item.resetHint}` : ''}`
      : `${providerTitle}\nRestart Demi web to enable agent check-ins`;
    const cachedCredit = agentCreditCache.get(agent.handle);
    button.title = `${presenceTitle}${agent.kind === 'HTTP' ? `\n${cachedCredit?.label || 'Credits: hover to check'}` : ''}`;
    button.setAttribute('aria-label', button.title);
    if (agent.kind === 'HTTP') button.addEventListener('mouseenter', () => refreshAgentCredits(agent, button, presenceTitle), { once: true });
  }
  elements['checkin-all'].hidden = agents.length === 0;
  elements['checkin-all'].title = presenceSupported ? 'Privately check in with all configured agents' : 'Restart Demi web to enable agent check-ins';
}

async function refreshAgentCredits(agent, button, presenceTitle) {
  const cached = agentCreditCache.get(agent.handle);
  if (cached && Date.now() - cached.checkedAt < 300000) {
    button.title = `${presenceTitle}\n${cached.label}`;
    button.setAttribute('aria-label', button.title);
    return;
  }
  button.title = `${presenceTitle}\nCredits: checking…`;
  try {
    const response = await action('agentCredits', { handle: agent.handle }, { quiet: true, timeoutMs: 10000 });
    const credit = response.result || {};
    const record = { label: credit.label || 'Credits: unavailable', checkedAt: Date.now() };
    agentCreditCache.set(agent.handle, record);
    button.title = `${presenceTitle}\n${record.label}`;
  } catch {
    button.title = `${presenceTitle}\nCredits: could not be checked`;
  }
  button.setAttribute('aria-label', button.title);
}

function renderHumans() {
  const list = elements['humans-list']; list.replaceChildren();
  const active = selectedHuman();
  for (const human of current?.humans || []) {
    const row = document.createElement('form'); row.className = 'human-card';
    const isActive = active?.id === human.id;
    if (isActive) { row.classList.add('active-human'); row.setAttribute('aria-current', 'true'); }
    row.style.setProperty('--human-color', human.color);
    const swatch = document.createElement('span'); swatch.className = 'human-swatch'; swatch.style.background = human.color;
    const nameLabel = document.createElement('label'); nameLabel.textContent = 'Display name';
    const name = document.createElement('input'); name.value = human.displayName; name.maxLength = 60; name.required = true; nameLabel.append(name);
    const colorLabel = document.createElement('label'); colorLabel.textContent = 'Color';
    const color = document.createElement('input'); color.type = 'color'; color.value = human.color; colorLabel.append(color);
    color.addEventListener('input', () => { swatch.style.background = color.value; });
    const authenticated = current?.authenticatedHumanId === human.id || !human.passwordProtected;
    const details = document.createElement('span'); details.className = 'human-role'; details.textContent = `${human.canSetCanon ? 'Project owner · canon authority' : human.role}${human.passwordProtected ? ' · Password protected' : ' · No password'}${isActive ? authenticated ? ' · Acting as you' : ' · Sign-in required' : ''}`;
    const save = document.createElement('button'); save.type = 'submit'; save.className = 'secondary'; save.textContent = 'Save';
    save.hidden = !current?.canConfigureProviders;
    const controls = document.createElement('span'); controls.className = 'human-card-actions'; controls.append(save);
    if (!isActive) {
      const choose = document.createElement('button'); choose.type = 'button'; choose.className = 'secondary human-switch'; choose.textContent = 'Switch';
      choose.addEventListener('click', async () => { try { const selected = await selectHumanIdentity(human.id); if (selected) showNotice(`You are now identified as ${selected.displayName} on this browser.`); } catch (error) { showNotice(error.message); } });
      controls.append(choose);
    }
    if (current?.canConfigureProviders && (current?.humans || []).length > 1) {
      const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'secondary danger'; remove.textContent = 'Delete';
      remove.addEventListener('click', async () => {
        if (!confirm(`Delete ${human.displayName} from Demi? Existing transcript entries will keep their original name.`)) return;
        try {
          remove.disabled = true; remove.textContent = 'Deleting…';
          const response = await action('deleteHuman', { id: human.id });
          current.humans = response.result?.humans || current.humans;
          if (humanIdentityId === human.id) {
            current.authenticatedHumanId = null;
            const replacement = current.humans[0] || null;
            humanIdentityId = replacement?.id || '';
            if (humanIdentityId) localStorage.setItem('demi-human-identity', humanIdentityId); else localStorage.removeItem('demi-human-identity');
            if (replacement?.passwordProtected) openIdentityDialog(replacement);
            else if (replacement) await authenticateHumanIdentity(replacement);
          }
          renderHumans(); updateConnectionLabel(); renderSession(current);
          showNotice(`${human.displayName} was removed.${response.result?.humans?.some(item => item.canSetCanon && item.id !== human.id) ? '' : ' Canon authority was preserved on the remaining owner.'}`);
        } catch (error) { showNotice(error.message); }
        finally { remove.disabled = false; remove.textContent = 'Delete'; }
      });
      controls.append(remove);
    }
    row.append(swatch, nameLabel, colorLabel, details, controls);
    let password = null, clearPassword = null;
    if (current?.canConfigureProviders) {
      const security = document.createElement('div'); security.className = 'human-security';
      const passwordLabel = document.createElement('label'); passwordLabel.textContent = human.passwordProtected ? 'New password or PIN (blank keeps the current one)' : 'Optional password or PIN';
      password = document.createElement('input'); password.type = 'password'; password.minLength = 4; password.maxLength = 128; password.autocomplete = 'new-password'; passwordLabel.append(password);
      const clearLabel = document.createElement('label'); clearLabel.className = 'human-clear-password';
      clearPassword = document.createElement('input'); clearPassword.type = 'checkbox'; clearPassword.disabled = !human.passwordProtected;
      clearLabel.append(clearPassword, document.createTextNode(' Remove password protection'));
      security.append(passwordLabel, clearLabel); row.append(security);
    }
    row.addEventListener('submit', async event => { event.preventDefault(); try { save.textContent = 'Saving…'; const passwordChanged = Boolean(password?.value) || clearPassword?.checked === true; await action('saveHuman', { id: human.id, displayName: name.value, color: color.value, newPassword: password?.value || '', clearPassword: clearPassword?.checked === true }); if (passwordChanged && current.authenticatedHumanId === human.id) current.authenticatedHumanId = null; const fresh = await action('status'); updateStatus(fresh); renderHumans(); renderSession(current); showNotice(`${name.value}’s display and security settings were updated.${password?.value ? ' Sign in again with the new password.' : ''}`); } catch {} finally { save.textContent = 'Save'; } });
    list.append(row);
  }
}

function openHumanForm() {
  elements['human-form'].reset();
  elements['human-color'].value = '#6fa8dc'; elements['human-role'].value = 'contributor'; elements['human-switch'].checked = true;
  elements['human-form-status'].textContent = '';
  elements['human-dialog'].showModal();
  elements['human-name'].focus();
}

async function createHumanProfile(event) {
  event.preventDefault(); const button = event.submitter || elements['save-human'];
  try {
    button.disabled = true; button.textContent = 'Adding…'; elements['human-form-status'].textContent = '';
    const response = await action('createHuman', { displayName: elements['human-name'].value, color: elements['human-color'].value,
      role: elements['human-role'].value, canSetCanon: elements['human-canon'].checked, newPassword: elements['human-password'].value });
    const created = response.result?.human; current.humans = response.result?.humans || current.humans;
    renderHumans(); elements['human-dialog'].close();
    if (created && elements['human-switch'].checked) {
      const selected = await selectHumanIdentity(created.id);
      if (selected) showNotice(`${selected.displayName} was added and is now the active identity.`);
    } else showNotice(`${created?.displayName || elements['human-name'].value} was added.`);
  } catch (error) { elements['human-form-status'].textContent = error.message; }
  finally { button.disabled = false; button.textContent = 'Add person'; }
}

function renderSecuritySettings() {
  const pairing = current?.security?.requireLanPairing !== false;
  elements['require-lan-pairing'].checked = pairing;
  elements['require-lan-pairing'].disabled = !current?.canConfigureProviders;
  elements['security-form'].querySelector('button').hidden = !current?.canConfigureProviders;
  elements['security-warning'].textContent = pairing
    ? 'Recommended. New home-network devices must enter a temporary pairing code once.'
    : 'Pairing is disabled. Any device on this network can open Demi; protected identities still require their own password.';
  elements['security-warning'].classList.toggle('danger-text', !pairing);
}

function renderAgents() {
  const catalog = current?.agentCatalog || current?.agents || [];
  const list = elements['agents-list'];
  list.replaceChildren();
  if (!catalog.length) {
    const empty = document.createElement('div'); empty.className = 'agents-empty';
    empty.innerHTML = '<strong>No agents configured yet.</strong><span>Add a collaborator when you are ready. Demi itself will still open and preserve sessions without one.</span>';
    list.append(empty); return;
  }
  for (const agent of catalog) {
    const card = document.createElement('article'); card.className = 'agent-card'; card.draggable = true; card.dataset.handle = agent.handle; card.style.setProperty('--agent-card-color', agent.color); if (!agent.enabled) card.classList.add('disabled');
    const drag = document.createElement('span'); drag.className = 'agent-drag-handle'; drag.textContent = '⋮⋮'; drag.title = 'Drag to change workflow order'; drag.setAttribute('aria-hidden', 'true');
    const avatar = document.createElement('span'); avatar.className = 'agent-card-avatar'; avatar.style.color = agent.color; avatar.textContent = agent.icon;
    const info = document.createElement('div'); info.className = 'agent-card-info';
    const heading = document.createElement('div'); heading.className = 'agent-card-heading';
    const name = document.createElement('strong'); name.textContent = agent.name;
    const command = document.createElement('code'); command.textContent = `/${agent.handle}`;
    heading.append(name, command);
    const description = document.createElement('span'); description.textContent = `${agent.kind}${agent.model ? ` · ${agent.model}` : ''} · ${agent.participationMode === 'automatic' ? 'Every round' : 'By invitation'}${agent.synthesisEnabled ? ' · Synthesizer' : ''}`;
    const role = document.createElement('span'); role.textContent = agent.role || 'No role description yet.';
    info.append(heading, description, role);
    const controls = document.createElement('div'); controls.className = 'agent-card-actions';
    const edit = document.createElement('button'); edit.type = 'button'; edit.className = 'secondary'; edit.textContent = 'Edit'; edit.addEventListener('click', () => openAgentForm(agent));
    const test = document.createElement('button'); test.type = 'button'; test.className = 'secondary'; test.textContent = 'Test'; test.disabled = !agent.enabled || agent.kind === 'Image'; test.addEventListener('click', async () => { try { test.textContent = 'Testing…'; const result = await action('testAgent', { handle: agent.handle }); const check = result.result?.check || result.check; showNotice(check?.online ? `${agent.name} responded successfully.` : `${agent.name} did not respond: ${check?.reason || 'no positive response'}`); } catch {} finally { test.textContent = 'Test'; } });
    const toggle = document.createElement('button'); toggle.type = 'button'; toggle.className = agent.enabled ? 'secondary danger' : 'secondary'; toggle.textContent = agent.enabled ? 'Disable' : 'Enable'; toggle.addEventListener('click', async () => { try { const result = await action('setAgentEnabled', { handle: agent.handle, enabled: !agent.enabled }); current.agentCatalog = result.result?.agents || result.agents || current.agentCatalog; const fresh = await action('status'); updateStatus(fresh); renderAgents(); } catch {} });
    controls.append(edit, test, toggle); card.append(drag, avatar, info, controls);
    card.addEventListener('dragstart', event => { card.classList.add('dragging'); event.dataTransfer.effectAllowed = 'move'; event.dataTransfer.setData('text/plain', agent.handle); });
    card.addEventListener('dragend', () => { card.classList.remove('dragging'); for (const item of list.children) item.classList.remove('drag-over'); });
    card.addEventListener('dragover', event => { event.preventDefault(); if (!card.classList.contains('dragging')) card.classList.add('drag-over'); event.dataTransfer.dropEffect = 'move'; });
    card.addEventListener('dragleave', () => card.classList.remove('drag-over'));
    card.addEventListener('drop', async event => {
      event.preventDefault(); card.classList.remove('drag-over');
      const source = list.querySelector(`[data-handle="${CSS.escape(event.dataTransfer.getData('text/plain'))}"]`);
      if (!source || source === card) return;
      const bounds = card.getBoundingClientRect();
      list.insertBefore(source, event.clientY < bounds.top + bounds.height / 2 ? card : card.nextSibling);
      const handles = [...list.querySelectorAll('.agent-card')].map(item => item.dataset.handle);
      try { const result = await action('reorderAgents', { handles }); current.agentCatalog = result.result?.agents || result.agents || current.agentCatalog; current.agents = current.agentCatalog.filter(item => item.enabled !== false); renderAgents(); renderAgentPresence(current.agentPresence || {}); showNotice('Agent workflow order updated.'); }
      catch { const fresh = await action('status'); updateStatus(fresh); renderAgents(); }
    });
    list.append(card);
  }
}

function openAgentForm(agent = null) {
  const form = elements['agent-form']; form.hidden = false;
  elements['agents-dialog'].classList.add('editing-agent');
  elements['agent-form-title'].textContent = agent ? `Edit ${agent.name}` : 'Add agent';
  elements['agent-original-handle'].value = agent?.handle || '';
  elements['agent-name'].value = agent?.name || '';
  elements['agent-handle'].value = agent?.handle || '';
  elements['agent-kind'].value = agent?.kind || 'Ollama';
  elements['agent-model'].value = agent?.model || '';
  elements['agent-image-provider'].value = agent?.imageProvider || 'replicate';
  elements['agent-image-resolution'].value = agent?.imageResolution || '2K';
  elements['agent-image-api-key'].value = '';
  elements['agent-image-api-key'].placeholder = agent?.hasImageApiKey ? 'Saved — leave blank to keep it' : 'Paste the provider API key';
  elements['agent-http-provider'].value = agent?.httpProvider || 'openai';
  elements['agent-api-style'].value = agent?.apiStyle || 'openai-responses';
  elements['agent-base-url'].value = agent?.baseUrl || '';
  elements['agent-api-key'].value = '';
  elements['agent-api-key'].placeholder = agent?.hasApiKey ? 'Saved — leave blank to keep it' : 'Paste an API key';
  elements['agent-icon'].value = agent?.icon || '🧠';
  elements['agent-icon-picker'].value = [...elements['agent-icon-picker'].options].some(option => option.value === elements['agent-icon'].value) ? elements['agent-icon'].value : 'custom';
  elements['agent-color'].value = agent?.color || '#a779e9';
  elements['agent-aliases'].value = (agent?.aliases || []).join(', ');
  elements['agent-role'].value = agent?.role || '';
  elements['agent-instruction-file'].value = agent?.instructionFile || '';
  elements['agent-direct'].checked = agent?.directEnabled !== false;
  elements['agent-automatic'].checked = agent?.participationMode === 'automatic';
  elements['agent-synthesis'].checked = agent?.synthesisEnabled === true;
  elements['agent-form-status'].textContent = '';
  updateAgentProviderFields();
  applyAgentFormAccess();
  if (providerConfigurationAllowed()) elements['agent-name'].focus();
}

function applyAgentFormAccess() {
  const editable = providerConfigurationAllowed();
  const form = elements['agent-form'];
  form.classList.toggle('remote-readonly', !editable);
  elements['agent-host-note'].hidden = editable;
  elements['save-agent'].hidden = !editable;
  for (const control of form.querySelectorAll('input, select')) {
    if (control.id === 'agent-original-handle') continue;
    if (editable) {
      control.readOnly = false;
      control.style.pointerEvents = '';
      control.removeAttribute('aria-readonly');
      continue;
    }
    if (control.matches('input[type="checkbox"], input[type="color"]')) control.disabled = true;
    else if (control.matches('select')) {
      control.style.pointerEvents = 'none';
      control.setAttribute('aria-readonly', 'true');
      control.tabIndex = -1;
    } else {
      control.readOnly = true;
      control.setAttribute('aria-readonly', 'true');
    }
  }
}

function updateAgentProviderFields() {
  const http = elements['agent-kind'].value === 'HTTP';
  const image = elements['agent-kind'].value === 'Image';
  elements['agent-http-fields'].hidden = !http;
  elements['agent-image-fields'].hidden = !image;
  elements['agent-base-url'].required = http;
  elements['agent-api-style'].required = http;
  elements['agent-automatic'].disabled = image; elements['agent-synthesis'].disabled = image;
  if (image) { elements['agent-automatic'].checked = false; elements['agent-synthesis'].checked = false; }
  elements['agent-form-help'].textContent = http
    ? 'The preset fills editable defaults. API keys are encrypted in Demi’s local credential store and are never written to agents.json.'
    : image ? 'Image agents are addressed directly and never participate in text collaboration rounds. Every generation requires confirmation.'
    : elements['agent-kind'].value === 'Ollama'
      ? 'For Ollama, use the exact installed model name. Invited agents respond only when addressed directly.'
      : 'Invited agents respond only when addressed directly.';
}

function applyHttpPreset() {
  const preset = HTTP_PRESETS[elements['agent-http-provider'].value] || HTTP_PRESETS.other;
  elements['agent-base-url'].value = preset.baseUrl;
  elements['agent-api-style'].value = preset.apiStyle;
  elements['agent-model'].value = preset.model;
}

async function saveAgentForm(event) {
  event.preventDefault();
  if (!providerConfigurationAllowed()) {
    elements['agent-form-status'].textContent = 'Agent settings can only be changed on the host computer.';
    return;
  }
  const payload = { originalHandle: elements['agent-original-handle'].value, name: elements['agent-name'].value,
    handle: elements['agent-handle'].value, kind: elements['agent-kind'].value, model: elements['agent-model'].value,
    icon: elements['agent-icon'].value, color: elements['agent-color'].value, aliases: elements['agent-aliases'].value, imageProvider: elements['agent-image-provider'].value,
    imageResolution: elements['agent-image-resolution'].value, imageApiKey: elements['agent-image-api-key'].value,
    role: elements['agent-role'].value, instructionFile: elements['agent-instruction-file'].value,
    httpProvider: elements['agent-http-provider'].value, baseUrl: elements['agent-base-url'].value,
    apiStyle: elements['agent-api-style'].value, apiKey: elements['agent-api-key'].value,
    directEnabled: elements['agent-direct'].checked, participationMode: elements['agent-automatic'].checked ? 'automatic' : 'invited',
    synthesisEnabled: elements['agent-synthesis'].checked, enabled: true };
  try {
    elements['agent-form-status'].textContent = 'Saving…';
    const saved = await action('saveAgent', payload, { timeoutMs: 20000 });
    current.agentCatalog = saved.result?.agents || saved.agents || current.agentCatalog;
    current.agents = current.agentCatalog.filter(agent => agent.enabled !== false);
    renderAgents(); renderAgentPresence(current.agentPresence || {});
    elements['agent-form'].hidden = true; elements['agents-dialog'].classList.remove('editing-agent'); showNotice(`${payload.name} is ready. Use /${payload.handle} to address this agent directly.`);
  } catch (error) { elements['agent-form-status'].textContent = error.message || 'Could not save.'; }
}

async function checkIn(agent = null) {
  if (!presenceSupported) return showNotice('This Demi web server predates agent check-ins. Stop and restart “demi web”, then reload this page.');
  try {
    const data = await action('checkin', agent ? { agent } : {});
    const failed = (data.result?.results || []).filter(item => !item.online);
    if (failed.length) showNotice(`${failed.map(item => item.agent).join(', ')} did not positively respond to the private check-in.`);
  } catch {}
}

function showNotice(message, retryable = false) {
  const noticeMessage = String(message || '');
  if (noticeMessage && noticeMessage === dismissedNoticeMessage) {
    elements.notice.hidden = true;
    return;
  }
  const text = document.createElement('span');
  text.className = 'notice-message';
  text.textContent = noticeMessage;
  const actions = document.createElement('span');
  actions.className = 'notice-actions';
  if (retryable) {
    const retry = document.createElement('button');
    retry.type = 'button';
    retry.textContent = 'Retry';
    retry.addEventListener('click', () => action('retry').catch(() => {}));
    actions.append(retry);
  }
  const dismiss = document.createElement('button');
  dismiss.type = 'button';
  dismiss.textContent = 'Dismiss';
  dismiss.setAttribute('aria-label', 'Dismiss notice');
  dismiss.addEventListener('click', () => {
    dismissedNoticeMessage = noticeMessage;
    clearNotice();
  });
  actions.append(dismiss);
  elements.notice.replaceChildren(text, actions);
  elements.notice.dataset.message = noticeMessage;
  elements.notice.hidden = false;
}

function clearNotice(resetDismissed = false) {
  elements.notice.hidden = true;
  elements.notice.replaceChildren();
  delete elements.notice.dataset.message;
  if (resetDismissed) dismissedNoticeMessage = null;
}

function setBusy(busy) {
  elements.send.disabled = busy;
  elements.stop.disabled = busy;
  elements.continue.disabled = busy;
  elements['new-session'].disabled = busy;
  elements['attach-image'].disabled = busy;
  elements['attachment-input'].disabled = busy;
  for (const button of elements['agent-presence-list'].querySelectorAll('button')) button.disabled = busy;
  elements['checkin-all'].disabled = busy;
  for (const button of elements['attachment-preview'].querySelectorAll('button')) button.disabled = busy;
}

function formatFileSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function savePendingAttachments() {
  sessionStorage.setItem('demi-web-attachments', JSON.stringify(pendingAttachments));
}

function renderPendingAttachments() {
  const container = elements['attachment-preview'];
  container.replaceChildren();
  container.hidden = pendingAttachments.length === 0;
  for (const attachment of pendingAttachments) {
    const card = document.createElement('div');
    card.className = 'attachment-card';
    const image = attachment.mime?.startsWith('image/') ? document.createElement('img') : document.createElement('span');
    if (image.tagName === 'IMG') { image.src = attachment.url; image.alt = ''; }
    else { image.className = 'attachment-file-icon'; image.textContent = (attachment.name.split('.').pop() || 'FILE').toUpperCase(); }
    const details = document.createElement('span');
    details.className = 'attachment-details';
    const name = document.createElement('strong');
    name.textContent = attachment.originalName || attachment.name;
    const size = document.createElement('span');
    size.textContent = formatFileSize(attachment.size);
    details.append(name, size);
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'attachment-remove';
    remove.textContent = 'Remove';
    remove.addEventListener('click', () => {
      pendingAttachments = pendingAttachments.filter(item => item.path !== attachment.path);
      savePendingAttachments();
      renderPendingAttachments();
    });
    card.append(image, details, remove);
    container.append(card);
  }
}

function clearPendingAttachments() {
  pendingAttachments = [];
  sessionStorage.removeItem('demi-web-attachments');
  renderPendingAttachments();
}

async function uploadImage(file) {
  if (!(file instanceof File)) throw new Error('Dropped item is not a file.');
  const extension = `.${(file.name.split('.').pop() || '').toLowerCase()}`;
  if (!ATTACHMENT_EXTENSIONS.has(extension)) throw new Error('Only PNG, JPEG, WebP, GIF, MD, PDF, DOCX, and EPUB files are accepted.');
  if (!file.size) throw new Error('The attachment is empty.');
  if (file.size > ATTACHMENT_MAX_BYTES) throw new Error('Attachment exceeds the 25 MB limit.');
  if (pendingAttachments.length >= 4) throw new Error('A message may contain at most four attachments.');
  const response = await fetch('/api/attachment', {
    method: 'POST',
    headers: { 'Content-Type': file.type || 'application/octet-stream', 'X-Demi-Token': token, 'X-Demi-Filename': encodeURIComponent(file.name) },
    body: file
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Attachment upload failed.');
  pendingAttachments.push(data.attachment);
  savePendingAttachments();
  renderPendingAttachments();
}

async function addImageFiles(files) {
  clearNotice(true);
  try {
    for (const file of Array.from(files || [])) await uploadImage(file);
  } catch (error) {
    showNotice(error.message);
  } finally {
    elements['attachment-input'].value = '';
  }
}

function activeMutation(snapshot) {
  if (snapshot?.activeAction || snapshot?.dispatcher?.active) return snapshot.activeAction || 'agent dispatch';
  if (snapshot?.state?.directTurn?.active) return `direct ${snapshot.state.directTurn.agent || 'agent'} turn`;
  return null;
}

async function openNewSessionDialog() {
  try {
    const fresh = await action('status');
    const active = activeMutation(fresh);
    if (active) return showNotice(`Cannot open a new session while ${active} is active. Finish it explicitly; no work was cancelled.`);
    const session = fresh.state.currentSession;
    elements['new-session-dialog'].dataset.session = session;
    elements['new-session-summary'].textContent = `Current session: ${session}`;
    elements['new-session-open-round'].hidden = fresh.state.round?.status !== 'open';
    elements['new-session-dialog'].showModal();
  } catch {}
}

async function confirmNewSession() {
  const dialog = elements['new-session-dialog'];
  const submittedCommand = dialog.dataset.composerCommand || '';
  try {
    const response = await action('newSession', {
      confirmedSession: dialog.dataset.session,
      confirmOpenRound: !elements['new-session-open-round'].hidden
    });
    dialog.close();
    dialog.dataset.composerCommand = '';
    renderSession(response);
    if (submittedCommand && elements.composer.value === submittedCommand) {
      elements.composer.value = '';
      if (sessionStorage.getItem('demi-web-draft') === submittedCommand) sessionStorage.removeItem('demi-web-draft');
    }
  } catch {}
}

async function refreshMutationToken() {
  const response = await fetch('/api/bootstrap', { cache: 'no-store' });
  const data = await response.json();
  if (!response.ok || !data.token) throw new Error(data.error || 'Demi could not refresh this page’s connection. Reload the page and try again.');
  token = data.token;
}

async function action(actionName, payload = {}, options = {}) {
  if (!options.quiet) clearNotice(true);
  if (!options.quiet) setBusy(true);
  const timeoutMs = Number(options.timeoutMs || 0);
  const controller = timeoutMs > 0 ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const send = () => fetch('/api/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Demi-Token': token },
      body: JSON.stringify({ action: actionName, payload: { ...payload, humanId: humanIdentityId || selectedHuman()?.id || '' } }),
      signal: controller?.signal
    });
    let response = await send();
    let data = await response.json();
    if (response.status === 403 && data.error === 'Invalid local session token or origin.') {
      await refreshMutationToken();
      response = await send();
      data = await response.json();
    }
    if (!response.ok) {
      const error = new Error(data.error || 'Demi request failed.');
      error.retryable = Boolean(data.retryable);
      throw error;
    }
    if (data.state) updateStatus(data);
    return data;
  } catch (error) {
    if (error.name === 'AbortError') error = new Error('Saving took too long. Nothing was changed; reload the page and try again.');
    if (!options.quiet) showNotice(error.message, error.retryable === true);
    throw error;
  } finally {
    if (timeout) clearTimeout(timeout);
    if (!options.quiet) setBusy(false);
  }
}

async function openTimelineDialog(event = null) {
  const response = await fetch('/api/timeline', { headers: { Accept: 'application/json' }, cache: 'no-store' });
  const data = await response.json();
  if (!response.ok) throw new Error(data.detail || data.error || 'Timeline data could not be loaded.');
  const silos = Array.isArray(data.silos) && data.silos.length
    ? data.silos
    : [...new Map((data.events || []).flatMap(item => item.silos || []).map(item => [item.slug, item])).values()];
  for (const select of [elements['timeline-focus'], elements['timeline-references']]) select.replaceChildren();
  for (const silo of silos) {
    for (const select of [elements['timeline-focus'], elements['timeline-references']]) {
      const option = document.createElement('option'); option.value = silo.slug; option.textContent = silo.name || silo.slug; select.append(option);
    }
  }
  const focus = event?.silos?.find(item => item.role === 'focus')?.slug || event?.silos?.[0]?.slug || 'global';
  const assignedSilos = new Set((event?.silos || []).map(item => item.slug));
  assignedSilos.add(focus);
  elements['timeline-form-title'].textContent = event ? 'Edit timeline event' : 'Add timeline event';
  elements['timeline-id'].value = event?.external_id || '';
  elements['timeline-date'].value = event?.display_date || '';
  elements['timeline-start'].value = event?.earth_year_start ?? '';
  elements['timeline-end'].value = event?.earth_year_end ?? '';
  elements['timeline-title'].value = event?.title || '';
  elements['timeline-summary'].value = event?.summary || '';
  elements['timeline-focus'].value = focus;
  for (const option of elements['timeline-references'].options) option.selected = assignedSilos.has(option.value);
  elements['timeline-status'].value = event?.adoption_status || 'suggested';
  elements['timeline-confidence'].value = event?.confidence || '';
  elements['timeline-date-system'].value = event?.date_system || 'Earth calendar';
  elements['timeline-date-basis'].value = event?.earth_year_basis || '';
  elements['timeline-impact'].value = event?.cross_book_impact || '';
  elements['timeline-source-label'].value = event?.sources?.[0]?.label || '';
  elements['timeline-source-claim'].value = event?.sources?.[0]?.claim || '';
  elements['timeline-form-status'].textContent = '';
  elements['delete-timeline'].hidden = !event?.external_id;
  elements['timeline-dialog'].showModal();
  elements['timeline-date'].focus();
}

async function saveTimelineEvent(event) {
  event.preventDefault();
  const focus = elements['timeline-focus'].value || 'global';
  const references = [...elements['timeline-references'].selectedOptions].map(option => option.value).filter(slug => slug !== focus);
  const payload = {
    externalId: elements['timeline-id'].value, date: elements['timeline-date'].value,
    earthYearStart: elements['timeline-start'].value, earthYearEnd: elements['timeline-end'].value,
    title: elements['timeline-title'].value, summary: elements['timeline-summary'].value,
    siloSlugs: [focus, ...references], adoptionStatus: elements['timeline-status'].value,
    verificationStatus: elements['timeline-status'].value === 'verified' ? 'verified' : 'not_required',
    confidence: elements['timeline-confidence'].value, dateSystem: elements['timeline-date-system'].value,
    dateBasis: elements['timeline-date-basis'].value, crossBookImpact: elements['timeline-impact'].value,
    sourceLabel: elements['timeline-source-label'].value, sourceClaim: elements['timeline-source-claim'].value
  };
  try {
    elements['timeline-form-status'].textContent = 'Saving…';
    const response = await action('timelineSave', payload);
    elements['timeline-dialog'].close();
    showNotice(`${response.result?.title || payload.title} was saved to the timeline.`);
  } catch (error) { elements['timeline-form-status'].textContent = error.message; }
}

async function deleteTimelineEvent() {
  const externalId = elements['timeline-id'].value;
  const eventTitle = elements['timeline-title'].value || externalId;
  if (!externalId || !window.confirm(`Delete “${eventTitle}” from the timeline? This cannot be undone.`)) return;
  try {
    elements['timeline-form-status'].textContent = 'Deleting…';
    await action('timelineDelete', { externalId });
    elements['timeline-dialog'].close();
    showNotice(`${eventTitle} was deleted from the timeline.`);
  } catch (error) { elements['timeline-form-status'].textContent = error.message; }
}

async function submit() {
  const text = elements.composer.value;
  if (!text.trim() && !pendingAttachments.length) return;
  const commandHandle = text.trim().match(/^\/([a-z][a-z0-9_-]{0,31})\s+/i)?.[1]?.toLowerCase();
  const imageCommand = Boolean((current?.agents || []).find(agent => agent.kind === 'Image' && [agent.handle, ...(agent.aliases || [])].includes(commandHandle)));
  if (pendingAttachments.length && text.trim().startsWith('/') && !imageCommand) return showNotice('Attachments can accompany ordinary human messages and /art image requests only.');
  if (imageCommand) {
    try {
      const estimate = await action('imageEstimate', { command: text, attachments: pendingAttachments.map(item => item.path) });
      const detail = estimate.result || estimate;
      const dialog = elements['image-confirm-dialog'];
      dialog.dataset.confirmationToken = detail.confirmationToken;
      dialog.dataset.originalCommand = text;
      dialog.dataset.originalAttachments = JSON.stringify(pendingAttachments.map(item => item.path));
      elements['image-confirm-prompt'].textContent = text.replace(/^\/[a-z][a-z0-9_-]{0,31}\s+/i, '');
      elements['image-confirm-provider'].textContent = detail.provider;
      elements['image-confirm-model'].textContent = detail.model;
      elements['image-confirm-resolution'].textContent = detail.resolution;
      elements['image-confirm-aspect'].textContent = detail.aspectRatio;
      elements['image-confirm-references'].textContent = detail.references?.length ? detail.references.join(', ') : 'None';
      elements['image-confirm-cost'].textContent = Number.isFinite(detail.estimate?.amount) ? `Approximately $${detail.estimate.amount.toFixed(2)} ${detail.estimate.currency}` : `Unavailable · ${detail.estimate?.basis || 'provider did not report pricing'}`;
      elements['image-confirm-credits'].textContent = detail.credits?.label || 'Unavailable';
      dialog.showModal();
    } catch {}
    return;
  }
  if (/^\/help\s*$/i.test(text.trim())) { openHelp(); elements.composer.value=''; sessionStorage.removeItem('demi-web-draft'); return; }
  const identityCommand = text.trim().match(/^\/identity(?:\s+(.+?))?\s*$/i);
  if (identityCommand) {
    try {
      if (!identityCommand[1]) {
        const human = selectedHuman();
        showNotice(human ? `You are currently identified as ${human.displayName}.` : 'No human identity is selected.');
      } else {
        const human = await selectHumanIdentity(identityCommand[1]);
        if (human) showNotice(`You are now identified as ${human.displayName} on this browser.`);
      }
      elements.composer.value = '';
      sessionStorage.removeItem('demi-web-draft');
    } catch (error) { showNotice(error.message); }
    return;
  }
  if (/^\/timeline\s*$/i.test(text.trim())) {
    try { await openTimelineDialog(); elements.composer.value=''; sessionStorage.removeItem('demi-web-draft'); }
    catch (error) { showNotice(error.message); }
    return;
  }
  if (/^\/new-session\s*$/i.test(text.trim())) {
    elements['new-session-dialog'].dataset.composerCommand = text;
    await openNewSessionDialog();
    return;
  }
  if (/^\/compact\s*$/i.test(text.trim())) { preferences.view = 'compact'; savePreferences(); elements.composer.value = ''; sessionStorage.removeItem('demi-web-draft'); return; }
  if (/^\/full\s*$/i.test(text.trim())) { preferences.view = 'detailed'; savePreferences(); elements.composer.value = ''; sessionStorage.removeItem('demi-web-draft'); return; }
  if (/^\/status\s*$/i.test(text.trim())) {
    try {
      const data = await action('status');
      const round = data.state.round;
      const pending = (data.state.acknowledgements || []).reduce((count, item) => count + (item.pending || []).length, 0);
      const obligation = data.pending
        ? `Pending: ${data.pending.speaker} since ${localTime(data.pending.since, true)} (${data.pending.for})`
        : 'Pending: no agent';
      const dispatch = data.dispatcher?.state === 'running'
        ? `Dispatcher: running ${data.dispatcher.agent} (${data.dispatcher.for})`
        : data.dispatcher?.state === 'failed/retryable'
          ? `Dispatcher: failed/retryable (${data.dispatcher.for} ago)`
          : 'Dispatcher: inactive';
      showNotice(`Session: ${data.state.currentSession} · Round: ${round.id || 'none'} (${round.status}) · ${obligation} · ${dispatch} · Remaining: ${round.remainingResponses} · Target: ${round.target} · Pending acknowledgments: ${pending}`);
      elements.composer.value = '';
      sessionStorage.removeItem('demi-web-draft');
    } catch {}
    return;
  }
  try {
    const submittedAttachments = pendingAttachments.map(item => item.path);
    const response = await action('composer', { text, attachments: submittedAttachments });
    if (response.result?.projectLinks) {
      current.projectLinks = response.result.projectLinks;
      renderProjectLinks(current.projectLinks);
      showNotice(`Project link “${response.result.link?.label || 'Untitled'}” was added.`);
    }
    const attachmentsUnchanged = JSON.stringify(pendingAttachments.map(item => item.path)) === JSON.stringify(submittedAttachments);
    if (response.accepted === true && elements.composer.value === text && attachmentsUnchanged) {
      elements.composer.value = '';
      if (sessionStorage.getItem('demi-web-draft') === text) sessionStorage.removeItem('demi-web-draft');
      clearPendingAttachments();
    }
  } catch {}
}

async function confirmImageGeneration() {
  const dialog = elements['image-confirm-dialog'];
  const button = elements['confirm-image-generation'];
  try {
    button.disabled = true; button.textContent = 'Generating…';
    const response = await action('generateImage', { confirmationToken: dialog.dataset.confirmationToken }, { timeoutMs: 360000 });
    const sameCommand = elements.composer.value === dialog.dataset.originalCommand;
    const sameAttachments = JSON.stringify(pendingAttachments.map(item => item.path)) === dialog.dataset.originalAttachments;
    dialog.close();
    if (response.accepted && sameCommand && sameAttachments) { elements.composer.value = ''; sessionStorage.removeItem('demi-web-draft'); clearPendingAttachments(); }
  } catch {} finally { button.disabled = false; button.textContent = 'Generate image'; }
}

function composerChanged() {
  sessionStorage.setItem('demi-web-draft', elements.composer.value);
  resizeComposer();
}

function renderHelp() {
  const content=elements['help-content'];content.replaceChildren();
  const section=(title,commands)=>{const heading=document.createElement('h3');heading.textContent=title;const list=document.createElement('dl');list.className='command-help-list';for(const [command,description] of commands){const term=document.createElement('dt');const code=document.createElement('code');code.textContent=command;term.append(code);const detail=document.createElement('dd');detail.textContent=description;list.append(term,detail)}content.append(heading,list)};
  section('Conversation',[['/help','Show this command list.'],['/identity name','Identify this browser as a configured human participant. Use /identity alone to check.'],['/note text','Record a note and request acknowledgments.'],['/note -noack text','Record a note silently.'],['/continue N','Allow N more agent responses.'],['/dispatch','Request the currently authorized response.'],['/run','Run the bounded authorized allowance.'],['/retry','Retry the latest failed dispatch from the sequential workflow.'],['/retry agent','Retry that agent’s latest failed parallel response.'],['/all question','Ask every available non-round agent independently and simultaneously.'],['/all --synthesize question','Run independent answers, then the configured synthesizers.'],['/agent1 /agent2 question','Ask the named agents independently and simultaneously.'],['/review request','Run concurrent independent reviews from all available non-round agents.'],['/review --synthesize request','Run concurrent reviews, then synthesize them.'],['/timeline','Open the timeline event editor.'],['/timeline date | title | summary','Quick-add a suggested timeline event.'],['/link "title" URL','Add a Project Link from the host computer.'],['/stop agent','Stop one running parallel response.'],['/stop','Stop all parallel responses and the sequential dispatcher.'],['/status','Show session and dispatcher status.']]);
  const agents=(current?.agents||[]).filter(agent=>agent.directEnabled);section('Configured agents',agents.length?agents.map(agent=>[`/${agent.handle} question`,`${agent.icon} Ask ${agent.name} directly.${agent.aliases?.length?` Aliases: ${agent.aliases.map(alias=>`/${alias}`).join(', ')}.`:''}`]):[['—','No directly addressable agents are configured.']]);
  section('Sessions and display',[['/new-session','Archive this session and open the next one after confirmation.'],['/compact','Use compact message display.'],['/full','Show detailed message metadata.']]);
  section('Images, documents, and guests',[['/image description','Generate an image with the default image model.'],['/image --model owner/model description','Override the default Replicate image model. Optional: --resolution 1K|2K|4K and --aspect 16:9.'],['/image-models query','Search Replicate for available image-generation models without consuming generation credits.'],['/draft request','Create a Sonnet reference or backend document draft.'],['/fable request','Create a Fable prose draft.'],['/alice text','Add an Alice-authored guest contribution.']]);
}

async function openHelp() {
  const content = elements['help-content'];
  elements['help-search'].value = '';
  content.innerHTML = '<p>Loading help…</p>';
  elements['help-dialog'].showModal();
  try {
    const response = await fetch('/api/help', { cache: 'no-store' });
    if (!response.ok) throw new Error('The help file is unavailable.');
    renderHelpDocument(await response.text());
  } catch {
    renderHelp();
  }
  elements['help-search'].focus();
}

function renderHelpDocument(markdown) {
  const content = elements['help-content'];
  content.replaceChildren();
  const lines = String(markdown || '').replace(/\r\n?/g, '\n').split('\n');
  let section = null;
  let subsection = [];
  const flushSubsection = () => {
    if (!section || !subsection.length) return;
    const body = document.createElement('div');
    body.innerHTML = DemiMarkdown.renderMarkdown(subsection.join('\n'));
    section.append(...body.childNodes);
    subsection = [];
  };
  for (const line of lines) {
    const levelTwo = line.match(/^##\s+(.+)$/);
    const levelThree = line.match(/^###\s+(.+)$/);
    if (levelTwo) {
      flushSubsection();
      section = document.createElement('section');
      section.className = 'help-section';
      const heading = document.createElement('h2'); heading.textContent = levelTwo[1];
      section.append(heading); content.append(section);
    } else if (levelThree && section) {
      flushSubsection();
      const heading = document.createElement('h3'); heading.textContent = levelThree[1];
      section.append(heading);
    } else if (!/^#\s+/.test(line)) {
      if (!section) {
        section = document.createElement('section');
        section.className = 'help-section help-introduction';
        content.append(section);
      }
      subsection.push(line);
    }
  }
  flushSubsection();
  insertConfiguredAgentsHelp(content);
}

function insertConfiguredAgentsHelp(content) {
  const section = document.createElement('section');
  section.className = 'help-section help-configured-agents';
  const heading = document.createElement('h2');
  heading.textContent = 'Configured agents';
  const introduction = document.createElement('p');
  introduction.textContent = 'This live list comes from People & Agents and updates whenever the agent configuration changes.';
  section.append(heading, introduction);
  const agents = current?.agents || [];
  if (!agents.length) {
    const empty = document.createElement('p');
    empty.textContent = 'No agents are configured.';
    section.append(empty);
  } else {
    const list = document.createElement('dl');
    list.className = 'command-help-list configured-agent-help-list';
    for (const agent of agents) {
      const term = document.createElement('dt');
      term.textContent = `${agent.icon || '●'} ${agent.name}`;
      const detail = document.createElement('dd');
      const addresses = agent.directEnabled
        ? [`/${agent.handle}`, ...(agent.aliases || []).map(alias => `/${alias}`)].join(', ')
        : 'Direct command disabled';
      const provider = agent.kind === 'HTTP' ? (agent.httpProvider || agent.kind) : (agent.imageProvider || agent.kind || 'Provider not set');
      const model = agent.model || 'provider default';
      detail.textContent = `${addresses} · ${provider} · ${model}${agent.enabled === false ? ' · Disabled' : ''}${agent.synthesisEnabled ? ' · Synthesizer' : ''}`;
      list.append(term, detail);
    }
    section.append(list);
  }
  const agentsSection = [...content.querySelectorAll('.help-section')].find(item => item.querySelector(':scope > h2')?.textContent === 'Agents');
  if (agentsSection) content.insertBefore(section, agentsSection);
  else content.append(section);
}

function filterHelp() {
  const content = elements['help-content'];
  for (const mark of [...content.querySelectorAll('mark.help-search-match')]) mark.replaceWith(document.createTextNode(mark.textContent));
  content.normalize();
  const rawQuery = elements['help-search'].value.trim();
  const query = rawQuery.toLocaleLowerCase();
  const sections = [...elements['help-content'].querySelectorAll('.help-section')];
  if (!sections.length) {
    for (const node of content.children) {
      node.hidden = Boolean(query) && !node.textContent.toLocaleLowerCase().includes(query);
      if (query && !node.hidden) highlightHelpMatches(node, rawQuery);
    }
    return;
  }
  for (const section of sections) {
    section.hidden = Boolean(query) && !section.textContent.toLocaleLowerCase().includes(query);
    if (query && !section.hidden) highlightHelpMatches(section, rawQuery);
  }
}

function highlightHelpMatches(root, query) {
  const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      return node.parentElement?.closest('mark,script,style') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
    }
  });
  const textNodes = [];
  while (walker.nextNode()) textNodes.push(walker.currentNode);
  for (const node of textNodes) {
    pattern.lastIndex = 0;
    if (!pattern.test(node.data)) continue;
    pattern.lastIndex = 0;
    const fragment = document.createDocumentFragment();
    let previous = 0;
    for (const match of node.data.matchAll(pattern)) {
      fragment.append(document.createTextNode(node.data.slice(previous, match.index)));
      const mark = document.createElement('mark');
      mark.className = 'help-search-match';
      mark.textContent = match[0];
      fragment.append(mark);
      previous = match.index + match[0].length;
    }
    fragment.append(document.createTextNode(node.data.slice(previous)));
    node.replaceWith(fragment);
  }
}

function resizeComposer() {
  const textarea = elements.composer;
  const keepLatestVisible = nearBottom();
  textarea.style.height = 'auto';
  const maximum = compactViewport() ? Math.min(innerHeight * .16, 120) : Math.min(innerHeight * .24, 190);
  textarea.style.height = `${Math.min(textarea.scrollHeight, maximum)}px`;
  const workspace = document.querySelector('.workspace');
  if (workspace) document.documentElement.style.setProperty('--composer-height', `${workspace.getBoundingClientRect().height}px`);
  if (keepLatestVisible) scrollToBottom();
}

function flashComposerTool(button, text) {
  const original = button.textContent;
  button.textContent = text;
  setTimeout(() => { button.textContent = original; }, 1200);
}

async function copyComposer() {
  try {
    await navigator.clipboard.writeText(elements.composer.value);
    flashComposerTool(elements['copy-composer'], 'Copied');
  } catch {
    showNotice('Clipboard access was blocked. Select the message text and use Ctrl+C.');
  }
}

async function pasteComposer() {
  try {
    const text = await navigator.clipboard.readText();
    elements.composer.value = text.slice(0, Number(elements.composer.maxLength) || 100000);
    composerChanged();
    elements.composer.focus();
    flashComposerTool(elements['paste-composer'], 'Replaced');
  } catch {
    showNotice('Clipboard access was blocked. Click in the message box and use Ctrl+V.');
  }
}

function populateDraftAgents() {
  const agents = (current?.agentCatalog || current?.agents || []).filter(agent => agent.enabled !== false && agent.kind !== 'Image');
  const previousDrafter = elements['draft-agent'].value;
  const previousReviewer = draftReviewerInitialized ? elements['draft-reviewer'].value : null;
  elements['draft-agent'].replaceChildren();
  elements['draft-reviewer'].replaceChildren(new Option('None — no automatic review', ''));
  for (const agent of agents) {
    const label = `${agent.icon || '●'} ${agent.name}${agent.model ? ` · ${agent.model}` : ''}`;
    elements['draft-agent'].append(new Option(label, agent.handle || agent.name));
    if (agent.directEnabled !== false) elements['draft-reviewer'].append(new Option(label, agent.handle || agent.name));
  }
  const claude = agents.find(agent => agent.name === 'Claude');
  const rowan = agents.find(agent => agent.name === 'Rowan' && agent.directEnabled !== false);
  elements['draft-agent'].value = [...elements['draft-agent'].options].some(option => option.value === previousDrafter) ? previousDrafter : claude?.handle || elements['draft-agent'].options[0]?.value || '';
  elements['draft-reviewer'].value = previousReviewer !== null && [...elements['draft-reviewer'].options].some(option => option.value === previousReviewer)
    ? previousReviewer : rowan?.handle || '';
  draftReviewerInitialized = true;
}

function openDraftDialog() {
  elements['draft-form'].hidden = Boolean(pendingDraft);
  elements['draft-preview'].hidden = !pendingDraft;
  elements['draft-created'].hidden = true;
  elements['draft-form-status'].textContent = '';
  populateDraftAgents();
  elements['draft-dialog'].showModal();
  elements['draft-request'].focus();
}

function suggestedDraftPath(draft, extension) {
  const supplied = elements['draft-file'].value.trim();
  if (supplied) return supplied.replace(/\.(?:md|txt|docx)$/i, `.${extension}`);
  const leaf = (draft.suggestedFileName || `draft_v001.${extension}`).replace(/\.(?:md|txt|docx)$/i, `.${extension}`);
  return `collaboration/handoff/${leaf}`;
}

async function generateDraft(event) {
  event.preventDefault();
  const payload = {
    request: elements['draft-request'].value,
    file: elements['draft-file'].value.trim() || null,
    format: elements['draft-format'].value,
    agent: elements['draft-agent'].value,
    reviewer: elements['draft-reviewer'].value || null,
    responsesOnly: false
  };
  const drafter = elements['draft-agent'].selectedOptions[0]?.textContent || 'the selected agent';
  elements['draft-form-status'].textContent = `Generating with ${drafter}…`;
  elements['draft-generate'].disabled = true;
  elements['draft-generate'].textContent = 'Generating…';
  elements['draft-dialog'].close();
  showNotice(`Draft generation started with ${drafter}. You can follow it in Dispatcher activity.`);
  try {
    const response = await action('draft', payload, { quiet: true });
    pendingDraft = response.result;
    elements['draft-form'].hidden = true;
    elements['draft-preview'].hidden = false;
    elements['draft-title'].textContent = pendingDraft.title;
    elements['draft-model-label'].textContent = pendingDraft.agent || pendingDraft.model || 'Draft agent';
    elements['draft-content'].innerHTML = DemiMarkdown.renderMarkdown(pendingDraft.content);
    elements['draft-save-file'].value = suggestedDraftPath(pendingDraft, payload.format);
    if (pendingDraft.creation) showDraftCreation(pendingDraft.creation);
    pendingDraft.reviewer = pendingDraft.reviewer || null;
    const reviewStatus = pendingDraft.reviewError ? ` The draft was saved, but ${pendingDraft.reviewer || 'the reviewer'} could not be started: ${pendingDraft.reviewError}`
      : pendingDraft.reviewer ? ` ${pendingDraft.reviewer} is reviewing it now.` : '';
    showNotice(`${pendingDraft.agent || 'The drafting agent'} completed “${pendingDraft.title}” and saved it to Session files.${reviewStatus}`);
  } catch (error) {
    elements['draft-form-status'].textContent = error.message || 'Draft generation failed.';
    if (!elements['draft-dialog'].open) elements['draft-dialog'].showModal();
  } finally {
    elements['draft-generate'].disabled = false;
    elements['draft-generate'].textContent = 'Generate';
  }
}

function showDraftCreation(creation) {
  elements['draft-created'].hidden = false;
  elements['draft-created'].replaceChildren();
  const link = document.createElement('a');
  link.href = `/api/document?path=${encodeURIComponent(creation.destination)}`;
  link.textContent = creation.destination;
  link.target = '_blank';
  elements['draft-created'].append(
    link,
    document.createTextNode(` · ${creation.fileSize} bytes · SHA-256 ${creation.sha256} · Proposed—not canon · No existing file was overwritten.`)
  );
}

async function savePendingDraft(extension) {
  if (!pendingDraft?.draftToken) return showNotice('This draft has already been created or has no pending save token.');
  const file = elements['draft-save-file'].value.trim().replace(/\.(?:md|txt|docx)$/i, `.${extension}`);
  elements['draft-save-file'].value = file;
  try {
    const response = await action('draftSave', { token: pendingDraft.draftToken, file });
    showDraftCreation(response.result);
    pendingDraft.draftToken = null;
  } catch {}
}

function discardDraft() {
  pendingDraft = null;
  elements['draft-content'].textContent = '';
  elements['draft-dialog'].close();
}

function connectEvents() {
  if (eventSource) eventSource.close();
  eventSource = new EventSource('/api/events');
  eventSource.addEventListener('open', () => {
    updateConnectionLabel();
    elements.connection.className = 'connection online';
    if (connectedOnce) clearNotice(true);
    connectedOnce = true;
  });
  eventSource.addEventListener('entry', event => receiveEntry(JSON.parse(event.data)));
  eventSource.addEventListener('session', event => renderSession(JSON.parse(event.data)));
  eventSource.addEventListener('status', event => updateStatus(JSON.parse(event.data)));
  eventSource.addEventListener('error', event => {
    if (event.data) {
      try { showNotice(JSON.parse(event.data).message, true); } catch {}
    } else {
      elements.connection.textContent = 'Reconnecting';
      elements.connection.className = 'connection offline';
      showNotice('Connection to the local Demi server was lost. Reconnecting…');
    }
  });
}

async function bootstrap() {
  applyPreferences();
  syncHeaderMenus();
  elements.composer.value = sessionStorage.getItem('demi-web-draft') || '';
  resizeComposer();
  try { pendingAttachments = JSON.parse(sessionStorage.getItem('demi-web-attachments') || '[]'); } catch { pendingAttachments = []; }
  if (!Array.isArray(pendingAttachments)) pendingAttachments = [];
  renderPendingAttachments();
  try {
    const response = await fetch('/api/bootstrap', { cache: 'no-store' });
    const data = await response.json();
    token = data.token;
    current = data;
    if (data.authenticatedHumanId) humanIdentityId = data.authenticatedHumanId;
    const identity = selectedHuman();
    if (identity && !humanIdentityId) {
      humanIdentityId = identity.id;
      localStorage.setItem('demi-human-identity', humanIdentityId);
    }
    renderEntryWindow(data.entries || []);
    renderConversation(data.entries || []);
    renderSessionFiles(data.entries || []);
    updateStatus(data);
    scrollToBottom();
    connectEvents();
  } catch (error) {
    showNotice(`Could not load Demi: ${error.message}`);
  }
}

elements.send.addEventListener('click', submit);
elements['load-earlier'].addEventListener('click', () => {
  const priorHeight = elements.messages.scrollHeight;
  renderEntryWindow(renderedEntries, Math.max(0, renderedStart - MESSAGE_PAGE_SIZE));
  elements.messages.scrollTop = Math.max(0, elements.messages.scrollHeight - priorHeight);
});
elements['checkin-all'].addEventListener('click', () => { document.querySelector('.agent-presence-menu')?.removeAttribute('open'); checkIn(); });
for (const menu of document.querySelectorAll('.agent-presence-menu, .mobile-actions-menu')) menu.addEventListener('toggle', () => {
  if (!compactViewport()) return;
  if (!menu.open) return;
  for (const other of document.querySelectorAll('.agent-presence-menu, .mobile-actions-menu')) if (other !== menu) other.removeAttribute('open');
});
document.querySelector('.top-actions')?.addEventListener('click', event => {
  if (compactViewport() && event.target.closest('button')) document.querySelector('.mobile-actions-menu')?.removeAttribute('open');
});
elements['session-files-toggle'].addEventListener('click', () => {
  const expanded = elements['session-files-toggle'].getAttribute('aria-expanded') === 'true';
  elements['session-files-toggle'].setAttribute('aria-expanded', String(!expanded));
  elements['session-file-list'].hidden = expanded;
});
elements.composer.addEventListener('keydown', event => {
  if (event.key === 'Enter' && event.ctrlKey) { event.preventDefault(); submit(); }
});
elements.composer.addEventListener('input', composerChanged);
elements.composer.addEventListener('paste', event => {
  const images = Array.from(event.clipboardData?.items || [])
    .filter(item => item.kind === 'file' && ATTACHMENT_MIME.has(item.type))
    .map(item => item.getAsFile()).filter(Boolean);
  if (images.length) addImageFiles(images);
});
for (const eventName of ['dragenter', 'dragover']) elements.composer.addEventListener(eventName, event => {
  event.preventDefault();
  if (Array.from(event.dataTransfer?.items || []).some(item => item.kind === 'file')) elements.composer.classList.add('attachment-drop-active');
});
for (const eventName of ['dragleave', 'drop']) elements.composer.addEventListener(eventName, event => {
  event.preventDefault();
  elements.composer.classList.remove('attachment-drop-active');
  if (eventName === 'drop') addImageFiles(event.dataTransfer?.files);
});
elements['attach-image'].addEventListener('click', () => elements['attachment-input'].click());
elements['attachment-input'].addEventListener('change', event => addImageFiles(event.target.files));
elements['copy-composer'].addEventListener('click', copyComposer);
elements['paste-composer'].addEventListener('click', pasteComposer);
elements.stop.addEventListener('click', () => action('stop').catch(() => {}));
elements.continue.addEventListener('click', () => action('continue', { count: Number(elements['continue-count'].value) }).catch(() => {}));
elements['new-messages'].addEventListener('click', scrollToBottom);
elements.messages.addEventListener('scroll', () => { followMessageTail = nearBottom(); }, { passive: true });
elements['conversation-collapse'].addEventListener('click', () => {
  if (matchMedia('(max-width: 620px)').matches) return closeMobileDrawers();
  preferences.conversationOpen = !preferences.conversationOpen;
  savePreferences();
});
elements['conversation-order'].addEventListener('click', () => {
  preferences.conversationNewestFirst = !preferences.conversationNewestFirst;
  localStorage.setItem('demi-web-preferences', JSON.stringify(preferences));
  renderConversation(current?.entries || []);
});
elements['mobile-conversation'].addEventListener('click', () => toggleMobileDrawer('conversation'));
elements['mobile-files'].addEventListener('click', () => toggleMobileDrawer('files'));
elements['close-session-files'].addEventListener('click', closeMobileDrawers);
elements['drawer-backdrop'].addEventListener('click', closeMobileDrawers);
document.querySelector('.feature-menu').addEventListener('toggle', event => {
  if (!matchMedia('(max-width: 620px)').matches) return;
  if (event.currentTarget.open) {
    document.body.classList.remove('conversation-drawer-open', 'files-drawer-open');
    elements['mobile-conversation'].setAttribute('aria-expanded', 'false');
    elements['mobile-files'].setAttribute('aria-expanded', 'false');
    document.body.classList.add('drawer-open');
  } else if (!document.body.classList.contains('conversation-drawer-open') && !document.body.classList.contains('files-drawer-open')) {
    document.body.classList.remove('drawer-open');
  }
});
elements['session-file-list'].addEventListener('click', event => { if (event.target.closest('a')) closeMobileDrawers(); });
elements.activity.addEventListener('click', () => {
  setActivityExpanded(elements.activity.getAttribute('aria-expanded') !== 'true');
  if (elements.activity.getAttribute('aria-expanded') === 'true' && current) renderDispatcherPanel(current);
});
addEventListener('keydown', event => { if (event.key === 'Escape') closeMobileDrawers(); });
addEventListener('resize', () => {
  syncHeaderMenus();
  if (!compactViewport()) closeMobileDrawers();
  renderLiveClocks();
  resizeComposer();
});
elements['settings-button'].addEventListener('click', () => {
  elements.settings.hidden = !elements.settings.hidden;
  elements['settings-button'].setAttribute('aria-expanded', String(!elements.settings.hidden));
});
document.addEventListener('pointerdown', event => {
  if (elements.settings.hidden) return;
  if (elements.settings.contains(event.target) || elements['settings-button'].contains(event.target)) return;
  elements.settings.hidden = true;
  elements['settings-button'].setAttribute('aria-expanded', 'false');
});
for (const [id, key] of [['theme','theme'], ['view','view']]) elements[id].addEventListener('change', () => { preferences[key] = elements[id].value; savePreferences(); });
elements['message-font-size'].addEventListener('change', () => { preferences.messageFontSize = Number(elements['message-font-size'].value); savePreferences(); });
for (const [id, key] of [['show-ids','showIds'], ['show-time','showTime'], ['show-status','showStatus'], ['show-dispatch','showDispatch'], ['show-counts','showCounts']]) {
  elements[id].addEventListener('change', () => { preferences[key] = elements[id].checked; savePreferences(); });
}
elements['close-help'].addEventListener('click', () => elements['help-dialog'].close());
elements['help-button'].addEventListener('click', openHelp);
elements['help-search'].addEventListener('input', filterHelp);
elements['close-identity'].addEventListener('click', () => elements['identity-dialog'].close());
elements['identity-form'].addEventListener('submit', async event => {
  event.preventDefault();
  const human = (current?.humans || []).find(item => item.id === elements['identity-id'].value);
  if (!human) return;
  const button = event.submitter;
  try {
    if (button) button.disabled = true;
    elements['identity-status'].textContent = 'Signing in…';
    await authenticateHumanIdentity(human, elements['identity-password'].value, elements['identity-remember'].checked);
    elements['identity-dialog'].close();
    showNotice(`You are now identified as ${human.displayName} on this browser.`);
  } catch (error) { elements['identity-status'].textContent = error.message; }
  finally { if (button) button.disabled = false; }
});
elements['security-form'].addEventListener('submit', async event => {
  event.preventDefault();
  const button = event.submitter;
  try {
    if (button) button.disabled = true;
    elements['security-form-status'].textContent = 'Saving…';
    const result = await action('saveSecurity', { requireLanPairing: elements['require-lan-pairing'].checked });
    current.security = result.result?.security || current.security;
    elements['security-form-status'].textContent = '';
    renderSecuritySettings();
    showNotice(current.security.requireLanPairing ? 'Home-network device pairing is required.' : 'Device pairing is disabled. Any device on this network can open Demi; protected identities still require their own password.');
  } catch (error) { elements['security-form-status'].textContent = error.message; }
  finally { if (button) button.disabled = false; }
});
elements['close-connection-qr'].addEventListener('click', () => elements['connection-qr-dialog'].close());
elements['close-project'].addEventListener('click', () => elements['project-dialog'].close());
elements['project-form'].addEventListener('submit', saveProjectForm);
elements['open-storage'].addEventListener('click', openStorageDialog);
elements['close-storage'].addEventListener('click', () => elements['storage-dialog'].close());
elements['storage-save'].addEventListener('click', event => runStorageAction('saveStorageSetup', event.currentTarget));
elements['storage-test'].addEventListener('click', event => runStorageAction('testStorage', event.currentTarget));
elements['storage-provision'].addEventListener('click', event => runStorageAction('provisionStorage', event.currentTarget, 'Create the configured database and generate a new Demi application credential?'));
elements['storage-migrate'].addEventListener('click', event => runStorageAction('migrateStorage', event.currentTarget));
elements['storage-preview'].addEventListener('click', event => runStorageAction('previewStorageImport', event.currentTarget));
elements['storage-import'].addEventListener('click', event => runStorageAction('importAndSwitchStorage', event.currentTarget, 'Import file-based sessions and project memory, then switch Demi to PostgreSQL? Existing matching records will be updated, not duplicated.'));
elements['storage-files'].addEventListener('click', event => runStorageAction('switchStorageFiles', event.currentTarget, 'Switch new session storage back to files? PostgreSQL data will not be deleted.'));
elements['cancel-image-generation-top'].addEventListener('click', () => elements['image-confirm-dialog'].close());
elements['cancel-image-generation'].addEventListener('click', () => elements['image-confirm-dialog'].close());
elements['confirm-image-generation'].addEventListener('click', confirmImageGeneration);
elements['close-timeline'].addEventListener('click', () => elements['timeline-dialog'].close());
elements['timeline-form'].addEventListener('submit', saveTimelineEvent);
elements['delete-timeline'].addEventListener('click', deleteTimelineEvent);
elements['timeline-focus'].addEventListener('change', () => {
  const option = [...elements['timeline-references'].options].find(item => item.value === elements['timeline-focus'].value);
  if (option) option.selected = true;
});
elements['draft-button'].addEventListener('click', openDraftDialog);
elements['new-session'].addEventListener('click', openNewSessionDialog);
elements['sessions-button'].addEventListener('click', () => { renderSessionCatalog(current?.sessions || []); elements['sessions-dialog'].showModal(); });
elements['close-sessions'].addEventListener('click', () => elements['sessions-dialog'].close());
elements['close-sessions-top'].addEventListener('click', () => elements['sessions-dialog'].close());
elements['agents-button'].addEventListener('click', () => { renderHumans(); renderAgents(); elements['add-human'].hidden = !providerConfigurationAllowed(); elements['add-agent'].hidden = !providerConfigurationAllowed(); elements['agent-form'].hidden = true; elements['agents-dialog'].classList.remove('editing-agent'); elements['agents-dialog'].scrollTop = 0; elements['agents-dialog'].showModal(); });
function closeAgentsDialog() { elements['agents-dialog'].classList.remove('editing-agent'); elements['agents-dialog'].close(); }
elements['close-agents'].addEventListener('click', closeAgentsDialog);
elements['close-agents-top'].addEventListener('click', closeAgentsDialog);
elements['add-agent'].addEventListener('click', () => openAgentForm());
elements['add-human'].addEventListener('click', openHumanForm);
elements['close-human'].addEventListener('click', () => elements['human-dialog'].close());
elements['human-form'].addEventListener('submit', createHumanProfile);
elements['cancel-agent'].addEventListener('click', () => { elements['agent-form'].hidden = true; elements['agents-dialog'].classList.remove('editing-agent'); });
elements['agent-form'].addEventListener('submit', saveAgentForm);
elements['agents-dialog'].addEventListener('close', () => elements['agents-dialog'].classList.remove('editing-agent'));
elements['agent-kind'].addEventListener('change', () => { updateAgentProviderFields(); if (elements['agent-kind'].value === 'HTTP' && !elements['agent-base-url'].value) applyHttpPreset(); });
elements['agent-http-provider'].addEventListener('change', applyHttpPreset);
elements['agent-icon-picker'].addEventListener('change', () => {
  if (elements['agent-icon-picker'].value !== 'custom') elements['agent-icon'].value = elements['agent-icon-picker'].value;
  else { elements['agent-icon'].focus(); elements['agent-icon'].select(); }
});
elements['agent-icon'].addEventListener('input', () => {
  elements['agent-icon-picker'].value = [...elements['agent-icon-picker'].options].some(option => option.value === elements['agent-icon'].value) ? elements['agent-icon'].value : 'custom';
});
elements['cancel-new-session'].addEventListener('click', () => {
  elements['new-session-dialog'].dataset.composerCommand = '';
  elements['new-session-dialog'].close();
});
elements['confirm-new-session'].addEventListener('click', confirmNewSession);
elements['close-draft'].addEventListener('click', () => elements['draft-dialog'].close());
elements['draft-form'].addEventListener('submit', generateDraft);
elements['draft-save-md'].addEventListener('click', () => savePendingDraft('md'));
elements['draft-save-docx'].addEventListener('click', () => savePendingDraft('docx'));
elements['draft-revise'].addEventListener('click', () => {
  elements['draft-form'].hidden = false;
  elements['draft-preview'].hidden = true;
  elements['draft-request'].value = `Revise the previous draft titled "${pendingDraft?.title || 'draft'}":\n\n`;
  elements['draft-request'].focus();
});
elements['draft-rowan'].addEventListener('click', () => {
  const reviewer = pendingDraft?.reviewer || elements['draft-reviewer'].value;
  if (!reviewer) return showNotice('Choose a reviewer before requesting a review.');
  if (pendingDraft) action('direct', { agent: reviewer, text: `Review the proposed draft ${pendingDraft.entry}: ${pendingDraft.title}. Identify material problems and recommended revisions; do not rewrite or approve it as canon.` }).catch(() => {});
});
elements['draft-discard'].addEventListener('click', discardDraft);
bootstrap();
setInterval(renderLiveClocks, 1000);
