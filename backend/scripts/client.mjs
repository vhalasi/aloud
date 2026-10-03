import { credentials } from './matrix-client.mjs';
export async function client(base = process.env.ALOUD_API_URL) {
  if (!base) throw new Error('Set ALOUD_API_URL to your Worker URL');
  const { API_TOKEN } = await credentials();
  return async (path, options = {}) => {
    const response = await fetch(new URL(path, base), { ...options, redirect:'error', signal:AbortSignal.timeout(60_000),
      headers: {Authorization:`Bearer ${API_TOKEN}`, 'Content-Type':'application/json', ...options.headers}});
    if (!response.ok) throw new Error(`API ${response.status}: ${await response.text()}`);
    return response;
  };
}
