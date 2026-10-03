import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/index';
import { ApiError, Matrix, type Bindings } from '../src/matrix';
const env: Bindings = {API_TOKEN: 'test-'.repeat(10), MATRIX_ACCESS_TOKEN: 'principal-test', MATRIX_COMPUTER: 'primary', MATRIX_PLATFORM_URL: 'https://app.matrix-os.com', MATRIX_AUTH_URL: 'https://api.matrix-os.com', MATRIX_RUNNER_PATH: '/home/matrix/home/projects/aloud-research/api/runner.py'};
const id = 'job_' + 'a'.repeat(32);
function fixture() {
  const calls: any[] = [];
  const app = createApp(() => ({async call(operation, ...args) {
    calls.push([operation, ...args]);
    if (operation === 'submit') return {...JSON.parse(args[0]), status: 'queued'};
    if (operation === 'artifact') return {content: btoa('proof')};
    return {id, status: 'succeeded'};
  }}));
  const request = (path: string, options: RequestInit = {}) => app.request(path, {...options,
    headers: {'Authorization': `Bearer ${env.API_TOKEN}`, 'Content-Type': 'application/json', ...options.headers}}, env);
  return {app, calls, request};
}
test('auth fails closed without calling Matrix; health remains public', async () => {
  const {app, calls} = fixture();
  assert.equal((await app.request('/v1/computer', {}, env)).status, 401);
  assert.equal((await app.request('/v1/computer', {headers: {Authorization: 'Bearer wrong'}}, env)).status, 401);
  assert.equal((await app.request('/v1/computer', {}, {...env, API_TOKEN: ''})).status, 503);
  assert.equal((await app.request('/health', {}, env)).status, 200);
  assert.equal(calls.length, 0);
});
test('validates body and generates stable idempotent dispatch IDs', async () => {
  const {request, calls} = fixture();
  for (const body of [{prompt:''}, {prompt:'x', timeoutSeconds: 601}, {prompt:'x', arbitrary:'y'}]) {
    assert.equal((await request('/v1/jobs', {method:'POST', body:JSON.stringify(body)})).status, 400);
  }
  assert.equal(calls.length, 0);
  const options = {method:'POST', body:JSON.stringify({prompt:'hello; $(touch nope)'}), headers:{'Idempotency-Key':'smoke-test-123'}};
  const first = await request('/v1/jobs', options);
  const second = await request('/v1/jobs', options);
  assert.equal(first.status, 202);
  assert.equal((await first.json() as any).id, (await second.json() as any).id);
  assert.deepEqual(calls[0], calls[1]);
});
test('rejects malformed IDs, traversal, and bad cursors before dispatch', async () => {
  const {request,calls} = fixture();
  for (const path of ['/v1/jobs/bad', '/v1/jobs/bad/events', '/v1/jobs/bad/cancel', `/v1/jobs/${id}/artifact?path=../secret`, `/v1/jobs/${id}/events?cursor=-1`]) {
    assert.equal((await request(path, path.endsWith('cancel') ? {method:'POST'} : {})).status, 400, path);
  }
  assert.equal(calls.length,0);
  const response = await request(`/v1/jobs/${id}/artifact?path=proof.txt`);
  assert.equal(await response.text(),'proof');
  assert.match(response.headers.get('Content-Disposition')!,/attachment/);
});
test('dispatch failure returns recoverable job ID and hides unexpected errors', async () => {
  const app = createApp(() => ({async call() {throw new ApiError('matrix_unreachable',503)}}));
  const response = await app.request('/v1/jobs', {method:'POST', headers:{Authorization:`Bearer ${env.API_TOKEN}`, 'Content-Type':'application/json'}, body:JSON.stringify({prompt:'test'})},env);
  assert.equal(response.status,503);
  assert.match((await response.json() as any).jobId,/^job_[a-f0-9]{32}$/);
  const broken = createApp(() => ({async call() {throw new Error('private-secret')}}));
  const result = await broken.request('/v1/computer',{headers:{Authorization:`Bearer ${env.API_TOKEN}`}},env);
  assert.deepEqual(await result.json(),{error:'internal_error'});
});
test('Matrix exchanges tokens and submits chunked argv without a shell', async () => {
  const calls: {url:string, options:RequestInit}[] = [];
  const request = async (url: any, options: any) => {
    calls.push({url:String(url),options});
    return Response.json(calls.length===1 ? {items:[{runtimeSlot:'primary',handle:'maxgfeller',availability:'available'}]} : calls.length===2 ? {slot:'primary',handle:'maxgfeller',accessToken:'runtime-test',expiresAt:Date.now()+10000} : {exitCode:0,stdout:JSON.stringify({ok:true,data:{id}})});
  };
  const body = JSON.stringify({id,prompt:'héllo; $(id)'.repeat(1500)});
  const matrix = new Matrix(env,request as typeof fetch);
  assert.deepEqual(await matrix.call('submit',body),{id});
  const command = JSON.parse(calls[2].options.body as string).command;
  assert.deepEqual(command.slice(0,3),['/usr/bin/python3',env.MATRIX_RUNNER_PATH,'submit']);
  assert.ok(command.every((arg:string)=>arg.length<=4096));
  assert.equal(Buffer.from(command.slice(3).join(''),'base64').toString(),body);
  assert.equal((calls[2].options.headers as any).Authorization,'Bearer runtime-test');
});
test('Matrix maps expired auth and runner conflicts to useful errors', async () => {
  await assert.rejects(new Matrix(env,(async()=>new Response('',{status:401})) as typeof fetch).call('health'), {code:'matrix_auth_required',status:503});
  let n=0;
  const matrix = new Matrix(env,(async()=>Response.json(++n===1 ? {items:[{runtimeSlot:'primary',handle:'maxgfeller',availability:'available'}]} : n===2 ? {slot:'primary',handle:'maxgfeller',accessToken:'runtime-test',expiresAt:Date.now()+10000} : {exitCode:0,stdout:JSON.stringify({ok:false,error:'idempotency_conflict'})})) as typeof fetch);
  await assert.rejects(matrix.call('submit','{}'), {code:'idempotency_conflict',status:409});
});
