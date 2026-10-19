"""Strict LaunchServices/coalition checks for the worktree QA bundle only."""
import json,os,pathlib,plistlib,re,subprocess,time
PROTECTED={2522,2530}
REAL_LABEL='dev.agentdeck.daemon.c92183e95f9d'
class UnsafeCoalition(RuntimeError):pass

def entries(text,bundle):
    return [block for block in re.split(r'(?m)(?=^\s*\d+\) ")',text) if f'bundle path="{bundle}"' in block]
def protected_pids():
    raw=subprocess.check_output(['/bin/ps','-axo','pid=,ppid='],text=True)
    pairs=[tuple(map(int,line.split())) for line in raw.splitlines() if len(line.split())==2]
    found=set(PROTECTED)
    while True:
        expanded=found|{pid for pid,parent in pairs if parent in found}
        if expanded==found:return found
        found=expanded

def verify(block,bundle,pid,call,R):
    current=entries(call(['/usr/bin/lsappinfo','list']),bundle)
    if len(current)!=1:raise UnsafeCoalition(f'Expected exactly one QA LS entry, got {len(current)}')
    block=current[0]
    ppid=int(call(['/bin/ps','-p',str(pid),'-o','ppid=']).strip())
    match=re.search(r'relatedCoalitionPIDs:\s*\(([^)]*)\)',block)
    related=set(map(int,re.findall(r'\d+',match.group(1)))) if match else set()
    protected=protected_pids()
    evidence={'pid':pid,'ppid':ppid,'bundle_path':str(bundle),'relatedCoalitionPIDs':sorted(related),
              'protected_daemon_pid':2530,'protected_app_pid':2522,'protected_pids':sorted(protected),
              'intersection':sorted(related&protected),'related_field_present':match is not None,'lsappinfo_entry':block,
              'passed':ppid==1 and not (related&protected)}
    (R/'coalition-verification.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2))
    (R/'lsappinfo-qa.txt').write_text(block)
    print('COALITION CHECK '+json.dumps({k:evidence[k] for k in ['pid','ppid','relatedCoalitionPIDs','intersection','passed']}),flush=True)
    if not evidence['passed']:raise UnsafeCoalition('QA app is related to protected user processes; do not quit it')
    return evidence

def daemon_label(term):
    normalized=('/' if str(term).startswith('/') else '')+'/'.join(x for x in str(term).split('/') if x and x!='.')
    h=0xcbf29ce484222325
    for b in normalized.encode():h=((h^b)*0x100000001b3)&0xffffffffffffffff
    label='dev.agentdeck.daemon.'+f'{h:016x}'[:12]
    assert label!=REAL_LABEL
    return label

def checked_daemon_plist(R):
    term=R/'data/term';p=term/'dev.agentdeck.daemon.plist'
    assert p.resolve().is_relative_to(R.resolve())
    assert 'video/.work/' in str(p.resolve())
    label=daemon_label(term)
    data=plistlib.loads(p.read_bytes())
    assert data['Label']==label and data['ProgramArguments'][2]==str(R/'data')
    print('QA DAEMON CLEANUP LABEL:',label,'PLIST:',p,flush=True)
    return label,p
