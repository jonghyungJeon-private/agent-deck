#!/usr/bin/env python3
"""Send sequential capture jobs to the existing supervisor. Never starts an app."""
import json,pathlib,re,subprocess,sys,time
V=pathlib.Path(__file__).resolve().parents[1];S=V/'.work'
R=pathlib.Path(json.loads((S/'active-run.json').read_text())['root'])
def cmd(action,*args):
    p=subprocess.Popen([sys.executable,str(V/'scripts/capture.py'),action,*args])
    with (S/'pids.log').open('a') as f:f.write(f'{p.pid} scene-client {action}\n')
    if p.wait()!=0:raise RuntimeError((action,args))
def post(*args):cmd('post',*args)
def shot(name):cmd('shot',name)
post('spaces-expand-all','font-size 16','chord cmd+1');time.sleep(2)
shot('spaces');post('spaces-collapse-all');shot('collapsed');post('spaces-expand-all');shot('split-before')
post('dragpoints')
log=(R/'app.log').read_text() if (R/'app.log').exists() else ''
points=list(re.finditer(r'tab 1 center=(\d+),(\d+)',log))
x,y=points[-1].groups() if points else ('614','742')
post(f'mouse down {x} {y}','mouse drag 680 704','mouse drag 1165 360');shot('split-drag')
post('mouse up 1165 360','tabs');shot('split-after')
main=json.loads((R/'data/sessions/11111111-1111-4111-8111-111111111111.json').read_text())['pane']
post('select '+main,'action extract-pane')
post('dock files left','tool-select files','expand src','open-file src/payments.ts');shot('files')
post('open-file README.md','editor-preview on');time.sleep(1);shot('markdown')
post('open-file src/routes.ts','index-build '+str(R/'demo/shop-api'));time.sleep(2)
post('goto 4:12','popup','editor-state');shot('definition')
cmd('settings');post('rows','tabs','location')
print('All fresh captures ready for review:',R/'public')
