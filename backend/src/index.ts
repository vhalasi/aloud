import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { bodyLimit } from 'hono/body-limit';
import { bearerAuth } from 'hono/bearer-auth';
import { z } from 'zod';
import { ApiError, Matrix, type Bindings, type Executor } from './matrix';

export { ResearchJob } from './browser-use';

const input = z.object({prompt: z.string().trim().min(1).max(20_000),
  timeoutSeconds: z.number().int().min(10).max(600).default(180)}).strict();
const jobPattern = /^job_[a-f0-9]{32}$/;

export function createApp(factory: (env: Bindings) => Executor = env => new Matrix(env)) {
  const app = new Hono<{Bindings: Bindings}>();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    c.header('X-Content-Type-Options', 'nosniff');
    await next();
  });
  app.get('/health', c => c.json({ok: true, service: 'aloud-matrix-api'}));
  app.use('/v1/*', async (c, next) => {
    if (!c.env.API_TOKEN || c.env.API_TOKEN.length < 32) return c.json({error: 'api_not_configured'}, 503);
    return bearerAuth<{Bindings: Bindings}>({token: c.env.API_TOKEN})(c, next);
  });
  app.use('/v1/*', bodyLimit({maxSize: 100_000, onError: c => c.json({error: 'body_too_large'}, 413)}));
  // Browser research has its own durable lifecycle; Matrix routes below remain available.
  app.post('/v1/research', async c => {
    if (!c.env.RESEARCH_JOBS || !c.env.BROWSER_USE_API_KEY) return c.json({error: 'browser_use_not_configured'}, 503);
    let json: unknown;
    try { json = await c.req.json(); } catch { return c.json({error: 'invalid_json'}, 400); }
    const parsed = input.safeParse(json);
    if (!parsed.success) return c.json({error: 'invalid_job'}, 400);
    const key = c.req.header('Idempotency-Key');
    if (!key || !/^[a-zA-Z0-9_-]{8,128}$/.test(key)) return c.json({error: 'invalid_idempotency_key'}, 400);
    const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key));
    const id = 'job_' + Array.from(new Uint8Array(hash)).map(n => n.toString(16).padStart(2, '0')).join('').slice(0, 32);
    const stub = c.env.RESEARCH_JOBS.get(c.env.RESEARCH_JOBS.idFromName(id));
    const response = await stub.fetch('https://research.internal/submit', {method: 'POST', body: JSON.stringify({id, ...parsed.data})});
    return new Response(response.body, {status: response.ok ? 202 : response.status,
      headers: {'Content-Type': 'application/json', 'Location': `/v1/research/${id}`, 'Cache-Control': 'no-store'}});
  });
  app.on(['GET', 'POST'], ['/v1/research/:id', '/v1/research/:id/cancel'], async c => {
    const id = c.req.param('id')!;
    if (!jobPattern.test(id)) return c.json({error: 'invalid_job_id'}, 400);
    const cancelling = c.req.path.endsWith('/cancel');
    if ((cancelling && c.req.method !== 'POST') || (!cancelling && c.req.method !== 'GET')) return c.json({error: 'method_not_allowed'}, 405);
    if (!c.env.RESEARCH_JOBS) return c.json({error: 'browser_use_not_configured'}, 503);
    return c.env.RESEARCH_JOBS.get(c.env.RESEARCH_JOBS.idFromName(id)).fetch(`https://research.internal/${cancelling ? 'cancel' : 'status'}?id=${id}`, {method: cancelling ? 'POST' : 'GET'});
  });
  app.get('/v1/computer', async c => c.json(await factory(c.env).call('health')));
  app.post('/v1/jobs', async c => {
    let json: unknown;
    try { json = await c.req.json(); } catch { return c.json({error: 'invalid_json'}, 400); }
    const parsed = input.safeParse(json);
    if (!parsed.success) return c.json({error: 'invalid_job', details: parsed.error.issues.map(i => ({path: i.path, message: i.message}))}, 400);
    const key = c.req.header('Idempotency-Key');
    if (key !== undefined && !/^[a-zA-Z0-9_-]{8,128}$/.test(key)) return c.json({error: 'invalid_idempotency_key'}, 400);
    const hash = key ? await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key)) : null;
    const suffix = hash ? Array.from(new Uint8Array(hash)).map(n => n.toString(16).padStart(2, '0')).join('').slice(0, 32) : crypto.randomUUID().replaceAll('-', '');
    const id = `job_${suffix}`;
    // Return the same id even on ambiguous dispatch failure so callers can poll/retry safely.
    try {
      const job = await factory(c.env).call('submit', JSON.stringify({id, ...parsed.data}));
      c.header('Location', `/v1/jobs/${id}`);
      return c.json(job, 202);
    } catch (error) {
      if (error instanceof ApiError) return c.json({error: error.code, jobId: id, statusUrl: `/v1/jobs/${id}`}, error.status as any);
      throw error;
    }
  });
  app.use('/v1/jobs/:id/*', async (c, next) => {
    if (!jobPattern.test(c.req.param('id') ?? '')) return c.json({error: 'invalid_job_id'}, 400);
    await next();
  });
  app.get('/v1/jobs/:id', async c => {
    if (!jobPattern.test(c.req.param('id'))) return c.json({error: 'invalid_job_id'}, 400);
    return c.json(await factory(c.env).call('status', c.req.param('id')));
  });
  app.post('/v1/jobs/:id/cancel', async c => c.json(await factory(c.env).call('cancel', c.req.param('id'))));
  app.get('/v1/jobs/:id/events', async c => {
    const cursor = c.req.query('cursor') ?? '0';
    if (!/^\d{1,12}$/.test(cursor)) return c.json({error: 'invalid_cursor'}, 400);
    return c.json(await factory(c.env).call('events', c.req.param('id'), cursor));
  });
  app.get('/v1/jobs/:id/artifact', async c => {
    const path = c.req.query('path') ?? '';
    if (!path || path.length > 512 || path.startsWith('/') || path.split('/').includes('..') || /[\\\x00-\x1f]/.test(path)) {
      return c.json({error: 'invalid_artifact_path'}, 400);
    }
    const result = await factory(c.env).call('artifact', c.req.param('id'), path);
    const bytes = Uint8Array.from(atob(result.content), c => c.charCodeAt(0));
    const filename = path.split('/').at(-1)!.replace(/[^a-zA-Z0-9._-]/g, '_');
    c.header('Content-Disposition', `attachment; filename="${filename}"`);
    c.header('Content-Type', 'application/octet-stream');
    return c.body(bytes);
  });
  app.onError((error, c) => {
    if (error instanceof HTTPException) return error.getResponse();
    return c.json({error: error instanceof ApiError ? error.code : 'internal_error'},
      (error instanceof ApiError ? error.status : 500) as any);
  });
  app.notFound(c => c.json({error: 'not_found'}, 404));
  return app;
}
export default createApp();
