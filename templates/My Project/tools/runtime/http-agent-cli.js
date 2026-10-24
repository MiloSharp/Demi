'use strict';

const { runAgent } = require('./provider-runtime');

const root = process.argv[2];
const handle = process.argv[3];
const usagePath = process.argv[4];
let prompt = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { prompt += chunk; });
process.stdin.on('end', async () => {
  try {
    const result = await runAgent(root, handle, prompt, { timeoutMilliseconds: Number(process.env.DEMI_HTTP_TIMEOUT_MS || 900000) });
    if (usagePath && result.usage) require('fs').writeFileSync(usagePath, JSON.stringify(result.usage), 'utf8');
    process.stdout.write(result.text);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
});
