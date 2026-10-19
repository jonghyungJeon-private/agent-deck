// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v13)],
    products: [
        // 화면 앱 + 세션을 붙잡고 있는 데몬(hook 처리도 맡는다)
        .executable(name: "AgentDeck", targets: ["AgentDeck"]),
        .executable(name: "AgentDeckDaemon", targets: ["AgentDeckDaemon"]),
    ],
    dependencies: [
        // 한글 입력·글자 폭을 고친 SwiftTerm 1.20.0 사본(Vendor/SwiftTerm/PATCHES.md)
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        // 앱과 데몬이 주고받는 메시지 형식, 데이터 위치(예전 ClaudeSessions 폴더에서 옮기기 포함)
        .target(name: "TermWire"),
        .target(name: "SessionCore", dependencies: ["TermWire"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore", "TermWire"]),

        // forkpty + exec (Swift 에서 fork 뒤 코드를 안전하게 돌리기 어려워 C 로 둔다)
        .target(name: "CPTY"),
        .executableTarget(name: "AgentDeckDaemon", dependencies: ["TermWire", "CPTY", "SessionCore"]),
        // 탭·분할 배치, git 작업 트리 읽기(화면과 떨어진 순수 로직이라 따로 시험한다)
        .target(name: "TermLayout"),
        // 가벼운 편집기의 화면 없는 부분: 줄 diff(git 변경 표시), 줄 끝·바이너리 판별·안전한 저장, 글자 색 훑기
        .target(name: "EditorCore"),
        .executableTarget(name: "AgentDeck", dependencies: [
            "TermWire", "SessionCore", "TermLayout", "EditorCore", .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .testTarget(name: "TermWireTests", dependencies: ["TermWire"]),
        .testTarget(name: "TermLayoutTests", dependencies: ["TermLayout"]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        // Vendor/SwiftTerm 에 고친 것(PATCHES.md) 중 화면 없이 시험할 수 있는 것
        .testTarget(name: "SwiftTermPatchTests", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
    ]
)
