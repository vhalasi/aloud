import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { client } from './client.mjs';
const base = process.argv[2] ?? process.env.ALOUD_API_URL;
const request = await client(base);
assert.equal((await fetch(new URL('/v1/computer',base))).status,401,'Unauthenticated request must fail');
const health=await (await request('/v1/computer')).json();
assert.equal(health.mode,'yolo');
console.log('Authentication and remote YOLO runner: OK');
const nonce=crypto.randomUUID();
const prompt=`Verify this Matrix computer by actually performing these actions with tools. Use only this job's current working directory for new files.
1. Create artifacts/numbers.csv with header value and rows 2, 3, 5, 7. Use Python to read it and compute the sum.
2. Create site/index.html with a heading "Aloud Matrix demo" and a button labeled "Reveal result" that changes a paragraph to "Sum: 17" when clicked. Start a temporary HTTP server bound to 127.0.0.1 on a free port.
3. Use the configured aloud-browser MCP to open that local HTTP page and click the button. Save a screenshot in artifacts/local-browser.png and verify the resulting text.
4. Use that browser to open https://example.com and follow its Learn more link. Verify the final URL and heading. Save a screenshot in artifacts/public-browser.png.
5. Save artifacts/proof.json with fields nonce ("${nonce}"), sum (number), localButtonText (visible text), publicURL (actual final URL), publicHeading (actual heading), browserUsed (boolean), shellUsed (boolean). Stop only the temporary HTTP server you started. Report the verified actions. Do not merely describe a plan.`;
const options={method:'POST',headers:{'Idempotency-Key':`smoke-${nonce}`},body:JSON.stringify({prompt,timeoutSeconds:420})};
const job=await (await request('/v1/jobs',options)).json();
console.log(`Created ${job.id}; status ${job.status}`);
const repeated=await (await request('/v1/jobs',options)).json();
assert.equal(repeated.id,job.id,'Retry must reuse job');
// Confirm queued cancellation while the real job owns the cloud computer.
const queued=await (await request('/v1/jobs',{method:'POST',body:JSON.stringify({prompt:'Write artifacts/cancelled.txt containing should-not-run.',timeoutSeconds:30})})).json();
const cancelled=await (await request(`/v1/jobs/${queued.id}/cancel`,{method:'POST'})).json();
assert.ok(['cancelled','running'].includes(cancelled.status));
let result;
for (let attempt=0;attempt<100;attempt++) {
  result=await (await request(`/v1/jobs/${job.id}`)).json();
  if (['succeeded','failed','timed_out','cancelled'].includes(result.status)) break;
  if(attempt%3===0) console.log(`Job ${result.status}`);
  await new Promise(resolve=>setTimeout(resolve,5000));
}
console.log(`Job ${result.status}`);
assert.equal(result.status,'succeeded',JSON.stringify(result));
const proof=await (await request(`/v1/jobs/${job.id}/artifact?path=proof.json`)).json();
assert.equal(proof.nonce,nonce); assert.equal(proof.sum,17);
assert.equal(proof.localButtonText,'Sum: 17'); assert.equal(proof.browserUsed,true); assert.equal(proof.shellUsed,true);
assert.equal(new URL(proof.publicURL).hostname,'www.iana.org');
assert.match(proof.publicHeading,/Example Domains/i);
const events=await (await request(`/v1/jobs/${job.id}/events`)).json();
assert.ok(events.items.some(item=>item.itemType==='mcp_tool_call'));
const cancelledStatus=await (await request(`/v1/jobs/${queued.id}`)).json();
assert.equal(cancelledStatus.status,'cancelled');
const output=process.env.ALOUD_SMOKE_OUTPUT ?? '.smoke';
await mkdir(output,{recursive:true});
await writeFile(resolve(output,'result.json'),JSON.stringify({job:result,proof,events,cancelledJob:cancelledStatus},null,2));
for(const artifact of result.artifacts.filter(item=>item.path.endsWith('.png'))) {
  const response=await request(`/v1/jobs/${job.id}/artifact?path=${encodeURIComponent(artifact.path)}`);
  await writeFile(resolve(output,artifact.path.split('/').at(-1)),Buffer.from(await response.arrayBuffer()));
}
console.log(JSON.stringify({jobId:job.id,proof,artifacts:result.artifacts},null,2));
console.log('PASS: auth, idempotency, cancellation, shell/files, local browser interaction, public browser navigation, artifact downloads.');
