#!/usr/bin/env python3
"""Real CLI/HTTP regressions; all recorder data confined to TemporaryDirectory."""
import hashlib, json, os, pathlib, signal, socket, sqlite3, subprocess, sys, tempfile, time, urllib.request, urllib.error
binary = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/annalist').resolve()
checks=[]
def check(name, ok):
    assert ok, name
    checks.append(name)
    print('PASS', name, flush=True)
with tempfile.TemporaryDirectory(prefix='annalist-integration-') as temp:
    root=pathlib.Path(temp); project=root/'project'; project.mkdir()
    env=dict(os.environ, HOME=str(root/'home'), XDG_DATA_HOME=str(root/'data'))
    def run(*args, cwd=project, code=0):
        p=subprocess.run([str(binary),*args],cwd=cwd,env=env,text=True,capture_output=True,timeout=20)
        assert p.returncode==code, (args,p.returncode,p.stdout,p.stderr)
        return p.stdout
    run('init'); cfg=project/'.annalist/config.toml'; identity=cfg.read_text(); run('init')
    check('init preserves identity',cfg.read_text()==identity)
    for args in [('ui','--bad'),('run','--bad','--','true'),('inspect','1','--bad'),('doctor','--bad'),('export','1','--all'),('gate','--bad')]:run(*args,code=2)
    check('strict command validation',True)
    (project/'a.txt').write_text('before\n'); (project/'gone.txt').write_text('deleted\n'); (project/'.env').write_text('SYNTHETIC_SECRET=not-real')
    run('run','--','sh','-c','printf "after\\n" > a.txt; rm gone.txt; printf "new\\n" > new.txt')
    database=root/'data/annalist/annalist.db'
    db=sqlite3.connect(database)
    sid=db.execute('select max(id) from sessions').fetchone()[0]; sid=str(sid)
    check('completed session and file changes',db.execute('select status from sessions where id=?',(sid,)).fetchone()[0]=='success' and db.execute("select count(*) from events where session_id=? and type like 'file_%'",(sid,)).fetchone()[0]==3)
    check('new index private',database.stat().st_mode & 0o077==0)
    check('default secret exclusion',not any(b'SYNTHETIC_SECRET' in p.read_bytes() for p in (project/'.annalist/objects').glob('*/*')))
    data=json.loads(run('inspect',sid,'--json')); check('inspect valid JSON',bool(data))
    run('rewind',sid,'--dry-run');check('dry run does not mutate', (project/'a.txt').read_text()=='after\n')
    bundle=root/'bundle';run('export',sid,'--out',str(bundle));manifest=json.loads((bundle/'manifest.json').read_text());check('export includes sequence zero',manifest['events'][0]['seq']==0)
    run('export',sid,'--out',str(bundle),code=1)
    imported=root/'imported';imported.mkdir();run('init',cwd=imported);run('import',str(bundle),cwd=imported)
    check('export/import round trip',db.execute('select count(*) from sessions').fetchone()[0]==2)
    run('import',str(bundle),cwd=imported,code=1)
    before=db.execute('select count(*) from sessions').fetchone()[0]
    broken=json.loads(json.dumps(manifest));broken['events'].append(dict(broken['events'][-1]));(bundle/'manifest.json').write_text(json.dumps(broken))
    run('import',str(bundle),'--force',cwd=imported,code=1)
    check('invalid import leaves no rows',db.execute('select count(*) from sessions').fetchone()[0]==before)
    for label, mutate in [
        ('unknown event', lambda m: m['events'][0].update(type='untrusted_event')),
        ('overflowing session timestamps', lambda m: m['session'].update(started_at=9223372036854775807, ended_at=9223372036854775807)),
        ('overflowing event timestamp', lambda m: m['events'][0].update(ts=9223372036854775807)),
        ('invalid status', lambda m: m['session'].update(status='invented')),
        ('unrelated previous path', lambda m: next(e for e in m['events'] if e['type']=='file_modified').update(prev_path='../outside')),
    ]:
        invalid=json.loads(json.dumps(manifest));mutate(invalid)
        (bundle/'manifest.json').write_text(json.dumps(invalid))
        run('import',str(bundle),'--force',cwd=imported,code=1)
        check('import rejects '+label,db.execute('select count(*) from sessions').fetchone()[0]==before)
    (bundle/'manifest.json').write_text(json.dumps(manifest))
    db.execute('update sessions set started_at=9223372036854775807 where id=?',(sid,));db.commit()
    check('malformed stored timestamp renders safely','Invalid timestamp' in run('sessions') and 'Invalid timestamp' in run('inspect',sid))
    db.execute('update sessions set started_at=-9223372036854775808, ended_at=9223372036854775807 where id=?',(sid,));db.commit()
    check('malformed stored duration renders safely','Invalid duration' in run('sessions') and 'Invalid duration' in run('inspect',sid))
    db.execute('update sessions set started_at=?, ended_at=? where id=?',(manifest['session']['started_at'],manifest['session']['ended_at'],sid));db.commit()
    # Missing blob must refuse all recovery changes and leave export retryable.
    prev=next(e['prev_hash'] for e in manifest['events'] if e.get('prev_hash'))
    blob=project/'.annalist/objects'/prev[:2]/prev[2:];saved=blob.read_bytes();blob.unlink()
    run('rewind',sid,'--force',code=1)
    check('missing blob recovery is all-preflight', (project/'a.txt').read_text()=='after\n' and (project/'new.txt').exists() and not (project/'gone.txt').exists())
    retry=root/'retry';run('export',sid,'--out',str(retry),code=1);check('failed export is not published',not retry.exists())
    blob.write_bytes(saved);run('export',sid,'--out',str(retry));check('export retry succeeds', (retry/'manifest.json').exists())
    blob.write_bytes(b'corrupt');run('doctor',code=1);run('rewind',sid,'--force',code=1);blob.write_bytes(saved)
    check('corrupt objects detected',True)
    outside=root/'outside';outside.write_text('untouched');(project/'a.txt').unlink();(project/'a.txt').symlink_to(outside)
    run('rewind',sid,'--force',code=1);check('symlink recovery refuses external writes',outside.read_text()=='untouched')
    (project/'a.txt').unlink();(project/'a.txt').write_text('later edit')
    run('rewind',sid,code=1);check('divergent edits refused',(project/'a.txt').read_text()=='later edit')
    run('rewind',sid,'--force');check('recovery restores pre-session state',(project/'a.txt').read_text()=='before\n' and (project/'gone.txt').read_text()=='deleted\n' and not (project/'new.txt').exists())
    backups=list((project/'.annalist/recovery').glob('*/a.txt'));check('pre-recovery copies retained',any(p.read_text()=='later edit' for p in backups))
    run('run','--','sh','-c','exit 7',code=7);check('child exit propagated',True)
    (project/'.env').unlink(missing_ok=True)
    (project/'policy.toml').write_text('allow_paths = ["src/", "docs/", "tests/"]' + chr(10) + 'deny_globs = [".env", ".env.*", "*.pem", "**/secrets/**"]' + chr(10) + 'max_files_changed = 80' + chr(10) + 'fail_on_secret = true' + chr(10))
    run('run','--','sh','-c','mkdir -p src && printf ok > src/ok.txt')
    gate_id = db.execute('select max(id) from sessions').fetchone()[0]
    run('gate','--session',str(gate_id),'--policy','policy.toml');check('gate passes clean session',True)
    run('run','--','sh','-c','printf SECRET=x > .env')
    secret_id = db.execute('select max(id) from sessions').fetchone()[0]
    run('gate','--session',str(secret_id),'--policy','policy.toml',code=2);check('gate denies secret',True)
    (project/'.env').unlink()
    run('gate','--session','999999','--policy','policy.toml',code=1);check('gate rejects unknown session',True)
    (project/'bad-policy.toml').write_text('allow_paths = []' + chr(10) + 'bogus = 1' + chr(10))
    run('gate','--session',str(gate_id),'--policy','bad-policy.toml',code=1);check('gate rejects unknown policy key',True)
    gblob = None
    gsaved = None
    ghash = None
    for row in db.execute('select distinct new_hash from events where session_id=? and new_hash is not null',(gate_id,)):
        cand = project/'.annalist/objects'/row[0][:2]/row[0][2:]
        if cand.exists():gblob = cand;gsaved = cand.read_bytes();ghash = row[0];break
    assert gblob is not None, 'gate fixture blob missing'
    gblob.unlink()
    run('gate','--session',str(gate_id),'--policy','policy.toml',code=1);check('gate fails on missing content',True)
    gblob.write_bytes(gsaved)
    # Long-running process verifies persisted events and exclusive maintenance.
    child=subprocess.Popen([str(binary),'run','--','sh','-c','echo live > live.txt; sleep 30'],cwd=project,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            if db.execute("select count(*) from events where path='live.txt'").fetchone()[0]:break
            time.sleep(.1)
        check('events durable while child runs',db.execute("select count(*) from events where path='live.txt'").fetchone()[0]>0)
        run('sessions');run('inspect',sid,'--json');run('diff',sid,sid);check('live history commands usable',True)
        run('doctor','--gc',code=1);run('prune','--older-than','1',code=1);check('active maintenance blocked',True)
        child.send_signal(signal.SIGTERM);out,err=child.communicate(timeout=8)
        check('SIGTERM forwarded and finalized',child.returncode==143 and db.execute('select status from sessions order by id desc limit 1').fetchone()[0]=='interrupted')
    finally:
        if child.poll() is None:child.kill();child.wait()
    run('doctor')
    # Permission failures must fail recording, never fabricate a deletion.
    run('run','--','sh','-c','chmod 000 a.txt',code=1)
    unreadable_id=db.execute('select max(id) from sessions').fetchone()[0]
    check('unreadable file does not become deletion',db.execute("select count(*) from events where session_id=? and type='file_deleted'",(unreadable_id,)).fetchone()[0]==0)
    (project/'a.txt').chmod(0o600)
    (project/'link').symlink_to('a.txt')
    run('run','--','sh','-c','sleep 3; rm link')
    link_event=db.execute("select prev_hash,new_hash from events where path='link' order by id desc limit 1").fetchone()
    check('unchanged symlink never references missing blob',link_event==(None,None))
    run('doctor')
    run('run','--','sh','-c','umask > child-mask.txt')
    parent_mask=os.umask(0);os.umask(parent_mask)
    check('child umask preserved',int((project/'child-mask.txt').read_text().strip(),8)==parent_mask)
    (project/'retry-store.txt').write_text('before')
    run('run','--','sh','-c','chmod 500 .annalist/objects; printf after > retry-store.txt; sleep 3; chmod 700 .annalist/objects; sleep 3; rm retry-store.txt; sleep 1',code=1)
    run('doctor')
    check('failed object write retries before deletion references hash',True)
    # Compare preview with actual deletion against identical eligible history.
    db.execute("update sessions set ended_at=1 where project_id=(select project_id from sessions where id=?)",(sid,));db.commit()
    preview=run('prune','--older-than','1','--dry-run')
    actual=run('prune','--older-than','1')
    check('prune preview matches actual counts',preview.split(':',1)[1]==actual.split(':',1)[1])
    # Restore one historical run for the dashboard fixture after pruning.
    run('import',str(bundle))
    sid=str(db.execute('select max(id) from sessions').fetchone()[0])
    # Bind a free loopback port for the actual embedded HTTP server.
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    with cfg.open('a') as f:f.write(f'\n[ui]\nport = {port}\n')
    ui=subprocess.Popen([str(binary),'ui'],cwd=project,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    def request(path,headers=None):
        try:
            with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}'+path,headers=headers or {}),timeout=5) as r:return r.status,r.read(),r.headers
        except urllib.error.HTTPError as e:return e.code,e.read(),e.headers
    try:
        for _ in range(50):
            try:status,body,headers=request('/');break
            except OSError:time.sleep(.1)
        check('dashboard loads offline assets',status==200 and b'A clear history.' in body and headers['X-Frame-Options']=='DENY')
        status,body,_=request('/api/sessions');check('session API is valid JSON',status==200 and len(json.loads(body))>=1)
        for escaped in ['%','%a','%zz']:
            check('malformed URL survives '+escaped,request(f'/api/files/history?session={sid}&path='+escaped)[0]==200)
        check('DNS rebinding rejected',request('/api/sessions',{'Host':'attacker.invalid'})[0]==403)
        check('cross-site requests rejected',request('/api/sessions',{'Sec-Fetch-Site':'cross-site'})[0]==403)
        status,body,_=request(f'/api/files/history?session={sid}&path=a.txt');history=json.loads(body)
        check('file versions served',history[0]['before']=='before\n' and history[0]['after']=='after\n')
    finally:ui.terminate();ui.wait(timeout=5)
    db.close()
print(f'{len(checks)} integration checks passed; isolated fixtures cleaned.')
