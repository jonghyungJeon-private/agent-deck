import React from 'react';
import {AbsoluteFill, Easing, Img, interpolate, Sequence, staticFile, useCurrentFrame} from 'remotion';
import './style.css';

const C = {bg:'#15181f',chrome:'#21252b',panel:'#282c34',text:'#dcdfe4',dim:'#a1a7b3',accent:'#c099ff',working:'#e5c07b',waiting:'#e06c75',done:'#56b6c2',orchestration:'#c678dd',green:'#98c379'};
const ease = Easing.bezier(.22,.75,.22,1);
const motion = (f:number,a:number,b:number,x:number,y:number) => interpolate(f,[a,b],[x,y],{extrapolateLeft:'clamp',extrapolateRight:'clamp',easing:ease});
const enter = (f:number,delay=0) => ({opacity:motion(f,delay,delay+20,0,1),transform:`translateY(${motion(f,delay,delay+24,24,0)}px)`});
const mono:React.CSSProperties = {fontFamily:'JetBrains Mono, monospace'};

const Logo:React.FC<{size?:number}> = ({size=48}) => <Img src={staticFile('icon.png')} style={{width:size,height:size}}/>;
const Kicker:React.FC<{children:React.ReactNode}> = ({children}) => <div className="kicker">{children}</div>;
const Subtitle:React.FC<{children:React.ReactNode}> = ({children}) => <div className="subtitle"><span>{children}</span></div>;
const Head:React.FC<{label:string;title:string;sub?:string}> = ({label,title,sub}) => <div style={{position:'absolute',left:112,top:115}}><Kicker>{label}</Kicker><h1>{title}</h1>{sub&&<p className="lead">{sub}</p>}</div>;
const Dot:React.FC<{color:string;ring?:boolean;dashed?:boolean}> = ({color,ring,dashed}) => <span style={{display:'inline-block',width:18,height:18,borderRadius:'50%',background:ring||dashed?'transparent':color,border:ring?`3px solid ${color}`:dashed?`3px dashed ${color}`:'none',flexShrink:0}}/>;
const Pill:React.FC<{children:React.ReactNode;color?:string}> = ({children,color=C.accent}) => <div className="pill" style={{color,borderColor:color+'55'}}>{children}</div>;

// 1200×760pt 앱 내부 그림을 2배로 캡처했다. x/y는 원래 앱의 pt 좌표다.
const Capture:React.FC<{name:string;x?:number;y?:number;scale?:number;style?:React.CSSProperties;label?:string;native?:boolean;pan?:number}> = ({name,x=0,y=0,scale=1.4,style,pan=0,label='AgentDeck · 데모 프로젝트',native=false}) => <div className="capture" style={style}>
  <div className="windowbar"><div style={{display:'flex',gap:9}}>{['#e06c75','#e5c07b','#98c379'].map(color=><i key={color} style={{background:color}}/>)}</div><span>{label}</span><span style={{color:C.accent}}>●</span></div>
  <div style={{position:'absolute',top:38,left:0,right:0,bottom:0,overflow:'hidden',background:C.panel}}>
    <Img src={staticFile(name+'.png')} style={{position:'absolute',maxWidth:'none',width:native?'100%':1200*scale,height:native?'auto':760*scale,left:native?0:-x*scale,top:native?-pan:-y*scale}}/>
  </div>
</div>;

const Frame:React.FC<{children:React.ReactNode;section:string;index:number;duration:number}> = ({children,section,index,duration}) => {
  const f=useCurrentFrame();
  return <AbsoluteFill style={{opacity:Math.min(motion(f,0,12,0,1),motion(f,duration-12,duration,1,0)),transform:`translateY(${motion(f,0,24,12,0)}px)`}}>
    <div className="topbrand"><Logo size={36}/><strong>AgentDeck</strong><span className="brandrule"/><span>{section}</span></div>
    <div className="topright">{String(index).padStart(2,'0')} <span>/ 08</span></div>
    {children}
  </AbsoluteFill>;
};

const Title:React.FC = () => {
  const f=useCurrentFrame();
  return <Frame index={1} duration={210} section="INTRODUCING">
    <div style={{position:'absolute',left:112,top:230,...enter(f,5)}}>
      <div style={{display:'flex',alignItems:'center',gap:30}}><Logo size={150}/><div><Kicker>YOUR AGENTS. ONE DECK.</Kicker><div style={{fontSize:112,fontWeight:750,letterSpacing:-5}}>AgentDeck<span style={{color:C.accent}}>.</span></div></div></div>
      <div style={{fontSize:66,lineHeight:1.45,fontWeight:650,letterSpacing:-2.4,marginTop:64}}>Claude·Codex 세션을 한 곳에서,<br/><span style={{color:C.accent}}>꺼져도 이어서.</span></div>
      <div style={{display:'flex',gap:15,marginTop:40,...enter(f,28)}}><Pill>macOS terminal</Pill><Pill color={C.dim}>Claude Code + Codex</Pill><Pill color={C.dim}>v0.4.0</Pill></div>
    </div>
    <div style={{position:'absolute',right:-230,top:260,width:760,height:760,border:'1px solid #c099ff28',borderRadius:180,transform:`rotate(-16deg) translateY(${motion(f,0,210,20,-15)}px)`}}><div style={{position:'absolute',inset:75,border:'1px solid #c099ff22',borderRadius:135}}/><div style={{position:'absolute',inset:150,border:'1px solid #c099ff15',borderRadius:90}}/></div>
  </Frame>;
};

const Problem:React.FC = () => {
  const f=useCurrentFrame();
  const cards=[{x:130,y:300,rot:-5,title:'shop-api',line:'결제 API 리팩터링',color:C.working},{x:695,y:360,rot:2,title:'shop-web',line:'어느 세션이 입력 대기였지?',color:C.waiting},{x:1250,y:280,rot:6,title:'feature/coupon',line:'다시 열고, 다시 resume…',color:C.orchestration}];
  return <Frame index={2} duration={210} section="THE FRICTION">
    <Head label="흩어진 작업, 끊기는 맥락" title="작업보다 세션 찾기가 먼저라면."/>
    {cards.map((c,i)=><div key={c.title} style={{position:'absolute',left:c.x,top:c.y,width:520,height:350,border:'1px solid #525765',borderRadius:16,background:C.chrome,boxShadow:'0 30px 60px #0005',opacity:motion(f,5+i*8,27+i*8,0,1),transform:`rotate(${c.rot}deg) translateY(${motion(f,5+i*8,40+i*8,55,0)}px)`}}>
      <div style={{padding:'22px 26px',borderBottom:'1px solid #3e4451',...mono,fontSize:25,color:C.dim}}>{c.title}</div>
      <div style={{padding:'42px 28px',fontSize:32,lineHeight:1.7}}><span style={{color:c.color}}>❯ </span>{c.line}<div style={{color:C.dim,fontSize:24,marginTop:28}}>세션 · 터미널 · 작업 트리</div></div>
    </div>)}
    <div style={{position:'absolute',left:112,top:800,fontSize:34,color:C.dim,...enter(f,75)}}>흩어진 터미널. 놓친 입력 요청. 재부팅 뒤의 복구.</div>
    <Subtitle>세션의 위치와 상태를, 한 창에서 관리하세요.</Subtitle>
  </Frame>;
};

const Spaces:React.FC = () => {
  const f=useCurrentFrame(); const collapsed=f>=390;
  const y=collapsed?24:motion(f,220,290,30,175);
  return <Frame index={3} duration={510} section="SPACES & LIVE STATUS">
    <Head label="01 / SPACES" title="폴더와 worktree가 작업의 지도가 됩니다."/>
    <Capture name={collapsed?'collapsed':'spaces'} x={0} y={y} scale={1.7} style={{left:112,top:258,width:930,height:644}} label={collapsed?'spaces · 접힌 그룹의 상태 합계':'spaces · 프로젝트와 하위 에이전트'}/>
    <div style={{position:'absolute',left:1120,top:290,width:660}}>
      <div style={{fontSize:40,fontWeight:650,marginBottom:35,...enter(f,15)}}>{collapsed?'접어도, 필요한 상태는 남습니다.':'지금, 누가 무엇을 기다리는지.'}</div>
      {[[C.working,'작업 중','응답과 도구 실행'],[C.waiting,'입력 대기','권한 요청 · 질문'],[C.done,'완료','확인할 결과'],[C.orchestration,'오케스트레이션 중','하위 에이전트 작업 계속']].map(([color,title,desc],i)=><div key={title} style={{display:'flex',gap:22,alignItems:'center',padding:'20px 0',borderBottom:'1px solid #ffffff12',...enter(f,25+i*9)}}><Dot color={color} ring={i===1} dashed={i===3}/><div><div style={{fontSize:38,color}}>{title}</div><div style={{fontSize:26,color:C.dim,marginTop:7}}>{desc}</div></div></div>)}
    </div>
    <Subtitle>{collapsed?'그룹을 접어도 상태 합계를 한눈에.':f<220?'프로젝트별 묶음 안에, worktree와 하위 에이전트까지.':'색과 글자로 읽는 작업 상태. 놓치지 않는 다음 행동.'}</Subtitle>
  </Frame>;
};

const Persistence:React.FC = () => {
  const f=useCurrentFrame(); const reboot=f>=180;
  return <Frame index={4} duration={390} section="PERSIST & RESUME">
    <Head label="02 / SESSION CONTINUITY" title={reboot?'재부팅 뒤에는, 같은 대화로.':'앱을 꺼도, 작업은 계속됩니다.'}/>
    <div style={{position:'absolute',left:112,top:306,width:1696,display:'flex',gap:30}}>
      <div className="continuity-card" style={{width:470,opacity:reboot?1:motion(f,80,120,1,.35)}}><Logo size={95}/><div className="cardtitle">AgentDeck 앱</div><div className="carddetail">{reboot?'탭·분할 배치 복구':'창을 닫고 나서도'}</div><div className="pill" style={{marginTop:32,color:reboot?C.accent:C.dim}}>{reboot?'원래 자리에서':'앱 종료'}</div></div>
      <div style={{width:100,display:'flex',justifyContent:'center',alignItems:'center',fontSize:56,color:C.accent}}>→</div>
      <div className="continuity-card" style={{width:510,borderColor:C.accent+'99'}}><div style={{fontSize:68,color:C.accent}}>{reboot?'↻':'◉'}</div><div className="cardtitle">{reboot?'세션 되살리기':'백그라운드 데몬'}</div><div className="carddetail">{reboot?'여는 탭만 다시 시작':'셸·에이전트를 계속 유지'}</div><div style={{...mono,fontSize:25,color:C.green,marginTop:32}}>{reboot?'claude --resume <ID>':'● session running'}</div></div>
      <div style={{width:100,display:'flex',justifyContent:'center',alignItems:'center',fontSize:56,color:C.accent}}>→</div>
      <div className="continuity-card" style={{width:470}}><div style={{fontSize:68,color:C.green}}>❯</div><div className="cardtitle">{reboot?'같은 대화 · 같은 옵션':'작업의 흐름 유지'}</div><div className="carddetail">{reboot?'Codex도 정확한 ID로 복구':'앱을 다시 열면 재연결'}</div><div style={{...mono,fontSize:24,color:C.dim,marginTop:32}}>{reboot?'codex resume <ID>':'Claude Code · Codex'}</div></div>
    </div>
    <div style={{position:'absolute',left:112,top:833,color:C.dim,fontSize:27}}>동작 설명{reboot?' · 재부팅 시 프로세스는 종료되고, 탭을 열 때 세션을 되살립니다.':' · 앱 종료 후에도 데몬이 세션을 유지합니다.'}</div>
    <Subtitle>{reboot?'기억한 배치에서, 원래 실행 옵션으로 이어갑니다.':'창을 닫는 것과, 세션을 끝내는 것은 다르니까요.'}</Subtitle>
  </Frame>;
};

const Splits:React.FC = () => {
  const f=useCurrentFrame();
  const phase=f<95?0:f<180?1:2;
  return <Frame index={5} duration={330} section="TABS & SPLITS">
    <Head label="03 / ARRANGE YOUR DECK" title="탭을 끌어, 작업을 나란히."/>
    <Capture name={['split-before','split-drag','split-after'][phase]} x={290} y={0} scale={1.9} style={{left:112,top:258,width:1696,height:640}}/>
    <div style={{position:'absolute',right:144,top:790,display:'flex',gap:14}}><Pill>{phase===0?'01  탭 선택':phase===1?'02  가장자리로 끌기':'03  분할 완료'}</Pill><Pill color={C.dim}>⌘D / ⇧⌘D</Pill></div>
    <Subtitle>좌우·위아래 분할. 배치를 바꿔도 세션은 그대로.</Subtitle>
  </Frame>;
};

const Editor:React.FC = () => {
  const f=useCurrentFrame(); const phase=f<150?0:f<300?1:2;
  const titles=['파일에서 편집까지, 한 흐름으로.','Markdown은 읽기 좋은 미리보기로.','코드의 맥락을, 바로 따라갑니다.'];
  return <Frame index={6} duration={450} section="FILES & LIGHTWEIGHT EDITOR">
    <Head label="04 / STAY IN CONTEXT" title={titles[phase]}/>
    <Capture name={['files','markdown','definition'][phase]} x={phase===0?0:phase===1?330:280} y={0} scale={phase===0?1.5:phase===1?2:1.9} style={{left:112,top:258,width:1696,height:640}}/>
    <div style={{position:'absolute',right:145,top:788,display:'flex',gap:16}}>{phase===0?<><Pill color="#7aa6da">M 변경</Pill><Pill color={C.green}>A 추가</Pill><Pill color="#bc8f73">U 미추적</Pill></>:phase===1?<Pill>⇧⌘V · Markdown 미리보기</Pill>:<><Pill>⌘B 선언 이동</Pill><Pill color={C.dim}>⌥F7 사용 위치</Pill><Pill color={C.dim}>⌘O 심볼</Pill></>}</div>
    <Subtitle>{['git 상태 색으로 찾고, 오른쪽 미리보기에서 확인하세요.','작성 중인 문서도, 저장 전에 미리 볼 수 있습니다.','가벼운 편집기에 선언·사용 위치·심볼 이동까지.'][phase]}</Subtitle>
  </Frame>;
};

const Preferences:React.FC = () => {
  const f=useCurrentFrame(); const settings=f>=150;
  return <Frame index={7} duration={360} section="NOTIFICATIONS & LAUNCH OPTIONS">
    <Head label={settings?'05 / LAUNCH OPTIONS':'05 / KNOW WHEN TO RETURN'} title={settings?'새 세션의 시작 옵션도 한곳에서.':'필요할 때, 다시 돌아오세요.'}/>
    {settings?<>
      <Capture name="settings" native pan={motion(f,235,295,70,790)} style={{left:112,top:258,width:1090,height:646}} label="설정 · 개발 중 기능"/>
      <div style={{position:'absolute',left:1280,top:330,width:500,...enter(f,160)}}><Pill>⌘, 설정</Pill><div style={{fontSize:48,fontWeight:650,marginTop:40,lineHeight:1.45}}>Claude·Codex<br/>실행 옵션</div><p className="lead" style={{fontSize:32,lineHeight:1.8}}>모델과 권한 옵션<br/>실행 명령 미리보기</p><div style={{fontSize:26,color:C.dim,marginTop:36}}>현재 브랜치의 다음 판 기능</div></div>
    </>:<>
      <Capture name="spaces" x={0} y={310} scale={1.8} style={{left:112,top:258,width:900,height:644}} label="spaces · 확인이 필요한 세션"/>
      <div style={{position:'absolute',left:1080,top:310,width:710}}>
        <div style={{fontSize:25,color:C.dim,marginBottom:24}}>알림 동작 설명 · 연출 화면</div>
        {[[C.done,'완료 · 배포 가이드 정리','검토할 결과가 준비되었습니다.'],[C.waiting,'입력 대기 · 체크아웃 UI 개선','권한 요청을 확인해 주세요.']].map(([color,title,body],i)=><div key={title} className="notification" style={{...enter(f,18+i*20),marginBottom:25}}><Logo size={60}/><div><div style={{fontSize:24,color:C.dim}}>AgentDeck</div><div style={{fontSize:30,color,margin:'9px 0'}}>{title}</div><div style={{fontSize:26}}>{body}</div></div></div>)}
        <div style={{fontSize:30,color:C.dim,lineHeight:1.65,marginTop:32}}>알림을 누르면 해당 화면으로.<br/>Dock 배지로 미확인 작업 확인.</div>
      </div>
    </>}
    <Subtitle>{settings?'새 세션은 기본 옵션으로. 되살릴 때는 원래 옵션으로.':'완료·입력 대기·오류를 알림으로 확인하세요.'}</Subtitle>
  </Frame>;
};

export const INSTALL = "gh api repos/jonghyungJeon-private/agent-deck/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash";
const Closing:React.FC = () => {
  const f=useCurrentFrame();
  return <Frame index={8} duration={300} section="READY FOR YOUR NEXT SESSION">
    <div style={{position:'absolute',left:112,top:190,...enter(f,6)}}>
      <div style={{display:'flex',gap:25,alignItems:'center'}}><Logo size={100}/><div style={{fontSize:86,fontWeight:750,letterSpacing:-3}}>AgentDeck <span style={{color:C.accent,fontSize:35,...mono}}>0.4.0</span></div></div>
      <div style={{fontSize:65,fontWeight:650,lineHeight:1.4,marginTop:48}}>흩어진 세션을 모으고,<br/><span style={{color:C.accent}}>작업의 맥락을 이어가세요.</span></div>
    </div>
    <div style={{position:'absolute',left:112,top:580,width:1696,padding:'28px 34px',background:C.chrome,border:'1px solid #c099ff60',borderRadius:18,...enter(f,28)}}>
      <div style={{fontSize:24,color:C.dim,marginBottom:18}}>설치 · 업데이트 / README의 한 줄 명령</div>
      <code style={{display:'block',fontSize:29,lineHeight:1.8,whiteSpace:'pre-wrap',overflowWrap:'anywhere',color:C.text}}>{INSTALL}</code>
    </div>
    <div style={{position:'absolute',left:112,top:827,fontSize:28,color:C.dim,...enter(f,36)}}>Apple Silicon · macOS 13+ · GitHub CLI 로그인 및 비공개 저장소 접근 권한 필요</div>
    <Subtitle>Claude·Codex 세션을 한 곳에서, 꺼져도 이어서.</Subtitle>
  </Frame>;
};

const Background:React.FC = () => <AbsoluteFill style={{background:C.bg,color:C.text,fontFamily:'-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif'}}><div style={{position:'absolute',inset:0,background:'radial-gradient(ellipse at 85% 15%, #c099ff13 0%, transparent 60%)'}}/><div style={{position:'absolute',left:112,right:112,top:87,height:1,background:'#ffffff14'}}/></AbsoluteFill>;
export const Intro:React.FC = () => {
  const f=useCurrentFrame();
  const scenes=[{at:0,len:210,node:<Title/>},{at:210,len:210,node:<Problem/>},{at:420,len:510,node:<Spaces/>},{at:930,len:390,node:<Persistence/>},{at:1320,len:330,node:<Splits/>},{at:1650,len:450,node:<Editor/>},{at:2100,len:360,node:<Preferences/>},{at:2460,len:300,node:<Closing/>}];
  return <AbsoluteFill style={{color:C.text,fontFamily:'-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif'}}><Background/>{scenes.map(s=><Sequence key={s.at} from={s.at} durationInFrames={s.len}>{s.node}</Sequence>)}<div style={{position:'absolute',left:0,bottom:0,height:3,width:1920*f/2759,background:C.accent}}/></AbsoluteFill>;
};

export const Teaser:React.FC = () => {
  const f=useCurrentFrame();
  return <AbsoluteFill style={{color:C.text,fontFamily:'-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif'}}><Background/>
    <div className="topbrand"><Logo size={36}/><strong>AgentDeck</strong><span className="brandrule"/><span>Claude Code + Codex</span></div>
    <div style={{position:'absolute',left:112,top:145,fontSize:70,lineHeight:1.35,fontWeight:700,background:C.bg}}>세션을 한곳에.<br/><span style={{color:C.accent}}>꺼져도 이어서.</span></div>
    <Capture name={f<210?'spaces':'split-after'} x={f<210?0:290} y={f<210?35:0} scale={f<210?1.55:1.9} style={{left:112,top:365,width:1696,height:530}}/>
    <Subtitle>{f<210?'프로젝트·worktree·하위 에이전트의 상태를 한눈에.':'탭·분할, 파일·편집기까지. AgentDeck 0.4.0'}</Subtitle>
  </AbsoluteFill>;
};
