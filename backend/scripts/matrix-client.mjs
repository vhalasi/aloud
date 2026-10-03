import { readFile } from 'node:fs/promises';
export async function credentials() {
  return JSON.parse(await readFile(new URL('../.secrets.json', import.meta.url), 'utf8'));
}
export async function runtime() {
  const { MATRIX_ACCESS_TOKEN } = await credentials();
  const platform = process.env.MATRIX_PLATFORM_URL ?? 'https://app.matrix-os.com';
  const auth = process.env.MATRIX_AUTH_URL ?? 'https://api.matrix-os.com';
  const slot = process.env.MATRIX_COMPUTER ?? 'primary';
  async function json(url, token, options = {}) {
    const response = await fetch(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(25_000),
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }});
    if (!response.ok) throw new Error(`Matrix HTTP ${response.status}`);
    return response.json();
  }
  const inventory = await json(`${platform}/api/auth/computers`, MATRIX_ACCESS_TOKEN);
  const computer = inventory.items.find(item => item.runtimeSlot === slot && item.availability === 'available');
  if (!computer) throw new Error('Matrix computer unavailable');
  const selected = await json(`${auth}/api/auth/runtime-selection`, MATRIX_ACCESS_TOKEN,
    {method: 'POST', body: JSON.stringify({slot})});
  if (selected.handle !== computer.handle || selected.slot !== slot) throw new Error('Matrix runtime mismatch');
  const endpoint = path => {
    const url = new URL(`/vm/${computer.handle}${path}`, platform);
    if (slot !== 'primary') url.searchParams.set('runtime', slot);
    return url;
  };
  return {
    async run(command) {
      const result = await json(endpoint('/api/terminal/run'), selected.accessToken,
        {method: 'POST', body: JSON.stringify({command, timeoutMs: 10_000})});
      if (result.exitCode !== 0 || result.timedOut || result.truncated) throw new Error('Matrix command failed');
      return result.stdout;
    },
    async upload(path, contents) {
      const url = endpoint('/api/files/blob');
      url.searchParams.set('path', path); url.searchParams.set('force', 'true');
      const response = await fetch(url, {method: 'PUT', redirect: 'error', signal: AbortSignal.timeout(25_000),
        headers: {Authorization: `Bearer ${selected.accessToken}`, 'Content-Type': 'application/octet-stream'}, body: contents});
      if (!response.ok) throw new Error(`Matrix upload HTTP ${response.status}`);
    }
  };
}
