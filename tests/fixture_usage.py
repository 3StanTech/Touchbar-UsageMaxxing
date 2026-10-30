"""Loopback fixture for the usage reader and verification app.

Serves synthetic Claude/Codex usage and token endpoints on 127.0.0.1 and writes
an isolated test config. Every artifact stays under USAGE_TEST_ROOT; only
synthetic credentials are used.
"""
import json,subprocess,threading,time,os
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
W=Path(os.environ['USAGE_TEST_ROOT']).resolve()
# Fixture traffic and its synthetic auth must never leave 127.0.0.1: drop inherited proxies.
for _key in [k for k in os.environ if k.lower() in ('http_proxy','https_proxy','all_proxy')]:del os.environ[_key]
os.environ['NO_PROXY'] = os.environ['no_proxy'] = '*'
def guard(path):
 p=Path(path).resolve()
 if not p.is_relative_to(W) or p==W:raise ValueError('Fixture artifacts must stay under USAGE_TEST_ROOT')
 return p
class Fixture:
 def __init__(self,script,out,tag):
  self.script=guard(script);self.root=guard(out)/tag;self.root.mkdir(parents=True,exist_ok=True)
  self.cache=self.root/'cache';self.cache.mkdir(exist_ok=True)
  self.config=self.root/'config.json';self.requests=[];self.lock=threading.Lock()
  self.rows={'claude':(27,45),'codex':(12,40)};self.count={'claude':0,'codex':0};self.hold={}
  self.ends={'claude':(int(time.time()+3600),int(time.time()+86400)),'codex':(int(time.time()+3600),int(time.time()+86400))}
  self.partial=None;self.slow=0;self.token_mode='ok';self.token_posts=[];self.sequence={'claude':[], 'codex':[]}
  outer=self
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_GET(self):
    provider=self.path.strip('/')
    if provider not in outer.count:self.send_error(404);return
    with outer.lock:
     outer.count[provider]+=1;index=outer.count[provider];entry={'provider':provider,'index':index,'start':time.time(),'auth':self.headers.get('Authorization')};outer.requests.append(entry)
    control=outer.sequence[provider].pop(0) if outer.sequence[provider] else {}
    five,week=control.get('rows',outer.rows[provider]);ends=outer.ends[provider]
    if control.get('delay'):time.sleep(control['delay'])
    code=control.get('status',200)
    if code!=200:
     entry.update(complete=time.time(),status=code);self.send_response(code)
     # retry=None omits Retry-After entirely.
     if control.get('retry',0) is not None:self.send_header('Retry-After',str(control.get('retry',0)))
     self.end_headers();return
    # hold[provider] (a threading.Event) keeps the response until the test releases it.
    if outer.hold.get(provider):outer.hold[provider].wait(30)
    if outer.slow:time.sleep(outer.slow)
    if provider=='claude':
     body={'five_hour':{'utilization':five,'resets_at':ends[0]},'seven_day':{'utilization':week,'resets_at':ends[1]}}
     if control.get('partial',outer.partial):body.pop(control.get('partial',outer.partial),None)
    else:body={'rate_limit':{'primary_window':{'used_percent':five,'limit_window_seconds':18000,'reset_at':ends[0]},'secondary_window':{'used_percent':week,'limit_window_seconds':604800,'reset_at':ends[1]}}}
    entry.update(complete=time.time(),five=five,week=week,reset=ends[0])
    self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
    try:
     raw=(control.get('raw') or json.dumps(body)).encode()
     for byte in raw:
      self.wfile.write(bytes([byte]));self.wfile.flush()
    except (BrokenPipeError,ConnectionResetError):pass
   def do_POST(self):
    if self.path!='/token':self.send_error(404);return
    body=json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}');n=len(outer.token_posts)+1;outer.token_posts.append(body)
    if outer.token_mode=='invalid':self.send_response(400);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"error":"invalid_grant"}');return
    if outer.token_mode=='rate':self.send_response(429);self.send_header('Retry-After','600');self.end_headers();return
    if outer.token_mode=='malformed':self.send_response(200);self.end_headers();self.wfile.write(b'{}');return
    reply={'access_token':f'renewed-access-{n}','refresh_token':f'renewed-refresh-{n}','expires_in':28800,'scope':body.get('scope','')}
    self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
    try:
     for byte in json.dumps(reply).encode():
      self.wfile.write(bytes([byte]));self.wfile.flush()
    except (BrokenPipeError,ConnectionResetError):pass
  self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=self.server.serve_forever,daemon=True).start()
  self.cfg={'cache_dir':str(self.cache),'claude_url':f'http://127.0.0.1:{self.server.server_port}/claude','codex_url':f'http://127.0.0.1:{self.server.server_port}/codex','claude_credentials':[{'accessToken':'synthetic-primary'}],'codex_auth':{'access_token':'synthetic-codex','account_id':'fixture'}}
  self.config.write_text(json.dumps(self.cfg))
 def enable_store(self,expires_ms,refresh='stored-refresh'):
  home=self.root/'claude-home';home.mkdir(exist_ok=True);store=self.root/'claude-store.json'
  for lock in (home/'.oauth_refresh.lock',Path(str(home.resolve())+'.lock')):
   if lock.exists():lock.rmdir()
  store.write_text(json.dumps({'claudeAiOauth':{'accessToken':'expired-access','refreshToken':refresh,'expiresAt':expires_ms,'scopes':['user:inference','user:profile'],'subscriptionType':'max'},'mcpOAuth':{'keep':'me'}}))
  self.cfg.update(claude_store_file=str(store),claude_home=str(home),claude_token_url=f'http://127.0.0.1:{self.server.server_port}/token',claude_credentials=[]);self.config.write_text(json.dumps(self.cfg));self.token_posts.clear()
  return store,home
 def command(self,provider='all',reason='automatic',payload=None,only=False):
  args=[str(self.script),'--format','slots','--provider',provider,'--refresh-reason',reason,'--test-config',str(self.config)]
  if only:args.append('--cache-only')
  p=subprocess.run(args,input=json.dumps(payload or {}),capture_output=True,text=True,timeout=100)
  if p.returncode:raise AssertionError(p.stderr)
  return json.loads(p.stdout)
 def advance(self,provider='claude',age=61):
  path=self.cache/f'statusline-{provider}-weekly.json';data=json.loads(path.read_text())
  for key in ('fetched_at','five_hour_fetched_at','seven_day_fetched_at'):data[key]=time.time()-age
  path.write_text(json.dumps(data));meta=path.with_name(path.name+'.refresh.json');d=json.loads(meta.read_text());d['next_attempt_at']=time.time()-1;d['next_manual_at']=time.time()-1;meta.write_text(json.dumps(d))
 def reset(self):
  for path in self.cache.iterdir():path.unlink()
  self.requests.clear();self.count={'claude':0,'codex':0};self.partial=None;self.slow=0;self.hold={}
 def wait_requests(self,provider,n,timeout=10):
  """Until the fixture has received n requests for provider (a handshake, not a sleep)."""
  end=time.time()+timeout
  while self.count[provider]<n:
   if time.time()>end:raise AssertionError(f'{provider} request {n} never arrived')
   time.sleep(.02)
 def close(self):self.server.shutdown();self.server.server_close()
