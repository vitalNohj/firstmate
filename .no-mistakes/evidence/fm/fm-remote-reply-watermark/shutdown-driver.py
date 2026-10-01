import os, pathlib, subprocess, time, shutil, json
root=pathlib.Path.cwd()
ev=pathlib.Path('/home/nohj/.no-mistakes/evidence/01M3V0SE3MQDEC017AEC6F2G2N')
results=[]
for scenario in ['state','home','pending-lock']:
    home=root/'.validation-tmp'/('lab-'+scenario)
    subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,stdout=subprocess.DEVNULL)
    env=os.environ.copy(); env.update(FM_HOME=str(home),FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',TMPDIR=str(root/'.validation-tmp/fixtures'),TMUX_TMPDIR=str(home/'tmux'))
    (home/'tmux').mkdir()
    tmux=['tmux','-S','.validation-tmp/fm-lab.socket']
    subprocess.run(tmux+['new-session','-d','-s','validation','sleep 300'],env=env,check=True)
    socket=subprocess.check_output(tmux+['display-message','-p','#{socket_path}'],env=env,text=True).strip()
    env['TMUX']=socket+',0,0'
    state=home/'state'
    if scenario=='pending-lock':
        (state/'pending-replies').mkdir()
        (state/'pending-replies/shutdown').write_text('corr_id=shutdown\ntask_id=mate\nphase=awaiting_report\n')
        (state/'.pending-reply-shutdown.lock').mkdir()
        (state/'.pending-reply-shutdown.lock/pid').write_text(str(os.getpid())+'\n')
    log=ev/('watcher-'+scenario+'.log')
    p=None
    try:
        with log.open('w') as f:
            p=subprocess.Popen(['bash','-x','bin/fm-watch.sh'],env=env,stdout=f,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+20
            needle='sleep 0.1' if scenario=='pending-lock' else 'event_wait_or_sleep'
            while time.monotonic()<deadline:
                text=log.read_text()
                if needle in text and (scenario!='pending-lock' or 'fm_pending_reply_reconcile_delivery' in text): break
                if p.poll() is not None: raise RuntimeError('watcher exited during startup')
                time.sleep(.05)
            else: raise RuntimeError('watcher never reached required runtime state')
            # Kill the private tmux server before deleting its socket with the home.
            subprocess.run(tmux+['kill-server'],env=env,check=True)
            start=time.monotonic()
            shutil.rmtree(home if scenario=='home' else state)
            rc=p.wait(timeout=5)
            elapsed=time.monotonic()-start
        text=log.read_text()
        expected='watcher: exiting - '+('home' if scenario=='home' else 'state directory')+' no longer exists:'
        assert expected in text and rc==1,(rc,text[-2000:])
        assert not (home if scenario=='home' else state).exists()
        results.append(dict(scenario=scenario,exit=rc,seconds=round(elapsed,3),reason=next(l for l in text.splitlines() if l.startswith('watcher: exiting')),state_recreated=False))
    finally:
        if p and p.poll() is None: p.kill(); p.wait()
        subprocess.run(tmux+['kill-server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        shutil.rmtree(home,ignore_errors=True)
(ev/'watcher-shutdown.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
