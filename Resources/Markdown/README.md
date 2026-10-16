# Markdown 변환기 사본 (편집기 미리보기용)

- marked v18.0.14 (MIT, `LICENSE`) — https://github.com/markedjs/marked
- 받은 곳: https://cdn.jsdelivr.net/npm/marked@18.0.14/lib/marked.umd.js (고치지 않은 원본)
- sha256: `21568877a938d2c4e7d74e27f18e60da96bb73a68809610ca39216e1efebae62`

앱은 이 파일을 웹 화면이 아니라 JavaScriptCore 에서 돌려 HTML 을 만들고, `HTMLSanitizer`(Sources/EditorCore/Markdown.swift)로
거른 뒤 스크립트를 끈 WKWebView 에 보인다. `scripts/build-term-proto.sh` 가 `marked.umd.js`·`LICENSE` 를 앱 묶음
`Contents/Resources/Markdown/` 으로 복사한다. 올릴 때는 같은 주소에서 정확한 버전으로 받고 위 버전·해시를 고친다.
