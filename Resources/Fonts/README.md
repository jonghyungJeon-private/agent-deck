# 앱에 넣은 글꼴

앱은 이 폴더의 `.ttf` 를 자기 프로세스에만 등록해 쓴다(`TermAppearance.registerBundledFonts`, 사용자 글꼴 폴더는 건드리지 않음).
`scripts/build-term-proto.sh` 가 폴더째 앱 묶음 `Contents/Resources/Fonts/` 로 복사한다.

| 글꼴 | 쓰는 곳 | 라이선스 |
|---|---|---|
| JetBrains Mono (Regular·Bold·Italic·BoldItalic) | 터미널·편집기·사이드바 글자 | OFL 1.1 (`JetBrainsMono-OFL.txt`) |
| Symbols Nerd Font Mono | 아이콘 글자 | MIT (`SymbolsNerdFont-LICENSE.txt`) |
| D2Coding (Regular·Bold) | 한글(고정폭, 터미널 굵은 글자도) | OFL 1.1 (`D2Coding-OFL.txt`) |

## D2Coding

- 버전: 1.3.2 (2018-05-24), 고치지 않은 원본 — https://github.com/naver/d2-coding-font
- 받은 곳: https://github.com/naver/d2-coding-font/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip
  (sha256 `0f1c9192eac7d56329dddc620f9f1666b707e9c8ed38fe1f988d0ae3e30b24e6`)
- zip 의 `D2Coding/` 에서 두 파일만 넣었다(합본 ttc·리거처 판은 뺌):
  - `D2Coding-Ver1.3.2-20180524.ttf` — sha256 `8b1b23e5de4dff652fb0b938528150d2f531edfda281d3944618b655711aba84`
  - `D2CodingBold-Ver1.3.2-20180524.ttf` — sha256 `dde75df435f061eaa0f6db84b1c30866aaa442d7038aaa62ea3c2be92f15d87d`
- 라이선스 본문: 저장소의 `LICENSE.md` 를 그대로 옮김(`D2Coding-OFL.txt`).
- 올릴 때는 같은 방식으로 정확한 릴리스 zip 을 받아 위 버전·해시를 고친다.
