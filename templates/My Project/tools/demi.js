#!/usr/bin/env node
'use strict';

const path = require('path');
const { spawnSync } = require('child_process');
const { nativeCommands, runNativeCommand } = require('./runtime/session-runtime');

const root = path.resolve(__dirname, '..');
const [command = 'help', ...args] = process.argv.slice(2);
(async () => { try {
  if (command.toLowerCase() === 'checkin') {
    const timeoutAt = args.findIndex(value => String(value).toLowerCase() === '-agenttimeoutseconds');
    const timeout = timeoutAt >= 0 ? Number(args[timeoutAt + 1]) : 60;
    const result = await require('./runtime/provider-runtime').checkIn(root, args[0], timeout);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(result.online ? 0 : 1);
  }
  if (nativeCommands.has(command.toLowerCase())) {
    process.stdout.write(`${runNativeCommand(root, command.toLowerCase(), args)}\n`);
    process.exit(0);
  }
  const powershell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const result = spawnSync(powershell, ['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'demi.ps1'),command,...args], {
    cwd: root, stdio: 'inherit', windowsHide: true, env: process.env
  });
  if (result.error) throw result.error;
  process.exit(result.status == null ? 1 : result.status);
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
} })();
