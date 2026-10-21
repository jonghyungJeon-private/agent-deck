#!/usr/bin/env python3
"""QA pane 의 ANSI 출력과 앱 CPU 측정. 실제 에이전트 CLI 는 쓰지 않는다.
  animate --control <scratch>/mode
  full-frame --control <scratch>/mode --fps 12
  sample <app-pid> <output.csv>
mode 파일: animate, idle, burst, static, scrollback, quit.
idle 모드는 정적 TUI 이며 셸 idle 측정용이 아니다. idle 측정은 quit 뒤 실제 프롬프트에서 한다.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import statistics

ESC = '\x1b['

def full_frame(control, fps, variant):
    """현재 pane 크기 그대로, 같은 본문도 매 프레임 다시 전송한다."""
    Path(str(control) + '.pid').write_text(str(os.getpid()))
    cols, rows = shutil.get_terminal_size()
    # 한글은 두 칸. 끝 칸 자동 줄바꿈 대신 행마다 커서를 옮긴다.
    unit = '한글 가나다 ABC abc 0123 ─┬─ │ '
    width = sum(2 if '\uac00' <= ch <= '\ud7a3' else 1 for ch in unit)
    body = unit * ((cols - 2) // width)
    body += ' ' * (cols - 2 - width * ((cols - 2) // width))
    lines = []
    for row in range(rows - 2):
        text = '┌' + '─' * (cols - 2) + '┐' if row == 0 else '│' + body + '│'
        lines.append(f'{ESC}{row+1};1H{ESC}{1 if row%3==0 else 22};38;5;{16+row*7%216}m{text}')
    base = ''.join(lines)
    changing = max(1, round(rows * 0.30) - 2)
    frames, total = 0, 0
    started = time.monotonic()
    sys.stdout.write(ESC + '?1049h' + ESC + '?7l')
    sys.stdout.flush()
    try:
        while not control.exists() or control.read_text().strip() != 'quit':
            if variant == 'spinner' and frames:
                body_frame = ''
            elif variant == 'thirty':
                # 스피너·상태 줄을 합해 전체 행의 약 30% 를 바꾼다.
                body_frame = ''.join(line.replace('0123', f'{frames % 10000:04d}') if 1 <= row <= changing else line
                                     for row, line in enumerate(lines))
            else:
                body_frame = base
            frame = (body_frame + f'{ESC}{rows-1};1H{ESC}0m{ESC}2K'
                     f'{"⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[frames%10]} 작업 중 · {variant} {fps:g}fps · {frames:06d}'
                     f'{ESC}{rows};1H{ESC}2Kstatus {frames//24:04d} · 한글 입력 대기{ESC}{rows};40H')
            data = frame.encode()
            sys.stdout.buffer.write(data)
            sys.stdout.flush()
            frames += 1
            total += len(data)
            time.sleep(max(0, started + frames/fps - time.monotonic()))
    finally:
        seconds = time.monotonic() - started
        Path(str(control)+'.full.json').write_text(json.dumps({'cols':cols,'rows':rows,'frames':frames,'seconds':seconds,'fps':frames/seconds,'bytes':total,'variant':variant}))
        sys.stdout.write(ESC+'0m'+ESC+'?7h'+ESC+'?1049l')
        sys.stdout.flush()

def animate(control):
    Path(str(control) + '.pid').write_text(str(os.getpid()))
    previous = None
    frame = 0
    started = time.monotonic()
    def emit(text):
        sys.stdout.write(text)
        sys.stdout.flush()
    def layout():
        size = shutil.get_terminal_size((120, 40))
        cols, rows = min(120, size.columns), min(40, size.lines)
        lines = [f'{ESC}1;38;5;117mAgentDeck QA · 한글 가독성 · Claude 같은 화면{ESC}0m',
                 '┌' + '─' * (cols - 2) + '┐']
        for row in range(2, rows - 4):
            text = f'│ {row:02d} 한글 가나다 · ABC abc 0123 ─┬─ │ '
            lines.append(f'{ESC}38;5;{16 + row * 7 % 216}m{text}{ESC}1m굵은 한글 Bold{ESC}0m')
        lines += ['└' + '─' * (cols - 2) + '┘', '입력 > 한글 조합 / cursor', '', '']
        emit(ESC + 'H' + ESC + '2J' + '\r\n'.join(lines) + ESC + '?25h')
        return rows
    rows = 40
    try:
        emit(ESC + '?1049h')
        while True:
            mode = control.read_text().strip() if control.exists() else 'animate'
            if mode == 'quit':
                break
            if mode != previous:
                if mode == 'scrollback':
                    emit(ESC + '?1049l' + ''.join(f'{n:04d} 한글 scrollback ─┼─ {ESC}38;5;117mcolor{ESC}0m\r\n' for n in range(600)))
                elif mode == 'burst':
                    emit(ESC + '?1049l')
                    chunk = ('throughput 한글 0123456789\r\n' * 1000).encode()
                    total = 0
                    t = time.monotonic()
                    while total < 50 * 1024 * 1024:
                        os.write(sys.stdout.fileno(), chunk)
                        total += len(chunk)
                    Path(str(control) + '.burst.json').write_text(json.dumps({'bytes': total, 'seconds': time.monotonic()-t}))
                else:
                    emit(ESC + '?1049h')
                    rows = layout()
                previous = mode
                frame = 0
            if mode == 'animate':
                if frame and frame % 144 == 0:
                    rows = layout()
                emit(f'{ESC}{rows-1};1H{ESC}2K{ESC}38;5;147m{"⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[frame%10]} 작업 중 · rendering spinner{ESC}0m')
                if frame % 36 == 0:
                    emit(f'{ESC}{rows};1H{ESC}2K{ESC}38;5;117mstatus {frame//36:04d} · 입력 대기{ESC}0m')
                emit(f'{ESC}{rows-2};22H')
                frame += 1
            time.sleep(max(0, started + 1/18 - time.monotonic()))
            started = time.monotonic()
    finally:
        emit(ESC + '0m' + ESC + '?25h' + ESC + '?1049l')

def sample(pid, output, seconds, notifier=None, channel=None, state_log=None):
    rows = []
    started = time.monotonic()
    states = []
    for i in range(seconds + 1):
        value = subprocess.check_output(['ps', '-o', '%cpu=,time=,rss=', '-p', str(pid)], text=True).split()
        rows.append([time.time(), *value])
        if notifier and channel and state_log:
            subprocess.run([str(notifier), channel, 'render-state'], check=True)
            time.sleep(0.1)
            state = next((line for line in reversed(state_log.read_text().splitlines()) if line.startswith('render-state')), '')
            states.append(state)

        if i < seconds:
            time.sleep(max(0, started + i + 1 - time.monotonic()))
    with output.open('w') as f:
        writer = csv.writer(f)
        writer.writerow(['timestamp', 'cpu_percent', 'cpu_time', 'rss_kib'])
        writer.writerows(rows)
    values = [float(row[1]) for row in rows]
    def cpu_seconds(value):
        parts = value.split(':')
        return sum(float(part)*60**i for i,part in enumerate(reversed(parts)))
    elapsed = float(rows[-1][0])-float(rows[0][0])
    used = cpu_seconds(rows[-1][2])-cpu_seconds(rows[0][2])
    result = {'output':str(output),'samples':len(rows),'mean_ps_cpu':statistics.mean(values),
              'cpu_seconds':used,'wall_seconds':elapsed,'cpu_time_percent':100*used/elapsed,
              'min':min(values),'max':max(values)}
    if states:
        result['visible_samples'] = sum('visible=true' in state for state in states)
        result['all_visible'] = result['visible_samples'] == len(states)
        output.with_suffix('.states.json').write_text(json.dumps(states, indent=2))
    output.with_suffix('.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result), flush=True)

parser = argparse.ArgumentParser(description=__doc__)
sub = parser.add_subparsers(dest='command', required=True)
a = sub.add_parser('animate')
a.add_argument('--control', type=Path, required=True)
f = sub.add_parser('full-frame')
f.add_argument('--control', type=Path, required=True)
f.add_argument('--fps', type=float, default=12)
f.add_argument('--variant', choices=['full', 'spinner', 'thirty'], default='full')
s = sub.add_parser('sample')
s.add_argument('pid', type=int)
s.add_argument('output', type=Path)
s.add_argument('--seconds', type=int, default=30)
s.add_argument('--notifier', type=Path)
s.add_argument('--debug-channel')
s.add_argument('--state-log', type=Path)
args = parser.parse_args()
if args.command == 'animate':
    animate(args.control)
elif args.command == 'full-frame':
    full_frame(args.control, args.fps, args.variant)
else:
    sample(args.pid, args.output, args.seconds, args.notifier, args.debug_channel, args.state_log)
