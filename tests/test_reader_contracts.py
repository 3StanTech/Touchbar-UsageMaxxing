#!/usr/bin/env python3
"""Reader contracts: polling boundaries, invalid input, freshness, native/API races,
test isolation and terminal sign-in renewal, through the real CLI and loopback HTTP.

Run: USAGE_TEST_ROOT=<dir> python3 test_reader_contracts.py --script <reader under root> --out <dir under root>
"""
import argparse,json,subprocess,sys,threading,time,hashlib
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from fixture_usage import Fixture,guard
parser=argparse.ArgumentParser();parser.add_argument('--script',required=True);parser.add_argument('--out',required=True);a=parser.parse_args();out=guard(a.out);out.mkdir(parents=True,exist_ok=True);script=guard(a.script);checks=[]
def passed(name):checks.append({'case':name,'result':'pass'})
def contracts():
 p=subprocess.run([sys.executable,str(HERE/'contracts_core.py'),str(script),str(out/'historical-contract-results.json')],capture_output=True,text=True,timeout=120)
 assert p.returncode==0,p.stdout+p.stderr
 old=json.loads((out/'historical-contract-results.json').read_text());checks.extend(old['checks'])
 f=Fixture(script,out,'boundary-fixture')
 try:
  for provider,key in [('claude','week'),('codex','codex')]:
   for five,week,interval in [(87.99,96.99,60),(88,96.99,30),(89.99,96.99,30),(90,96.99,30),(0,97,30),(0,97.99,30),(0,98,30)]:
    f.reset();f.rows[provider]=(five,week);x=f.command(provider)[key]
    assert x['poll_interval_seconds']==interval,(provider,five,week,x)
    assert all(x[w]['is_fresh'] for w in ['five_hour','seven_day'])
    n=len(f.requests)
    for reason in ['automatic','wake','provider-start']:
     y=f.command(provider,reason,payload={'trigger':'refresh_interval'})[key];assert len(f.requests)==n
    passed(f'{provider} boundaries {five}/{week}; caller budgets')
  for provider,key in [('claude','week'),('codex','codex')]:
   for invalid in [float('nan'),float('inf'),-1,101,True,None]:
    f.reset();f.rows[provider]=(invalid,invalid);x=f.command(provider)[key]
    assert x['five_hour']['pct'] is None and not x['five_hour']['is_fresh'] and not x['seven_day']['is_fresh'],(provider,invalid,x)
    passed(f'{provider} rejects invalid API percentages {invalid}')
  f.reset();f.rows['codex']=(float('nan'),float('nan'));x=f.command('codex')['codex'];assert x['error']=='usage_unavailable' and x['five_hour']['pct'] is None;passed('nonfinite Codex API percentages cannot become fresh limits')
  f.reset();f.rows['codex']=(12,40);f.ends['codex']=(10**20,10**20);x=f.command('codex')['codex'];assert not x['five_hour']['is_fresh'] and x['five_hour']['resets_at'] is None;passed('overflow Codex API reset is unknown, never a crash')
  f.ends['codex']=(int(time.time()+3600),int(time.time()+86400))
  f.reset();f.rows={'claude':(88,45),'codex':(12,40)};x=f.command();assert x['week']['poll_interval_seconds']==30 and x['codex']['poll_interval_seconds']==60;passed('provider independence')
  f.partial='seven_day';f.advance();x=f.command('claude')['week'];assert x['poll_interval_seconds']==30 and not x['seven_day']['is_fresh'];passed('partial high retains mode and independent old window age')
  f.rows['claude']=(20,45);f.advance();x=f.command('claude')['week'];assert x['poll_interval_seconds']==30;passed('partial low cannot silently decelerate')
  f.partial=None;f.advance();x=f.command('claude')['week'];assert x['poll_interval_seconds']==60;passed('complete low acquisition decelerates')
  before=x['five_hour']['fetched_at'];f.advance();x=f.command('claude')['week'];assert x['five_hour']['fetched_at']>before and x['five_hour']['is_fresh'];passed('same-value fresh API acquisition advances age')
  f.reset();f.cfg['claude_credentials']=[];f.config.write_text(json.dumps(f.cfg))
  native={'rate_limits':{'five_hour':{'used_percentage':90,'resets_at':time.time()+3600}}}
  x=f.command('claude',payload=native)['week'];stamp=x['five_hour']['fetched_at'];observed=x['five_hour']['observed_at'];x=f.command('claude',payload=native)['week']
  assert stamp is None and x['five_hour']['fetched_at'] is None and x['five_hour']['observed_at']>=observed and not x['five_hour']['is_fresh'];passed('native replay has receipt but no invented measurement freshness')
  f.cfg['claude_credentials']=[{'accessToken':'synthetic-primary'}];f.config.write_text(json.dumps(f.cfg));f.reset();x=f.command('claude')['week'];cp=f.cache/'statusline-claude-weekly.json'
  for invalid in [time.time()+300,'malformed',None,float('inf')]:
   d=json.loads(cp.read_text());d['five_hour_fetched_at']=invalid;cp.write_text(json.dumps(d));x=f.command('claude',only=True)['week'];assert not x['five_hour']['is_fresh'];passed(f'future/malformed timestamp {str(invalid)} suppressed')
  d=json.loads(cp.read_text());d['five_hour_end']='malformed';cp.write_text(json.dumps(d));assert not f.command('claude',only=True)['week']['five_hour']['is_fresh'];passed('malformed reset suppresses freshness')
  f.reset();f.rows['claude']=(20,45);f.command('claude');cp=f.cache/'statusline-claude-weekly.json';d=json.loads(cp.read_text());d['seven_day_fetched_at']=time.time()-100;d['period_end']=__import__('datetime').datetime.fromtimestamp(time.time()-10,__import__('datetime').timezone.utc).isoformat();cp.write_text(json.dumps(d));f.partial='seven_day';f.advance();f.command('claude');n=len(f.requests)
  for reason in ['automatic','wake','provider-start']:f.command('claude',reason)
  assert len(f.requests)==n;passed('expired missing window probes once, then obeys budget')
  f.reset();f.hold['claude']=threading.Event()
  args=[str(script),'--format','slots','--provider','claude','--test-config',str(f.config)]
  slow=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE);f.wait_requests('claude',1)
  f.command('claude',payload=native);during=time.time()-f.requests[-1]['start'];f.hold['claude'].set();slow.communicate(timeout=10)
  # Proof the native update landed while the reader (2.5 s request timeout) was still waiting.
  assert during<2.0,during;x=f.command('claude',only=True)['week']
  assert x['five_hour']['pct']==90 and not x['five_hour']['is_fresh'] and x['seven_day']['is_fresh'];passed('native/API race keeps preferred five-hour report and useful weekly API result')
  f.reset();f.cfg['cache_dir']=str(script.parent/'cache');f.config.write_text(json.dumps(f.cfg))
  try:f.command();raise AssertionError('live cache accepted')
  except AssertionError as e:assert 'isolated' in str(e)
  passed('test refuses live cache')
  f.cfg['cache_dir']=str(f.cache);f.cfg['claude_url']='https://api.anthropic.com/api/oauth/usage';f.config.write_text(json.dumps(f.cfg))
  try:f.command();raise AssertionError('real endpoint accepted')
  except AssertionError as e:assert 'loopback' in str(e)
  passed('test refuses real endpoints')
 finally:f.close()
 renewal_contracts()
 report={'result':'pass','script_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),'checks':checks,'scope':'real CLI/HTTP contracts; synthetic recovery only'};(out/'reader-contract-results.json').write_text(json.dumps(report,indent=2));print('Reader contracts passed:',len(checks),flush=True)
def renewal_contracts():
 f=Fixture(script,out,'renewal-fixture');past=int(time.time()*1000)-3600_000
 try:
  def expire():
   cp=f.cache/'statusline-claude-weekly.json';d=json.loads(cp.read_text());d['retry_at']=time.time()-1;cp.write_text(json.dumps(d));f.advance()
   # Also age the 60 s manual attempt floor that applies while failing.
   mp=f.cache/'statusline-claude-weekly.json.refresh.json';m=json.loads(mp.read_text());m['last_attempt_started_at']=time.time()-61;[a.update(started_at=a['started_at']-61,completed_at=a.get('completed_at',a['started_at'])-61) for a in m.get('attempts',[])];mp.write_text(json.dumps(m))
  def fresh_slot():
   x=f.command('claude')['week'];return x
  f.reset();store,home=f.enable_store(past);meta=f.cache/'statusline-claude-renewal.json'
  x=fresh_slot();d=json.loads(store.read_text());o=d['claudeAiOauth']
  assert len(f.token_posts)==1 and f.token_posts[0]=={'grant_type':'refresh_token','refresh_token':'stored-refresh','client_id':'9d1c250a-e61b-44d9-88ed-5944d1962f5e','scope':'user:inference user:profile'},f.token_posts
  assert o['accessToken']=='renewed-access-1' and o['refreshToken']=='renewed-refresh-1' and o['expiresAt']>time.time()*1000+28000_000 and o['subscriptionType']=='max' and d['mcpOAuth']=={'keep':'me'}
  assert f.requests[-1]['auth']=='Bearer renewed-access-1' and x['error'] is None and x['five_hour']['is_fresh']
  assert not (home/'.oauth_refresh.lock').exists() and not Path(str(home.resolve())+'.lock').exists()
  passed('expired terminal sign-in renews, preserves other fields, releases locks, then reads usage')
  f.advance();f.command('claude');assert len(f.token_posts)==1;passed('valid renewed sign-in is reused without another renewal')
  f.reset();store,home=f.enable_store(past);(home/'.oauth_refresh.lock').mkdir()
  x=f.command('claude')['week'];assert not f.token_posts and json.loads(store.read_text())['claudeAiOauth']['accessToken']=='expired-access' and x['error']
  assert not meta.exists();passed('fresh Claude Code refresh lock is respected')
  old=time.time()-300;__import__('os').utime(home/'.oauth_refresh.lock',(old,old));expire();x=f.command('claude','manual')['week']
  assert len(f.token_posts)==1 and x['error'] is None and not (home/'.oauth_refresh.lock').exists();passed('abandoned refresh lock is taken over')
  f.reset();store,home=f.enable_store(past);f.token_mode='invalid'
  x=f.command('claude')['week'];assert len(f.token_posts)==1 and x['error'] and json.loads(store.read_text())['claudeAiOauth']['refreshToken']=='stored-refresh'
  expire();f.command('claude','manual');assert len(f.token_posts)==1;passed('rejected refresh token is not retried')
  f.token_mode='ok';d=json.loads(store.read_text());d['claudeAiOauth']['expiresAt']=past+1;store.write_text(json.dumps(d));expire();x=f.command('claude','manual')['week']
  assert len(f.token_posts)==2 and x['error'] is None;passed('new sign-in after rejection renews again')
  f.reset();store,home=f.enable_store(past);f.token_mode='rate';f.command('claude');expire();f.command('claude','manual')
  assert len(f.token_posts)==1 and json.loads(meta.read_text())['next_attempt_at']>time.time()+500;passed('token endpoint 429 cools down')
  f.token_mode='ok';f.reset();store,home=f.enable_store(int(time.time()*1000)+3600_000);d=json.loads(store.read_text());d['claudeAiOauth']['accessToken']='valid-access';store.write_text(json.dumps(d))
  x=f.command('claude')['week'];assert not f.token_posts and f.requests[-1]['auth']=='Bearer valid-access';passed('unexpired sign-in is never renewed')
  for bad in [{'claude_token_url':'https://platform.claude.com/v1/oauth/token'},{'claude_store_file':'/tmp/claude-store.json'}]:
   cfg=dict(f.cfg,**bad);f.config.write_text(json.dumps(cfg))
   try:f.command('claude');raise AssertionError('unsafe renewal config accepted')
   except AssertionError as e:assert 'loopback' in str(e) or 'isolated' in str(e),e
  passed('test refuses real token endpoint and live sign-in store')
 finally:f.close()
try:
 contracts()
except Exception as e:
 print('FAIL:',repr(e),flush=True);sys.exit(1)
