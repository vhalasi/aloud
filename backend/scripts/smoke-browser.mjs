// Opt-in live Browser Use test; consumes credits, with each run capped at $0.25.
import assert from 'node:assert/strict';
import {client} from './client.mjs';
const api = await client(process.argv[2]);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const key = 'browser-smoke-' + crypto.randomUUID();
const body = JSON.stringify({prompt: 'Visit https://www.iana.org/help/example-domains and explain in two sentences why example.com exists. Include the source URL.', timeoutSeconds: 120});
const start = Date.now();
const submit = () => api('/v1/research', {method: 'POST', headers: {'Idempotency-Key': key}, body});
const first = await submit(); assert.equal(first.status, 202);
const job = await first.json(); const duplicate = await (await submit()).json(); assert.equal(duplicate.id, job.id);
async function wait(id, cleanup = false) {
  const deadline = Date.now() + 150_000;
  while (Date.now() < deadline) {
    const response = await api(`/v1/research/${id}`); assert.equal(response.status, 200);
    const result = await response.json();
    if (!['queued', 'running'].includes(result.status) && (!cleanup || result.cleanupComplete)) return result;
    await sleep(2000);
  }
  await api(`/v1/research/${id}/cancel`, {method: 'POST'});
  throw new Error('Research/cleanup timed out; cancellation requested');
}
const result = await wait(job.id);
assert.equal(result.status, 'succeeded'); assert.match(result.result, /iana\.org/); assert.match(result.result, /document/i);
console.log(JSON.stringify({id: job.id, seconds: (Date.now() - start) / 1000, result: result.result}));
assert.equal((await wait(job.id, true)).cleanupComplete, true);
const cancelResponse = await api('/v1/research', {method:'POST', headers:{'Idempotency-Key':'browser-cancel-'+crypto.randomUUID()},
  body:JSON.stringify({prompt:'Research the history of Stockholm City Hall using three official sources.', timeoutSeconds:120})});
assert.equal(cancelResponse.status,202); const cancelled = await cancelResponse.json();
await api(`/v1/research/${cancelled.id}/cancel`, {method:'POST'});
const stopped = await wait(cancelled.id, true);
assert.equal(stopped.status, 'cancelled'); assert.equal(stopped.cleanupComplete, true);
const matrix = await api('/v1/computer'); assert.equal(matrix.status,200);
console.log('PASS: sourced research, retry identity, cancellation, browser cleanup, retained Matrix connectivity.');
