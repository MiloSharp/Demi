'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

function credentialDirectory() {
  return process.env.DEMI_CREDENTIAL_DIR || path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), '.demiurge'), 'Demiurge', 'credentials');
}

function paths() {
  const directory = credentialDirectory();
  return { directory, key: path.join(directory, 'provider.key'), data: path.join(directory, 'providers.json') };
}

function ensureKey() {
  const files = paths();
  fs.mkdirSync(files.directory, { recursive: true, mode: 0o700 });
  if (!fs.existsSync(files.key)) fs.writeFileSync(files.key, crypto.randomBytes(32), { mode: 0o600 });
  const key = fs.readFileSync(files.key);
  if (key.length !== 32) throw new Error('Demi provider credential key is invalid.');
  return key;
}

function readStore() {
  const file = paths().data;
  if (!fs.existsSync(file)) return {};
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function writeStore(store) {
  const file = paths().data;
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(store, null, 2), { mode: 0o600 });
  fs.renameSync(temporary, file);
}

function saveCredential(id, secret) {
  if (!String(id || '').trim() || !String(secret || '')) throw new Error('A credential name and API key are required.');
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', ensureKey(), iv);
  const ciphertext = Buffer.concat([cipher.update(String(secret), 'utf8'), cipher.final()]);
  const store = readStore();
  store[id] = { iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), ciphertext: ciphertext.toString('base64') };
  writeStore(store);
}

function getCredential(id) {
  const record = readStore()[id];
  if (!record) return null;
  const decipher = crypto.createDecipheriv('aes-256-gcm', ensureKey(), Buffer.from(record.iv, 'base64'));
  decipher.setAuthTag(Buffer.from(record.tag, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(record.ciphertext, 'base64')), decipher.final()]).toString('utf8');
}

function hasCredential(id) { return Boolean(readStore()[id]); }
function removeCredential(id) { const store = readStore(); if (store[id]) { delete store[id]; writeStore(store); } }

module.exports = { saveCredential, getCredential, hasCredential, removeCredential, credentialDirectory };
