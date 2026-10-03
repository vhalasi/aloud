import { readFile, writeFile, chmod } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
const profile = process.env.MATRIX_PROFILE ?? 'cloud';
if (!/^[a-zA-Z0-9_-]+$/.test(profile)) throw new Error('Invalid Matrix profile');
const auth = JSON.parse(await readFile(join(homedir(), '.matrixos', 'profiles', profile, 'auth.json'), 'utf8'));
if (!auth.accessToken || auth.expiresAt <= Date.now()) throw new Error('Run matrix login --profile cloud first: token missing or expired');
let previous = {};
try { previous = JSON.parse(await readFile('.secrets.json', 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
const secrets = { ...previous, API_TOKEN: previous.API_TOKEN ?? randomBytes(32).toString('hex'), MATRIX_ACCESS_TOKEN: auth.accessToken };
for (const [file, content] of [
  ['.secrets.json', JSON.stringify(secrets, null, 2) + '\n'],
  ['.dev.vars', Object.entries(secrets).map(([key, value]) => `${key}=${JSON.stringify(value)}`).join('\n') + '\n']
]) {
  await writeFile(file, content, { mode: 0o600 });
  await chmod(file, 0o600);
}
console.log('Saved credentials in ignored .secrets.json and .dev.vars (mode 0600).');
console.log(`Matrix access token expires: ${new Date(auth.expiresAt).toISOString()}`);
