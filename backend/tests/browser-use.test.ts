import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BrowserUse, ResearchJob, ProviderRejected } from '../src/browser-use';

function fixture(options: {lost?: boolean; status?: string; rejected?: boolean} = {}) {
  let stored: any, alarm: number | undefined, creates = 0, stops = 0, cancels = 0;
  let status = options.status ?? 'running';
  const input = {id: 'job_' + 'b'.repeat(32), prompt: 'History of Stockholm City Hall', timeoutSeconds: 30};
  const provider = {
    async create() { creates++; if (options.rejected) throw new ProviderRejected('browser_use_credit_limit', true); if (options.lost) throw new Error('lost response'); return {id: 'run', sessionId: 'session'}; },
    async reconcile() { return {id: 'run', sessionId: 'session'}; },
    async stopBrowsers() { stops++; },
    async json(path: string) {
      if (path.endsWith('/cancel')) { cancels++; status = 'cancelled'; }
      return {status, result: 'Verified history https://example.com'};
    }
  } as unknown as BrowserUse;
  const ctx = {storage: {
    async get() { return stored && structuredClone(stored); },
    async put(_key: string, value: any) { stored = structuredClone(value); },
    async setAlarm(value: number) { alarm = value; }, async deleteAlarm() { alarm = undefined; }
  }, waitUntil(p: Promise<any>) { void p; }} as unknown as DurableObjectState;
  const make = () => new ResearchJob(ctx, {}, provider);
  const job = make();
  const submit = (body = input, target = job) => target.fetch(new Request('https://internal/submit', {method: 'POST', body: JSON.stringify(body)}));
  return {job, input, submit, make, setStatus: (s: string) => {status = s}, state: () => ({stored, alarm, creates, stops, cancels})};
}
test('durable retries and concurrent submits never create duplicate paid runs', async () => {
  const f = fixture();
  const results = await Promise.all([f.submit(), f.submit(), f.submit()]);
  assert.ok(results.every(r => r.ok)); assert.equal(f.state().creates, 1);
  assert.equal((await f.submit({...f.input, prompt: 'different'})).status, 409);
  await f.submit(f.input, f.make()); assert.equal(f.state().creates, 1);
});
test('lost provider response reconciles instead of resubmitting, including after restart', async () => {
  const f = fixture({lost: true}); await f.submit(); await f.submit(f.input, f.make());
  assert.equal(f.state().creates, 1); await f.make().alarm();
  assert.equal(f.state().stored.runId, 'run'); assert.equal(f.state().creates, 1);
});
test('completion fetches result and repeatedly stops owned browsers before clearing watchdog', async () => {
  const f = fixture({status: 'completed'}); await f.submit();
  await f.job.alarm(); assert.equal(f.state().stored.status, 'succeeded');
  assert.match(f.state().stored.result, /Verified/); assert.ok(f.state().alarm);
  await f.job.alarm(); await f.job.alarm();
  assert.equal(f.state().stops, 3); assert.equal(f.state().alarm, undefined);
});
test('watchdog enforces deadline even when phone stops polling', async () => {
  const f = fixture(); await f.submit({...f.input, timeoutSeconds: 0}); await f.job.alarm();
  assert.equal(f.state().cancels, 1); assert.equal(f.state().stored.status, 'timed_out');
});
test('cancel before submit leaves a tombstone and never starts a run', async () => {
  const f = fixture(); await f.job.fetch(new Request(`https://internal/cancel?id=${f.input.id}`, {method:'POST'}));
  const response = await f.submit(); assert.equal((await response.json() as any).status, 'cancelled'); assert.equal(f.state().creates, 0);
});
test('provider request uses server credential, cost limit, Flash low reasoning and no recording', async () => {
  let captured: any;
  const provider = new BrowserUse({BROWSER_USE_API_KEY:'secret'}, (async function(this: unknown, url: any, init: any) {
    assert.equal(this, globalThis); assert.equal(url, 'https://api.browser-use.com/api/v4/runs');
    assert.equal(init.redirect, 'manual'); captured = init; return Response.json({id:'run'});
  }) as typeof fetch);
  await provider.create({id:'job-test', prompt:'Test', status:'queued', createdAt:0, deadline:1, submitted:true, timeoutSeconds:30});
  const body = JSON.parse(captured.body);
  assert.equal(captured.headers['X-Browser-Use-API-Key'],'secret');
  assert.equal(body.model,'gemini-3.6-flash'); assert.equal(body.modelParams.thinkingConfig.thinkingLevel,'low');
  assert.equal(body.maxCostUsd,.25); assert.equal(body.browserSettings.record,false); assert.equal(body.agentmail,false);
});

test('definitive credit rejection stops immediately without reconciliation or duplicate billing', async () => {
  const f = fixture({rejected: true}); const response = await f.submit();
  const body = await response.json() as any;
  assert.equal(body.status, 'failed'); assert.equal(body.error, 'browser_use_credit_limit');
  assert.equal(f.state().alarm, undefined); await f.submit(); assert.equal(f.state().creates, 1);
});
test('user cancellation persists across restart and stops provider run', async () => {
  const f = fixture(); await f.submit();
  await f.job.fetch(new Request(`https://internal/cancel?id=${f.input.id}`, {method:'POST'}));
  await f.job.alarm();
  assert.equal(f.state().stored.status, 'cancelled'); assert.equal(f.state().cancels, 1);
});
