// swift-tools-version:5.10
import PackageDescription

// SwiftTerm v1.20.0 (5d14406) 을 AgentDeck 용으로 고친 사본. 고친 내용은 PATCHES.md.
// 원본의 빌드 정보 플러그인·예제·테스트·iOS 소스는 뺐다.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [.process("Apple/Metal/Shaders.metal")]
        ),
    ]
)
