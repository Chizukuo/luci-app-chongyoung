import { execFileSync } from 'node:child_process';
import path from 'node:path';

const url = process.argv[2];
if (!url) throw new Error('usage: node tests/ui/luci-interaction.mjs http://127.0.0.1:<port>');
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(url)) throw new Error('URL must be http://127.0.0.1:<numeric-port>');
const nodeDir = path.dirname(process.execPath);
const npx = process.platform === 'win32' ? path.join(nodeDir, 'npx.cmd') : path.join(nodeDir, 'npx');
const cli = (...args) => execFileSync(npx, ['--yes', '--package', '@playwright/cli', 'playwright-cli', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], shell: true });
cli('open', url, '--browser', 'msedge');
const result = cli('run-code', '--filename', 'tests/ui/luci-flow.js');
console.log(result.match(/### Result[\s\S]*?(?=###|$)/)?.[0]?.trim() ?? result.trim());
