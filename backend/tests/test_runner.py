import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

RUNNER = Path(__file__).resolve().parents[1] / 'matrix' / 'runner.py'

class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.fake = self.root / 'fake-codex'
        self.fake.write_text('#!' + sys.executable + '''
import sys, time, json
from pathlib import Path
prompt = sys.stdin.read()
if 'SLOW_JOB' in prompt: time.sleep(30)
Path('artifacts/proof.txt').write_text('shell and filesystem work')
Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text('done')
print(json.dumps({'type':'item.completed','item':{'type':'command_execution','status':'completed','command':'secret not exposed'}}))
''')
        self.fake.chmod(0o700)
        self.env = {**os.environ, 'ALOUD_JOBS_ROOT':str(self.root / 'jobs'), 'ALOUD_CODEX_BIN':str(self.fake), 'CODEX_HOME':str(self.root / 'config')}
        self.jobs = []
    def tearDown(self):
        for job in self.jobs:
            self.call('cancel',job)
        time.sleep(0.4)
        self.tmp.cleanup()
    def call(self,*args):
        result = subprocess.run([sys.executable,str(RUNNER),*args],env=self.env,capture_output=True,text=True,check=True)
        return json.loads(result.stdout)
    def submit(self,prompt='test',timeout=20,job=None):
        job = job or 'job_'+uuid.uuid4().hex
        self.jobs.append(job)
        payload = base64.b64encode(json.dumps({'id':job,'prompt':prompt,'timeoutSeconds':timeout}).encode()).decode()
        return self.call('submit',payload)
    def wait(self,job,statuses,timeout=15):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            data=self.call('status',job)['data']
            if data['status'] in statuses:return data
            time.sleep(0.1)
        self.fail('Job did not reach '+str(statuses))
    def test_detached_job_artifact_events_and_idempotency(self):
        data=self.submit()['data']; job=data['id']
        result=self.wait(job,{'succeeded'})
        self.assertEqual(result['result'],'done')
        self.assertEqual(result['mode'],'yolo')
        self.assertEqual(self.submit(job=job)['data']['id'],job)
        self.assertEqual(self.submit('different',job=job)['error'],'idempotency_conflict')
        self.assertEqual(base64.b64decode(self.call('artifact',job,'proof.txt')['data']['content']),b'shell and filesystem work')
        event=self.call('events',job,'0')['data']
        self.assertNotIn('secret',json.dumps(event))
        self.assertGreater(event['cursor'],0)
        self.assertEqual(self.call('events',job,str(event['cursor']))['data']['items'],[])
        self.assertEqual(self.call('artifact',job,'../../request.json')['error'],'artifact_not_found')
        (self.root/'jobs'/job/'work/artifacts/link').symlink_to(self.root/'jobs'/job/'request.json')
        self.assertEqual(self.call('artifact',job,'link')['error'],'artifact_not_found')
    def test_cancel_running_and_queued(self):
        job=self.submit('SLOW_JOB')['data']['id']
        self.wait(job,{'running'})
        queued=self.submit()['data']['id']
        self.assertEqual(self.call('status',queued)['data']['status'],'queued')
        self.assertEqual(self.call('cancel',queued)['data']['status'],'cancelled')
        self.call('cancel',job)
        self.assertEqual(self.wait(job,{'cancelled'})['status'],'cancelled')
    def test_timeout(self):
        job=self.submit('SLOW_JOB',10)['data']['id']
        self.assertEqual(self.wait(job,{'timed_out'})['status'],'timed_out')
    def test_yolo_and_mcp_approvals(self):
        spec=importlib.util.spec_from_file_location('runner',RUNNER); runner=importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
        config=self.root/'config';config.mkdir()
        (config/'config.toml').write_text('[mcp_servers.aloud-browser]\ncommand="node"\nargs=["cli.js","--output-dir","old"]\n[mcp_servers.aloud-browser.tools.browser_navigate]\napproval_mode="prompt"\n')
        previous=os.environ.get('CODEX_HOME');os.environ['CODEX_HOME']=str(config)
        try: args=runner.codex_command(self.root)
        finally:
            if previous is None:os.environ.pop('CODEX_HOME',None)
            else:os.environ['CODEX_HOME']=previous
        self.assertIn('--dangerously-bypass-approvals-and-sandbox',args)
        self.assertFalse(any('mcp_servers."' in arg for arg in args))
        self.assertTrue(any('default_tools_approval_mode="approve"' in arg for arg in args))
        self.assertTrue(any('browser_navigate.approval_mode="approve"' in arg for arg in args))
        self.assertTrue(any(str(self.root/'work/artifacts') in arg for arg in args))

if __name__=='__main__':unittest.main()
