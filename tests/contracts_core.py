#!/usr/bin/env python3
"""Core reader contracts: the real CLI against loopback HTTP with isolated synthetic auth and cache.

Run: USAGE_TEST_ROOT=<dir> python3 contracts_core.py <reader under root> <results.json>
"""
import json,os,subprocess,tempfile,time,threading,hashlib,sys
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
ROOT=Path(os.environ['USAGE_TEST_ROOT']).resolve()
WAITING_S=2.0  # below the reader's 2.5 s request timeout
# Fixture traffic and its synthetic auth must never leave 127.0.0.1: drop inherited proxies.
for _key in [k for k in os.environ if k.lower() in ('http_proxy','https_proxy','all_proxy')]:del os.environ[_key]
os.environ['NO_PROXY']=os.environ['no_proxy']='*'
SCRIPT=Path(sys.argv[1])
requests=[];mode={'claude':200,'codex':200,'slow':0,'retry':'120','hold':None}
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  provider=self.path.strip('/'); token=self.headers.get('Authorization','')
  entry={'provider':provider,'at':time.time(),'credential':'alternate' if token.endswith('alternate') else 'primary'};requests.append(entry)
  if provider=='claude':
   if mode['hold']:mode['hold'].wait(30)  # held until the test releases it
   time.sleep(mode['slow'])
  code=mode[provider]
  if code=='alternate': code=200 if token.endswith('alternate') else 401
  self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Retry-After',mode['retry'])
  if code==302:self.send_header('Location','https://api.anthropic.com/api/oauth/usage')
  self.end_headers()
  body={'five_hour':{'utilization':27,'resets_at':time.time()+3600},'seven_day':{'utilization':45,'resets_at':time.time()+86400}} if provider=='claude' else {'rate_limit':{'primary_window':{'used_percent':12,'limit_window_seconds':18000,'reset_at':int(time.time()+3600)},'secondary_window':{'used_percent':40,'limit_window_seconds':604800,'reset_at':int(time.time()+86400)}}}
  try:self.wfile.write(json.dumps(body if code==200 else {}).encode());entry['done']=time.time()
  except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
ROOT.joinpath('fixtures').mkdir(exist_ok=True)
results=[]
with tempfile.TemporaryDirectory(dir=ROOT/'fixtures') as tmp:
 root=Path(tmp);cache=root/'cache';cache.mkdir();config=root/'config.json'
 cfg={'cache_dir':str(cache),'claude_url':f'http://127.0.0.1:{server.server_port}/claude','codex_url':f'http://127.0.0.1:{server.server_port}/codex','claude_credentials':[{'accessToken':'synthetic-primary'},{'accessToken':'synthetic-alternate'}],'codex_auth':{'access_token':'synthetic-codex','account_id':'fixture'}};config.write_text(json.dumps(cfg))
 def cmd(provider='all',reason='manual',only=False,payload=None):
  args=[str(SCRIPT),'--format','slots','--provider',provider,'--refresh-reason',reason,'--test-config',str(config)]
  if only:args.append('--cache-only')
  q=subprocess.run(args,input=json.dumps(payload or {}),capture_output=True,text=True,timeout=100)
  assert q.returncode==0,q.stderr
  return json.loads(q.stdout)
 def reset():
  for p in cache.iterdir():p.unlink()
  requests.clear();mode.update(claude=200,codex=200,slow=0,retry='120',hold=None)
 def arrived(provider,n=1,timeout=10):
  # Handshake: the held request has reached the fixture (no fixed sleep).
  # Concurrency checks then require their step to finish within WAITING_S of that arrival, so the
  # held reader (2.5 s request timeout) was provably still waiting; a slow machine fails loudly.
  end=time.time()+timeout
  while len([r for r in requests if r['provider']==provider])<n:
   assert time.time()<end,provider+' request never arrived'
   time.sleep(.02)
 def passed(name):results.append({'scenario':name,'result':'pass'})
 reset();before=len(requests);x=cmd(only=True);assert set(x)=={'week','codex'} and len(requests)==before;passed('cache-only without credentials or HTTP')
 x=cmd('claude','automatic');assert set(x)=={'week'} and x['week']['five_hour']['pct']==27;passed('selected provider retains top-level key and usage schema')
 cmd('claude','manual');assert len(requests)==2
 cmd('claude','manual');assert len(requests)==2;passed('manual bypasses ordinary TTL once, repeated clicks stay bounded')
 reset();mode['claude']=302;x=cmd('claude');assert x['week']['error']=='usage_unavailable' and len(requests)==1;passed('test mode rejects redirects without forwarding synthetic credentials')
 reset();cfg['claude_credentials']=[{'accessToken':'expired','expiresAt':1}];config.write_text(json.dumps(cfg));x=cmd('claude');assert x['week']['fetch_error']=='sign_in_expired' and x['week']['error']=='usage_unavailable' and len(requests)==0;passed('expired reader credential stays diagnosed without asserting app logout')
 cfg['claude_credentials']=[{'accessToken':'synthetic-primary'},{'accessToken':'synthetic-alternate'}];config.write_text(json.dumps(cfg))
 reset();(cache/'statusline-codex-weekly.json').write_text(json.dumps({'percent':12,'fetched_at':time.time()}));x=cmd('codex','automatic');assert x['codex']['five_hour']['pct']==12 and len(requests)==1;passed('legacy partial Codex cache fetches missing five-hour window')
 reset();mode['claude']='alternate';x=cmd('claude');assert x['week']['error'] is None and len(requests)==2;passed('401 permits one distinct valid alternate')
 reset();mode['slow']=4;old={'percent':22,'five_hour_percent':33,'fetched_at':time.time()-600};(cache/'statusline-claude-weekly.json').write_text(json.dumps(old));x=cmd('claude');assert x['week']['error']=='network_error' and x['week']['five_hour']['pct']==33 and x['week']['fetched_at']==old['fetched_at'] and len(requests)==1;passed('network timeout keeps values/timestamps and never tries alternate')
 reset();mode['claude']=403;x=cmd('claude');assert x['week']['error']=='access_denied' and len(requests)==1
 for reason in ['manual','wake','provider-start']:cmd('claude',reason)
 assert len(requests)==1;passed('403 never tries alternate or bypasses retry deadline')
 reset();mode['claude']=429;x=cmd('claude');deadline=x['week']['retry_at']
 for reason in ['manual','wake','provider-start','automatic']:assert cmd('claude',reason)['week']['retry_at']==deadline
 assert len(requests)==1
 cmd('claude',payload={'rate_limits':{'five_hour':{'used_percentage':66,'resets_at':time.time()+1000}}})
 cmd('claude','manual');assert len(requests)==1;passed('429 survives manual, wake, native cache updates and new CLI processes')
 reset();mode['claude']=401;x=cmd('claude');assert x['week']['fetch_error']=='sign_in_expired' and x['week']['error']=='usage_unavailable' and len(requests)==2
 cfg['claude_credentials']=[{'accessToken':'synthetic-alternate'}];config.write_text(json.dumps(cfg));mode['claude']=200
 # Same rejected state cannot be hammered; move isolated persisted budget past deadline.
 meta=cache/'statusline-claude-weekly.json.refresh.json';meta.write_text(json.dumps({'next_attempt_at':time.time()-1})); cp_recover=cache/'statusline-claude-weekly.json'; recover=json.loads(cp_recover.read_text()); recover['retry_at']=time.time()-1; cp_recover.write_text(json.dumps(recover))
 x=cmd('claude','provider-start');assert x['week']['error'] is None;passed('recovered synthetic sign-in rechecks after bounded cooldown')
 reset();mode['hold']=threading.Event()
 args=[str(SCRIPT),'--format','slots','--provider','claude','--refresh-reason','manual','--test-config',str(config)]
 slow=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);arrived('claude')
 start=time.monotonic();x=cmd('codex');fast=time.monotonic()-start;claude_at=next(r['at'] for r in requests if r['provider']=='claude');codex_done=next(r['done'] for r in requests if r['provider']=='codex')
 assert x['codex']['five_hour']['pct']==12 and codex_done-claude_at<WAITING_S,(codex_done-claude_at)  # served while Claude was still waiting
 cached=cmd('claude',only=True);assert cached['week']['five_hour']['pct'] is None
 mode['hold'].set();slow.communicate(timeout=10);assert slow.returncode==0;passed('independent provider completes while Claude is held')
 reset();mode['hold']=threading.Event()
 slow=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);arrived('claude')
 native={'rate_limits':{'five_hour':{'used_percentage':66,'resets_at':time.time()+1000}}}
 cmd('claude',payload=native);during=time.time()-next(r['at'] for r in requests if r['provider']=='claude');mode['hold'].set();slow.communicate(timeout=10)
 # The native update landed while the API request was still in flight.
 assert during<WAITING_S,during;x=cmd('claude',only=True);assert x['week']['five_hour']['pct']==66;passed('native update arriving during HTTP wins')
 # Concurrent manual requests share the real interprocess lock and cooldown.
 reset();mode['slow']=1
 ps=[subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(6)]
 for p in ps:p.communicate(timeout=10);assert p.returncode==0
 assert len(requests)==1;passed('six concurrent manual requests coalesce')
 # Automatic native clock ticks obey the adaptive shared budget.
 reset();cmd('claude','automatic');assert len(requests)==1
 cmd('claude','automatic',payload={'trigger':'refresh_interval'});assert len(requests)==1
 cp=cache/'statusline-claude-weekly.json';d=json.loads(cp.read_text())
 for key in ('fetched_at','five_hour_fetched_at','seven_day_fetched_at'):d[key]=time.time()-61
 cp.write_text(json.dumps(d));(cache/'statusline-claude-weekly.json.refresh.json').write_text(json.dumps({'next_attempt_at':time.time()-1}));cmd('claude','automatic');assert len(requests)==2;passed('60-second automatic TTL includes native clock ticks')
 # Third distinct valid credential must be reached after two rejected candidates.
 reset();cfg['claude_credentials']=[{'accessToken':'synthetic-first'},{'accessToken':'synthetic-second'},{'accessToken':'synthetic-alternate'}];config.write_text(json.dumps(cfg));mode['claude']='alternate'
 x=cmd('claude');assert len(requests)==3 and x['week']['error'] is None;passed('401 tries all distinct valid candidates and reaches third')
 # Advance only fixture deadlines, never the live cache or wall clock.
 reset();mode.update(claude=429,retry='0');meta=cache/'statusline-claude-weekly.json.refresh.json'
 # Refused taps inside an episode do not escalate, so escalation is driven by automatic calls.
 for expected in [60,120,240,480,900,900]:
  started=time.time();x=cmd('claude','automatic');wait=x['week']['retry_at']-started
  assert expected<=wait<expected+3,(expected,wait)
  assert x['week']['error']=='usage_unavailable' and x['week']['fetch_error']=='rate_limited'
  n=len(requests)
  for reason in ['manual','wake','provider-start','automatic']:cmd('claude',reason)
  assert len(requests)==n
  d=json.loads(cp.read_text());d['retry_at']=time.time()-1;cp.write_text(json.dumps(d))
  # Manual calls also honour the 60 s attempt floor while failing.
  m=json.loads(meta.read_text());m['server_retry_at']=time.time()-1;m['next_attempt_at']=time.time()-1;m['recovery_next_at']=time.time()-1;m['last_attempt_started_at']=time.time()-61;[a.update(started_at=a['started_at']-61,completed_at=a.get('completed_at',a['started_at'])-61) for a in m.get('attempts',[])];meta.write_text(json.dumps(m))
 # One success after level 5 steps down to level 4 (480 s) and keeps recovery.
 mode['claude']=200;x=cmd('claude');assert x['week']['error'] is None and json.loads(meta.read_text())['rate_limit_failures']==4 and x['week']['recovery_successes']==1 and x['week']['request_interval_seconds']==480;passed('zero Retry-After backs off 60/120/240/480/900 and one success decays to 480 s while retaining recovery')
 reset();mode.update(claude=429,retry='1800');started=time.time();x=cmd('claude');assert x['week']['retry_at']-started>=1800;passed('long server retry deadline is never shortened')
 reset();cfg['claude_credentials']=[];config.write_text(json.dumps(cfg));x=cmd('claude');assert x['week']['error']=='usage_unavailable' and x['week']['fetch_error']=='sign_in_required' and not requests;passed('missing reader credential does not assert app logout')
server.shutdown()
report={'date':time.strftime('%Y-%m-%d'),'script_sha256':hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),'checks':results,'independent_codex_seconds':fast,'last_fixture_requests':requests,'scope':'real CLI/HTTP/cache contracts; does not prove physical display, actual login or live auth recovery'}
Path(sys.argv[2]).write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
