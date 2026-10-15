// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeSessions",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeSessions", targets: ["ClaudeSessions"]),
        // 내장 터미널 시제품: 화면 앱 + 세션을 붙잡고 있는 데몬
        .executable(name: "ClaudeTerm", targets: ["ClaudeTerm"]),
        .executable(name: "ClaudeTermDaemon", targets: ["ClaudeTermDaemon"]),
    ],
    dependencies: [
        // 한글 입력·글자 폭을 고친 SwiftTerm 1.20.0 사본(Vendor/SwiftTerm/PATCHES.md)
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .target(name: "SessionCore"),
        .executableTarget(name: "ClaudeSessions", dependencies: ["SessionCore"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),

        // 앱과 데몬이 주고받는 메시지 형식
        .target(name: "TermWire"),
        // forkpty + exec (Swift 에서 fork 뒤 코드를 안전하게 돌리기 어려워 C 로 둔다)
        .target(name: "CPTY"),
        .executableTarget(name: "ClaudeTermDaemon", dependencies: ["TermWire", "CPTY", "SessionCore"]),
        // 탭·분할 배치, git 작업 트리 읽기(화면과 떨어진 순수 로직이라 따로 시험한다)
        .target(name: "TermLayout"),
        .executableTarget(name: "ClaudeTerm", dependencies: [
            "TermWire", "SessionCore", "TermLayout", .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .testTarget(name: "TermWireTests", dependencies: ["TermWire"]),
        .testTarget(name: "TermLayoutTests", dependencies: ["TermLayout"]),
    ]
)
