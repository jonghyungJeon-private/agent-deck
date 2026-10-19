#!/usr/bin/env python3
"""One supervisor, exactly one QA app, fresh data/snapshots, PID-only cleanup."""
import fcntl, hashlib, json, os, pathlib, re, shutil, signal, struct, subprocess, sys, time, uuid, plistlib
from fixtures import prepare
from launchd_safety import entries,verify,daemon_label,checked_daemon_plist,UnsafeCoalition

V=pathlib.Path(__file__).resolve().parents[1]; W=V.parent; S=V/'.work'
EXE=W/'dist/AgentDeck.app/Contents/MacOS'; GLOBAL=S/'pids.log'
BOOTLOG=S/'current-boot-pids.log'
S.mkdir(exist_ok=True)
def ps(pid):
    p=subprocess.run(['/bin/ps','-p',str(pid),'-o','pid=,stat=,lstart=,command='],capture_output=True,text=True)
    return p.stdout.strip() if p.returncode==0 else ''
def logpid(pid,role,path=''):
    with GLOBAL.open('a') as f:f.write(f'{pid} {role} {path}\n')
    with BOOTLOG.open('a') as f:f.write(f'{pid} {role} {path}\n')
def old_pids():
    return sorted({int(x.split()[0]) for x in BOOTLOG.read_text().splitlines() if x.split() and x.split()[0].isdigit()}) if BOOTLOG.exists() else []
def reject_alive(exclude=()):
    live=[ps(pid) for pid in old_pids() if pid not in exclude]
    live=[x for x in live if x]
    if live:raise RuntimeError('Refusing to launch: recorded PID is still alive:\n'+'\n'.join(live))
def pngsize(p):
    return struct.unpack('>II',p.read_bytes()[16:24])

def serve():
    lock=(S/'capture.lock').open('a+')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:raise RuntimeError('Another capture supervisor owns the lock; refusing to launch')
    boot=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.boottime'],text=True)
    bootfile=S/'current-boot.txt'
    if not bootfile.exists() or bootfile.read_text()!=boot:
        if BOOTLOG.exists():shutil.copy2(BOOTLOG,S/('pids-previous-boot-'+str(time.time_ns())+'.log'))
        BOOTLOG.write_text('');bootfile.write_text(boot)
    reject_alive(exclude=(os.getpid(),))
    bundle=W/'dist/AgentDeck.app'
    existing=entries(subprocess.check_output(['/usr/bin/lsappinfo','list'],text=True),bundle)
    if existing:raise RuntimeError('QA app already registered at exact worktree bundle path; refusing launch')
    run_id='run-'+time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6]
    R=S/'runs'/run_id; R.mkdir(parents=True)
    for name in ['home','appsupport','data/term','claude','codex','tasks','snapshot','tmp','bin','queue','captures','public']:(R/name).mkdir(parents=True)
    env={k:os.environ[k] for k in ['CLANG_MODULE_CACHE_PATH','SWIFTPM_MODULECACHE_OVERRIDE','XDG_CACHE_HOME'] if k in os.environ}
    env.update(LANG='ko_KR.UTF-8',USER='demo',LOGNAME='demo')
    env.update(HOME=str(R/'home'),CFFIXED_USER_HOME=str(R/'home'),ZDOTDIR=str(R/'home'),
       AGENTDECK_APP_SUPPORT=str(R/'appsupport'),AGENTDECK_HOME=str(R/'data'),AGENTDECK_TERM_HOME=str(R/'data/term'),
       CLAUDE_CONFIG_DIR=str(R/'claude'),CODEX_HOME=str(R/'codex'),AGENTDECK_CLAUDE_TMP=str(R/'tasks'),
       AGENTDECK_NO_ACTIVATE='1',AGENTDECK_NO_NOTIFY='1',AGENTDECK_DEBUG='1',AGENTDECK_AUTO_TITLE='0',
       AGENTDECK_DEBUG_NAME='dev.agentdeck.video.20261019.'+run_id,AGENTDECK_SNAPSHOT=str(R/'snapshot'),
       AGENTDECK_FAKE_LATEST='v0.4.0',AGENTDECK_VIDEO_PID_LOG=str(GLOBAL),TMPDIR=str(R/'tmp')+'/',SHELL='/bin/zsh',
       PATH=str(R/'bin')+':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin')
    # Inherited Claude/Codex session markers must not leak into the QA process.
    for key in list(env):
        if key.startswith('CLAUDE_CODE_') or key in ['CLAUDECODE','CLAUDE_PID','CLAUDE_EFFORT','CODEX_THREAD_ID']:env.pop(key)
    manifest={'run':run_id,'root':str(R),'driver':os.getpid(),'channel':env['AGENTDECK_DEBUG_NAME'],'app':None,'daemon':None,'state':'starting'}
    def save():
        for file in [S/'active-run.json',R/'manifest.json']:
            tmp=file.with_suffix('.tmp');tmp.write_text(json.dumps(manifest,indent=2));tmp.replace(file)
    logpid(os.getpid(),'capture-supervisor',run_id)
    (R/'environment.json').write_text(json.dumps({k:v for k,v in env.items() if k.startswith(('AGENTDECK_','CLAUDE_CONFIG','CODEX_HOME')) or k in ['HOME','CFFIXED_USER_HOME','ZDOTDIR','TMPDIR','PATH']},indent=2))
    processes=[]; app=None; daemon=None; pane_pids=[]; shots={}; verified=False; unsafe=False
    def spawn(args,role,**kwargs):
        p=subprocess.Popen([str(x) for x in args],env=env,**kwargs);logpid(p.pid,role,str(args[0]));processes.append(p)
        with (R/'pids.log').open('a') as f:f.write(f'{p.pid} {role}\n')
        return p
    def call(args):
        p=spawn(args,'capture-command',stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        output=p.communicate(timeout=180 if str(args[0]).endswith('swiftc') else 30)[0].decode()
        if p.returncode:raise RuntimeError(output)
        return output
    def post(c):
        if app is None or not ps(app):raise RuntimeError('QA app exited; refusing commands and automatic relaunch')
        call([R/'post',c]);time.sleep(.35)
    def shot(name):
        if not re.fullmatch(r'[a-z0-9-]+',name):raise ValueError(name)
        post('rows');post('tabs');post('dragpoints')
        after=time.time();files=['window.png','terminal.png','tabbar.png'];target=R/'captures'/name;target.mkdir(exist_ok=True)
        for _ in range(100):
            time.sleep(.1)
            paths=[R/'snapshot'/n for n in files]
            if not all(p.exists() and p.stat().st_mtime>after for p in paths):continue
            before=[p.stat().st_mtime_ns for p in paths]
            for p in paths:shutil.copy2(p,target/p.name)
            if before!=[p.stat().st_mtime_ns for p in paths]:continue
            break
        else:raise RuntimeError('No complete fresh snapshot cycle')
        assert pngsize(target/'window.png')==(2400,1520),pngsize(target/'window.png')
        assert pngsize(target/'terminal.png')==(2400,1520),pngsize(target/'terminal.png')
        output=R/'public'/(name+'.png')
        call(['/opt/homebrew/bin/ffmpeg','-v','error','-y','-i',target/'window.png','-i',target/'terminal.png',
           '-filter_complex','[0:v][1:v]overlay=0:0:format=auto[out]','-map','[out]','-frames:v','1','-threads','2','-update','1',output])
        shots[name]={'size':pngsize(output),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'app':app,'run':run_id}
        (R/'shots.json').write_text(json.dumps(shots,indent=2));print('Captured',name,flush=True)
        return str(output)
    def terminate_owned(p):
        if p and p.poll() is None:
            p.terminate()
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:p.kill();p.wait(timeout=10)
        if p and ps(p.pid):raise RuntimeError(f'Recorded child {p.pid} has not exited')
    def wait_pid_exit(pid):
        for _ in range(100):
            if not ps(pid):return
            time.sleep(.05)
        raise RuntimeError(f'Recorded PID {pid} did not exit')
    stop_requested=False
    try:
        save();shutil.copy2(S/'post-current',R/'post')
        prepare(R,V,call)
        (R/'data/term/ui.json').write_text(json.dumps({'version':1,'tools':{'spaces':'left','files':'left'},'lastSides':{'spaces':'left','files':'left'},'selected':{'left':'spaces'},'widths':{'left':330,'right':280},'fontSize':16}))
        exe=str(EXE/'AgentDeckDaemon');command='[ -x "'+exe+'" ] || exit 0; exec "'+exe+'" hook'
        (R/'claude/settings.json').write_text(json.dumps({'hooks':{e:[{'hooks':[{'type':'command','timeout':10,'command':command}]}] for e in ['SessionStart','SessionEnd','UserPromptSubmit','Stop','StopFailure','Notification','PermissionRequest']}}))
        # Only launchd may invoke open; this shell never starts a QA GUI process.
        LD=S/'launchd';LD.mkdir(exist_ok=True)
        counterfile=LD/'counter'
        counter=int(counterfile.read_text())+1 if counterfile.exists() else 1
        counterfile.write_text(str(counter))
        opener='dev.agentdeck.videoqa.opener.'+str(counter)
        plist=LD/(opener+'.plist')
        argv=['/usr/bin/open','-n','--stdout',str(R/'app.log'),'--stderr',str(R/'app.log')]
        for key,value in env.items():argv+=['--env',key+'='+value]
        argv+=[str(bundle)]
        payload={'Label':opener,'ProgramArguments':argv,'RunAtLoad':True,'KeepAlive':False,
            'AbandonProcessGroup':True,'WorkingDirectory':str(R/'demo/shop-api'),
            'StandardOutPath':str(R/'opener.log'),'StandardErrorPath':str(R/'opener.log')}
        plist.write_bytes(plistlib.dumps(payload))
        manifest.update(opener=opener,opener_plist=str(plist),daemon_label=daemon_label(R/'data/term'));save()
        call(['/bin/launchctl','bootstrap','gui/'+str(os.getuid()),plist])
        for _ in range(150):
            blocks=entries(call(['/usr/bin/lsappinfo','list']),bundle)
            if len(blocks)==1 and re.search(r'pid = (\d+)',blocks[0]):break
            time.sleep(.2)
        else:raise UnsafeCoalition('QA LS entry could not be identified; leave app untouched')
        app=int(re.search(r'pid = (\d+)',blocks[0]).group(1));logpid(app,'qa-app-launchd',str(bundle))
        manifest['app']=app;save()
        call(['/bin/launchctl','bootout','gui/'+str(os.getuid())+'/'+opener])
        # First app-specific action: mandatory exact-path coalition/ppid verification.
        verify(blocks[0],bundle,app,call,R);verified=True
        manifest['coalition_verified']=True;save()
        shutil.copy2(R/'coalition-verification.json',R/'coalition-initial.json')
        for _ in range(100):
            if (R/'data/term/daemon.pid').exists() and (R/'data/term/dev.agentdeck.daemon.plist').exists():break
            time.sleep(.1)
        daemon=int((R/'data/term/daemon.pid').read_text());logpid(daemon,'qa-daemon-launchd',str(R/'data/term'))
        label,daemon_plist=checked_daemon_plist(R)
        daemon_status=call(['/bin/launchctl','print','gui/'+str(os.getuid())+'/'+label])
        (R/'daemon-launchctl.txt').write_text(daemon_status)
        assert int(call(['/bin/ps','-p',str(daemon),'-o','ppid=']))==1
        manifest['daemon']=daemon;save()
        for name in ['shop-api','shop-api-feature-coupon','shop-web','shop-docs']:
            output=call([EXE/'AgentDeckDaemon','ctl','new',R/'demo'/name,'exec claude'])
            for raw in re.findall(r'^[A-F0-9-]{36}\s+\S+\s+pid (\d+)',output,re.M):
                pid=int(raw)
                if pid not in pane_pids:pane_pids.append(pid);logpid(pid,'qa-pane',manifest['run'])
        time.sleep(3)
        manifest['state']='ready';save()
        print('READY '+str(R),flush=True)
        while not stop_requested:
            if not ps(app):raise RuntimeError('QA app exited unexpectedly')
            requests=sorted((R/'queue').glob('*.request.json'))
            if not requests:time.sleep(.1);continue
            for request in requests:
                job=json.loads(request.read_text());result={}
                try:
                    if job['action']=='post':
                        for c in job['commands']:post(c)
                    elif job['action']=='shot':result['output']=shot(job['name'])
                    elif job['action']=='settings':
                        post('settings');time.sleep(1)
                        target=R/'captures/settings';target.mkdir(exist_ok=True)
                        post('settings-snap '+str(target/'window.png'))
                        if not (target/'window.png').exists():raise RuntimeError('Settings snapshot absent')
                        shutil.copy2(target/'window.png',R/'public/settings.png')
                        result['size']=pngsize(R/'public/settings.png')
                    elif job['action']=='stop':
                        verify('',bundle,app,call,R);stop_requested=True
                    else:raise ValueError(job)
                    result['ok']=True
                except UnsafeCoalition:raise
                except Exception as e:result={'ok':False,'error':str(e)}
                response=request.with_name(request.name.replace('.request.json','.response.json'))
                response.write_text(json.dumps(result));request.unlink()
    except UnsafeCoalition as e:
        unsafe=True;manifest['state']='UNSAFE-DO-NOT-QUIT';save()
        details='STOPPED: '+str(e)+'\nQA app PID '+str(app)+' was deliberately not signalled.\nRun: '+str(R)+'\n'
        (V/'STATUS.md').write_text('# Safety stop\n\n'+details)
        print(details,flush=True)
        raise
    finally:
        if not unsafe:
            manifest['state']='stopping';save()
            if app is not None and not verified:
                manifest['state']='UNVERIFIED-DO-NOT-QUIT';save()
                raise UnsafeCoalition('App not verified; no cleanup signal permitted')
            if app is not None and ps(app):
                os.kill(app,signal.SIGTERM);wait_pid_exit(app)
            if daemon is not None:
                label,p=checked_daemon_plist(R)
                manifest['cleanup_daemon_label']=label;manifest['cleanup_plist_inside_work']=True;save()
                result=call(['/bin/launchctl','bootout','gui/'+str(os.getuid())+'/'+label])
                wait_pid_exit(daemon)
            for pid in pane_pids:
                if ps(pid):os.kill(pid,signal.SIGTERM);wait_pid_exit(pid)
            for p in processes:
                if p.poll() is None:terminate_owned(p)
                else:p.wait()
            manifest['state']='stopped';save()
            (R/'cleanup.json').write_text(json.dumps({'app_pid_absent':app,'daemon_pid_absent':daemon,'coalition_verified':verified,'pane_pids_absent':pane_pids},indent=2))
            print('STOPPED: verified QA app and scratch daemon/panes exited',flush=True)

def client(action):
    manifest=json.loads((S/'active-run.json').read_text());R=pathlib.Path(manifest['root'])
    if manifest['state']!='ready' or not ps(manifest['driver']) or not ps(manifest['app']):raise RuntimeError('No live supervised QA run')
    job={'action':action}
    if action=='post':job['commands']=sys.argv[2:]
    if action=='shot':job['name']=sys.argv[2]
    request=R/'queue'/(str(time.time_ns())+'.request.json');tmp=request.with_suffix('.tmp')
    tmp.write_text(json.dumps(job));tmp.replace(request)
    response=request.with_name(request.name.replace('.request.json','.response.json'))
    for _ in range(900):
        if response.exists():
            result=json.loads(response.read_text());response.unlink()
            if not result['ok']:raise RuntimeError(result['error'])
            print(json.dumps(result));return
        time.sleep(.1)
    raise RuntimeError('Capture supervisor response timed out')

if __name__=='__main__':
    action=sys.argv[1] if len(sys.argv)>1 else ''
    if action=='run':serve()
    elif action in ['post','shot','settings','stop']:client(action)
    else:raise SystemExit('capture.py run | post <commands...> | shot <name> | settings | stop')
