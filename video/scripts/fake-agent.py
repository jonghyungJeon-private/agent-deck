#!/usr/bin/env python3
"""실제 에이전트/네트워크를 실행하지 않는, 영상 전용 가상 CLI."""
import datetime, json, os, pathlib, signal, subprocess, sys, time

root = pathlib.Path(os.environ['AGENTDECK_HOME'])
work = root.parent
cwd = pathlib.Path.cwd()
specs = {
    'shop-api': ('결제 API 리팩터링', 'working', '결제 검증 로직을 서비스 계층으로 분리해 줘.', [
        ('Read', 'src/payments.ts · src/routes.ts'),
        ('Edit', '결제 검증과 응답 처리를 분리했습니다.'),
        ('Test', 'payments.spec.ts  12 passed'),
        ('Next', '실패 응답과 중복 결제를 확인하고 있습니다.')]),
    'shop-api-feature-coupon': ('쿠폰 정책 검증', 'done', '쿠폰 정책과 경계값 테스트를 병렬로 확인해 줘.', [
        ('Agent', '정책 검토 에이전트 실행 중'),
        ('Agent', '경계값 테스트 에이전트 실행 중'),
        ('Plan', '메인 응답 완료 · 하위 작업 결과를 기다립니다.')]),
    'shop-web': ('체크아웃 UI 개선', 'waiting', '모바일 체크아웃 화면의 버튼 간격을 조정해 줘.', [
        ('Read', 'src/Checkout.tsx · src/checkout.css'),
        ('Edit', '터치 영역과 결제 요약을 정리했습니다.'),
        ('Ask', '변경 내용을 저장할까요?  [허용] [직접 확인]')]),
    'shop-docs': ('배포 가이드 정리', 'done', '결제 모듈의 배포 가이드를 정리해 줘.', [
        ('Write', 'README.md · docs/deployment.md'),
        ('Check', '설치 순서와 롤백 절차를 확인했습니다.'),
        ('Done', '배포 가이드를 정리했습니다. 검토해 주세요.')]),
}
name, state, prompt, lines = specs.get(cwd.name, specs['shop-api'])
ids = {'shop-api':'11111111-1111-4111-8111-111111111111',
       'shop-api-feature-coupon':'22222222-2222-4222-8222-222222222222',
       'shop-web':'33333333-3333-4333-8333-333333333333',
       'shop-docs':'44444444-4444-4444-8444-444444444444'}
sid = ids.get(cwd.name, ids['shop-api'])
project = pathlib.Path(os.environ['CLAUDE_CONFIG_DIR']) / 'projects' / 'fictional-shop'
project.mkdir(parents=True, exist_ok=True)
transcript = project / (sid + '.jsonl')
def write_json(path, data):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
    tmp.replace(path)
transcript.write_text('\n'.join(json.dumps(x, ensure_ascii=False, separators=(',',':')) for x in [
    {'type':'custom-title','customTitle':name},
    {'type':'user','message':{'role':'user','content':prompt}}
]) + '\n', encoding='utf-8')
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
helper=subprocess.Popen([str(work/'post'),'pid',str(os.getpid())],stdout=subprocess.PIPE)
with pathlib.Path(os.environ['AGENTDECK_VIDEO_PID_LOG']).open('a') as f:f.write(f'{helper.pid} fake-pid-helper\n')
started=float(helper.communicate()[0]);assert helper.returncode==0
record = dict(sessionId=sid, cwd=str(cwd), transcriptPath=str(transcript),
              pid=os.getpid(), pidStartedAt=started, startedAt=now, activeSince=now,
              pane=os.environ['AGENTDECK_PANE'], termProgram='AgentDeck',
              state=state, stateAt=now, stateSeq=1)
if state == 'waiting': record['stateMessage'] = '권한 요청'
if cwd.name.endswith('feature-coupon'):
    record['background'] = [dict(id='policy',type='subagent',status='running',description='쿠폰 정책 검토'),
                            dict(id='boundary',type='subagent',status='running',description='경계값 테스트')]
    agents = project / sid / 'subagents'
    agents.mkdir(parents=True, exist_ok=True)
    for ident, desc in [('policy','쿠폰 정책 검토'),('boundary','경계값 테스트')]:
        (agents / f'agent-{ident}.meta.json').write_text(json.dumps({'agentType':'general-purpose','description':desc},ensure_ascii=False))
        (agents / f'agent-{ident}.jsonl').write_text(json.dumps({'type':'user','message':{'role':'user','content':f'{desc}: {cwd}' }},ensure_ascii=False)+'\n'+json.dumps({'type':'assistant','message':{'role':'assistant','content':[{'type':'text','text':f'{desc} 진행 중'}],'stop_reason':'tool_use'}},ensure_ascii=False)+'\n')
(root / 'sessions').mkdir(exist_ok=True)
write_json(root / 'sessions' / (sid + '.json'), record)
with pathlib.Path(os.environ['AGENTDECK_VIDEO_PID_LOG']).open('a') as f: f.write(f'{os.getpid()} fake-agent {cwd.name}\n')
with (work / 'fake-launches.jsonl').open('a') as f:
    f.write(json.dumps({'pid':os.getpid(),'cwd':str(cwd),'args':sys.argv[1:],'pane':os.environ['AGENTDECK_PANE']})+'\n')
purple='\033[38;2;192;153;255m'; dim='\033[38;2;127;132;142m'; white='\033[38;2;220;223;228m'; green='\033[38;2;152;195;121m'; reset='\033[0m'
print('\033[2J\033[H\033[?25l',end='')
print(f'\n  {purple}✦  Claude Code{reset}   {dim}DEMO · 가상 프로젝트{reset}\n')
print(f'  {white}{name}{reset}')
print(f'  {dim}{cwd.name}  ·  '+('feature/coupon' if 'coupon' in cwd.name else 'main')+f'{reset}\n')
print(f'  {purple}❯{reset} {prompt}\n')
for kind, text in lines:
    print(f'  {green}●{reset} {white}{kind:<6}{reset} {text}\n')
print(f'  {dim}─────────────────────────────────────────────{reset}\n')
print(f'  {purple}❯{reset} ',end='',flush=True)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    try:
        if not sys.stdin.readline(): time.sleep(1)
    except KeyboardInterrupt: pass
