import Foundation

/// 페이지 위 마우스 자리의 커서 종류. 브라우저 칸이 그림(screencast)이라 페이지가 정한 커서가 안 보이므로
/// 마우스 밑 요소를 페이지에 물어(`queryScript`) 맥 커서로 바꿔 보인다.
public enum PageCursor: Equatable, Sendable {
    case arrow, pointer, text, notAllowed, openHand, closedHand, crosshair, resizeHorizontal, resizeVertical

    /// 페이지에서 (x, y)(CSS 픽셀) 밑 요소의 커서를 "css커서|입력칸|글자|링크" 한 줄로 돌려주는 식.
    /// 입력칸 = input(글자 받는 종류)·textarea·contenteditable, 글자 = 그 점이 글자 위, 링크 = a[href]·button 안.
    public static func queryScript(x: Double, y: Double) -> String {
        """
        (() => { const x = \(Int(x.rounded())), y = \(Int(y.rounded()));
          let el = document.elementFromPoint(x, y);
          for (let i = 0; el && el.shadowRoot && i < 8; i++) { const inner = el.shadowRoot.elementFromPoint(x, y); if (!inner || inner === el) break; el = inner; }
          if (!el) return 'default|0|0|0';
          const cs = getComputedStyle(el).cursor || 'auto';
          const plain = ['button','submit','checkbox','radio','range','color','file','image','reset'];
          const field = !!(el.isContentEditable || el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && !plain.includes(el.type)));
          let text = false;
          if (!field && getComputedStyle(el).userSelect !== 'none' && document.caretRangeFromPoint) {
            const r = document.caretRangeFromPoint(x, y);
            if (r && r.startContainer.nodeType === 3) {
              const range = document.createRange(); range.selectNodeContents(r.startContainer);
              for (const b of range.getClientRects()) if (x >= b.left && x <= b.right && y >= b.top && y <= b.bottom) { text = true; break; }
            }
          }
          const link = !!el.closest('a[href],button,summary,[role=button],[role=link]');
          return [cs, field ? 1 : 0, text ? 1 : 0, link ? 1 : 0].join('|'); })()
        """
    }

    /// `queryScript` 의 답을 커서 종류로. 못 읽으면 화살표.
    /// - pointer → 손가락, text 류 → I빔, not-allowed 류 → 금지, grab → 편 손, 그 밖의 이름 있는 커서는 대응하는 것, 나머지는 화살표
    /// - auto 는 브라우저가 고른다: 입력칸·글자 위면 I빔, 링크면 손가락
    public static func parse(_ raw: String?) -> PageCursor {
        guard let raw else { return .arrow }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return .arrow }
        let field = parts[1] == "1", text = parts[2] == "1", link = parts[3] == "1"
        switch parts[0].lowercased() {
        case "pointer": return .pointer
        case "text", "vertical-text": return .text
        case "not-allowed", "no-drop": return .notAllowed
        case "grab": return .openHand
        case "grabbing": return .closedHand
        case "crosshair": return .crosshair
        case "ew-resize", "col-resize", "e-resize", "w-resize": return .resizeHorizontal
        case "ns-resize", "row-resize", "n-resize", "s-resize": return .resizeVertical
        case "auto":
            if field || text { return .text }
            return link ? .pointer : .arrow
        default: return .arrow
        }
    }
}
