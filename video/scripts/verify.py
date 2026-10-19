#!/usr/bin/env python3
"""출력 형식 검증 + 8개 대표 프레임. stdlib와 ffmpeg만 사용한다."""
import json, pathlib, shutil, subprocess
V=pathlib.Path(__file__).resolve().parents[1]
O=V/'out'; F=O/'frames'; F.mkdir(parents=True,exist_ok=True)
ffmpeg=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
ffprobe=shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
def call(args):
    p=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    scratch=V/'.work'; scratch.mkdir(exist_ok=True)
    with (scratch/'pids.log').open('a') as f: f.write(f'{p.pid} verify {args[0]}\n')
    out,err=p.communicate()
    if p.returncode: raise RuntimeError(err.decode())
    return out
def probe(file):
    return json.loads(call([ffprobe,'-v','error','-show_entries','format=duration,size:stream=index,codec_type,codec_name,width,height,r_frame_rate,pix_fmt','-of','json',str(file)]))
data=probe(O/'AgentDeck-intro.mp4')
(O/'ffprobe.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
video=[s for s in data['streams'] if s['codec_type']=='video']
assert len(video)==1 and len(data['streams'])==1, data
s=video[0]
assert (s['width'],s['height'],s['codec_name'],s['r_frame_rate'])==(1920,1080,'h264','30/1'),s
assert s['pix_fmt'] in ['yuv420p','yuvj420p'],s
assert abs(float(data['format']['duration'])-92)<.05,data
shots=[(3,'01-title'),(10,'02-problem'),(21,'03-spaces'),(39,'04-resume'),(52,'05-splits'),(58,'06-editor'),(78,'07-settings'),(87,'08-install')]
for second,name in shots:
    call([ffmpeg,'-v','error','-y','-ss',str(second),'-i',str(O/'AgentDeck-intro.mp4'),'-frames:v','1','-threads','2',str(F/(name+'.png'))])
call([ffmpeg,'-v','error','-y','-pattern_type','glob','-i',str(F/'0*.png'),'-vf','scale=480:270,tile=4x2:padding=8:margin=8:color=0x15181f','-frames:v','1','-threads','2',str(O/'contact-sheet.png')])
if (O/'AgentDeck-teaser.mp4').exists():
    teaser=probe(O/'AgentDeck-teaser.mp4')
    assert len(teaser['streams'])==1 and 10<=float(teaser['format']['duration'])<=15,teaser
    (O/'teaser-ffprobe.json').write_text(json.dumps(teaser,indent=2)+'\n')
print(json.dumps(data,indent=2))
print('PASS: 92s / 1920×1080 / 30fps / H.264 '+s['pix_fmt']+' / audio streams: 0')
