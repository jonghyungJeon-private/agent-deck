import EditorCore
import Foundation
import XCTest

final class SymbolScannerTests: XCTestCase {
    /// "이름@줄(1부터):종류" 목록
    private func decls(_ text: String, _ language: SyntaxLanguage, locals: Bool = false) -> [String] {
        SymbolScanner.scan(text, language: language, includeLocals: locals).map { "\($0.name)@\($0.line + 1):\($0.kind.label)" }
    }

    private func find(_ text: String, _ language: SyntaxLanguage, _ name: String) -> SymbolDeclaration? {
        SymbolScanner.scan(text, language: language).first { $0.name == name }
    }

    func testKotlinDeclarations() {
        let source = """
        package com.example.user

        import org.springframework.stereotype.Service

        /** 사용자 서비스 — fun notAFunction() 은 주석 */
        @Service
        class UserService(
            private val userRepository: UserRepository,
            val clock: Clock,
        ) : BaseService() {
            private val log = "fun fake() in string"
            companion object {
                const val MAX_SIZE = 10
                fun create(): UserService = TODO()
            }

            fun findById(id: Long): User? {
                val local = 1
                return userRepository.find(id)
            }

            suspend fun <T> load(type: Class<T>): T = TODO()
            constructor() : this(UserRepository(), Clock())
        }

        data class User(val id: Long, var name: String)
        enum class Status { ACTIVE, INACTIVE; fun label() = name }
        sealed interface Event
        object Registry {
            val items = mutableListOf<String>()
        }
        fun String.toSlug(): String = lowercase()
        fun <T> List<T>.second(): T = this[1]
        typealias UserId = Long
        annotation class Audited(val value: String)
        fun interface Handler { fun handle() }
        val topLevel: Int get() = 1
        """
        let found = decls(source, .kotlin)
        let expected = [
            "UserService@7:class", "userRepository@8:property", "clock@9:property", "log@11:property",
            "MAX_SIZE@13:constant", "create@14:method", "findById@17:method", "load@22:method",
            "UserService@23:constructor", "User@26:class", "id@26:property", "name@26:property",
            "Status@27:enum", "ACTIVE@27:enum case", "INACTIVE@27:enum case", "label@27:method",
            "Event@28:interface", "Registry@29:object", "items@30:property", "toSlug@32:function",
            "second@33:function", "UserId@34:type", "Audited@35:annotation", "value@35:property",
            "Handler@36:interface", "handle@36:method", "topLevel@37:property",
        ]
        XCTAssertEqual(found, expected)
        // 함수 안 지역 변수는 기본으로 빼고, includeLocals 면 넣는다
        XCTAssertFalse(found.contains { $0.hasPrefix("local@") })
        XCTAssertTrue(decls(source, .kotlin, locals: true).contains("local@18:variable"))
        // 멤버의 감싸는 타입
        XCTAssertEqual(find(source, .kotlin, "findById")?.container, "UserService")
        XCTAssertEqual(find(source, .kotlin, "MAX_SIZE")?.container, "UserService")
        XCTAssertEqual(find(source, .kotlin, "label")?.container, "Status")
    }

    func testKotlinAnnotationsAndModifiers() {
        let source = """
        @Configuration
        @EnableConfigurationProperties(AppProps::class)
        open class AppConfig @Inject constructor(private val props: AppProps) {
            @Bean fun objectMapper(): ObjectMapper = ObjectMapper()
            @field:JsonProperty("x") lateinit var x: String
            override fun toString() = "AppConfig"
            private val handler = object : Handler {
                override fun handle() {}
            }
        }
        @JvmInline value class Email(val raw: String)
        """
        XCTAssertEqual(decls(source, .kotlin), [
            "AppConfig@3:class", "props@3:property", "objectMapper@4:method", "x@5:property", "toString@6:method",
            "handler@7:property", "Email@11:class", "raw@11:property",
        ])
    }

    func testJavaDeclarations() {
        let source = """
        package com.example;

        import java.util.List;

        @RestController
        @RequestMapping("/users")
        public class UserController extends BaseController implements Api {
            private static final Logger log = LoggerFactory.getLogger(UserController.class);
            public static final int MAX_PAGE = 100;
            private final UserService userService;
            private Map<String, List<Integer>> cache = new HashMap<>();

            public UserController(UserService userService) {
                this.userService = userService;
                int local = 1;
            }

            @GetMapping("/{id}")
            public ResponseEntity<User> findById(@PathVariable Long id) throws NotFoundException {
                return userService.find(id); // String fake() 주석
            }

            public <T extends Comparable<T>> List<T> sorted(List<T> items,
                                                             Comparator<T> comparator) {
                return items;
            }

            protected static int[] numbers() { return new int[0]; }

            static class Inner {
                void run() {}
            }

            interface Callback { void done(String result); }

            enum Mode { FAST("f"), SLOW("s"); private final String code; Mode(String code) { this.code = code; } }

            record Point(int x, List<String> labels) {}

            @interface Marker { String value() default ""; }
        }
        """
        XCTAssertEqual(decls(source, .java), [
            "UserController@7:class", "log@8:field", "MAX_PAGE@9:constant", "userService@10:field", "cache@11:field",
            "UserController@13:constructor", "findById@19:method", "sorted@23:method", "numbers@28:method",
            "Inner@30:class", "run@31:method", "Callback@34:interface", "done@34:method",
            "Mode@36:enum", "FAST@36:enum case", "SLOW@36:enum case", "code@36:field", "Mode@36:constructor",
            "Point@38:record", "x@38:field", "labels@38:field", "Marker@40:annotation", "value@40:method",
        ])
    }

    func testTypeScriptDeclarations() {
        let source = """
        import { Injectable } from '@angular/core';

        export interface User {
          id: number;
          name?: string;
          greet(other: User): string;
        }

        export type UserId = string | number;
        export enum Role { Admin = 'admin', Guest }

        @Injectable()
        export class UserService {
          private cache = new Map<string, User>();
          constructor(private readonly http: Http) {}
          async load(id: UserId): Promise<User> {
            const local = 1;
            return this.http.get(`/users/${id}`);
          }
          get size(): number { return this.cache.size; }
        }

        export function formatUser(user: User): string { return user.name ?? ''; }
        export const DEFAULT_ROLE = Role.Guest;
        export const useUser = (id: string) => useQuery(id);
        const handler = async function () {};
        export default function App() {}
        namespace Utils { export function helper() {} }
        """
        XCTAssertEqual(decls(source, .typescript), [
            "User@3:interface", "id@4:property", "name@5:property", "greet@6:method", "UserId@9:type",
            "Role@10:enum", "Admin@10:enum case", "Guest@10:enum case", "UserService@13:class", "cache@14:property",
            "UserService@15:constructor", "load@16:method", "size@20:method", "formatUser@23:function",
            "DEFAULT_ROLE@24:constant", "useUser@25:function", "handler@26:function", "App@27:function",
            "Utils@28:module", "helper@28:function",
        ])
    }

    func testSwiftDeclarations() {
        let source = """
        import AppKit

        /// 문서 — func fake() 은 주석
        final class EditorDocument: NSObject {
            static let limit = 500
            private(set) var isDirty = false
            @Published var name: String = "x"
            init(path: String) { self.name = path }
            convenience init() { self.init(path: "") }
            func save() -> Bool {
                let local = 1
                return true
            }
            class func make() -> EditorDocument { EditorDocument() }
        }

        enum Kind: String {
            case text, binary(Int)
            case unknown = "u"
        }
        protocol Loader { func load() }
        extension EditorDocument { func reload() {} }
        struct Point { var x: Double }
        typealias Handler = () -> Void
        """
        XCTAssertEqual(decls(source, .swift), [
            "EditorDocument@4:class", "limit@5:property", "isDirty@6:property", "name@7:property",
            "EditorDocument@8:constructor", "EditorDocument@9:constructor", "save@10:method", "make@14:method",
            "Kind@17:enum", "text@18:enum case", "binary@18:enum case", "unknown@19:enum case",
            "Loader@21:protocol", "load@21:method", "reload@22:method", "Point@23:struct", "x@23:property",
            "Handler@24:type",
        ])
        XCTAssertEqual(find(source, .swift, "reload")?.container, "EditorDocument")
    }

    func testPythonDeclarations() {
        let source = """
        import os
        MAX_RETRIES = 3
        logger = get_logger()

        class UserService(Base):
            \"\"\"def fake(): 문자열 안\"\"\"
            timeout: int = 5

            def __init__(self, repo):
                self.repo = repo
                local = 1

            @property
            def name(self):
                def inner():
                    pass
                return "x"

        async def main():
            config = {
                "key": 1,
            }
        """
        XCTAssertEqual(decls(source, .python), [
            "MAX_RETRIES@2:constant", "logger@3:variable", "UserService@5:class", "timeout@7:property",
            "__init__@9:method", "name@14:method", "main@19:function",
        ])
        XCTAssertEqual(find(source, .python, "name")?.container, "UserService")
    }

    func testGoDeclarations() {
        let source = """
        package user

        const MaxSize = 10

        var (
            ErrNotFound = errors.New("not found")
            defaultName string
        )

        type User struct {
            ID   int64
            Name, Email string `json:"name"`
            sync.Mutex
        }

        type Repository interface {
            Find(id int64) (*User, error)
        }

        type ID = int64

        func NewService(repo Repository) *Service { return nil }

        func (s *Service) FindByID(id int64) (*User, error) {
            var local = 1
            return nil, nil
        }

        func (l *List[T]) Push(v T) {}
        """
        XCTAssertEqual(decls(source, .go), [
            "MaxSize@3:constant", "ErrNotFound@6:variable", "defaultName@7:variable", "User@10:struct",
            "ID@11:field", "Name@12:field", "Email@12:field", "Repository@16:interface", "Find@17:method",
            "ID@20:type", "NewService@22:function", "FindByID@24:method", "Push@29:method",
        ])
        XCTAssertEqual(find(source, .go, "FindByID")?.container, "Service")
        XCTAssertEqual(find(source, .go, "Push")?.container, "List")
    }

    func testRustDeclarations() {
        let source = """
        use std::fmt;

        pub const MAX: usize = 10;
        static mut COUNTER: u32 = 0;

        #[derive(Debug, Clone)]
        pub struct User {
            pub id: u64,
            name: String,
        }

        pub enum Shape { Circle(f64), Square { side: f64 }, Empty }

        pub trait Store { fn get(&self, id: u64) -> Option<User>; }

        impl fmt::Display for User {
            fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { let x = 'a'; Ok(()) }
        }

        impl<'a> User {
            pub(crate) async fn load(id: u64) -> Self { todo!() }
        }

        pub type Id = u64;
        mod tests { fn helper() {} }
        macro_rules! square { ($x:expr) => { $x * $x }; }
        """
        let found = decls(source, .rust)
        XCTAssertEqual(found, [
            "MAX@3:constant", "COUNTER@4:constant", "User@7:struct", "id@8:field", "name@9:field",
            "Shape@12:enum", "Circle@12:enum case", "Square@12:enum case", "Empty@12:enum case",
            "Store@14:trait", "get@14:method", "fmt@17:method", "load@21:method", "Id@24:type",
            "tests@25:module", "helper@25:method", "square@26:function",
        ])
        XCTAssertEqual(find(source, .rust, "fmt")?.container, "User")
        XCTAssertEqual(find(source, .rust, "load")?.container, "User")
    }

    func testBracesInsideParametersDoNotStartBody() {
        // 생성자 기본값 람다의 { } 가 클래스 몸통을 가져가면 안 된다
        let kotlin = """
        class C(val provider: () -> String = { "x" }, val other: Int = listOf(1).map { it }.size) {
            val p = 1
            fun work() {}
        }
        fun f(cb: () -> Unit = {}, n: Int = 0) {
            val local = 1
        }
        fun g() {}
        """
        XCTAssertEqual(decls(kotlin, .kotlin), [
            "C@1:class", "provider@1:property", "other@1:property", "p@2:property", "work@3:method", "f@5:function", "g@8:function",
        ])
        XCTAssertEqual(find(kotlin, .kotlin, "work")?.container, "C")
        XCTAssertNil(find(kotlin, .kotlin, "g")?.container)
        let java = """
        @SuppressWarnings({"unchecked", "rawtypes"})
        public class A {
            @Foo({"a", "b"}) public void x() {}
            @Bar(values = {1, 2})
            private int count;
            void y() {}
        }
        """
        XCTAssertEqual(decls(java, .java), ["A@2:class", "x@3:method", "count@5:field", "y@6:method"])
        XCTAssertEqual(find(java, .java, "y")?.container, "A")
    }

    func testLocalScopes() {
        let source = """
        class C {
            val value = 1
            fun one() {
                val value = 2
                println(value)
                if (true) {
                    val inner = 3
                }
                println(inner)
            }
            fun two() {
                println(value)
            }
        }
        """
        let all = SymbolScanner.scan(source, language: .kotlin, includeLocals: true)
        let local = all.first { $0.name == "value" && $0.scope != nil }
        XCTAssertEqual(local?.line, 3)
        XCTAssertEqual(local?.scope, 2...9) // one() 몸통
        XCTAssertNil(all.first { $0.name == "value" && $0.line == 1 }?.scope) // 속성은 지역 아님
        // one() 안의 참조는 지역, two() 안의 참조는 지역이 아니다(속성으로 간다)
        XCTAssertEqual(LocalScope.nearest(all, name: "value", line: 4)?.line, 3)
        XCTAssertNil(LocalScope.nearest(all, name: "value", line: 11))
        // 선언 앞(같은 블록이라도)은 아님, if 블록 밖에선 inner 가 보이지 않는다
        XCTAssertNil(LocalScope.nearest(all, name: "value", line: 2))
        XCTAssertNil(LocalScope.nearest(all, name: "inner", line: 8))
        XCTAssertEqual(LocalScope.nearest(all, name: "inner", line: 6)?.line, 6)
        // 닫히지 않은 블록(편집 중)은 파일 끝까지
        let open = SymbolScanner.scan("fun a() {\n    val x = 1\n    x\n", language: .kotlin, includeLocals: true)
        XCTAssertEqual(LocalScope.nearest(open, name: "x", line: 2)?.line, 1)
        // Python: 함수 들여쓰기 범위
        let python = "class A:\n    def one(self):\n        value = 1\n        print(value)\n    def two(self):\n        print(value)\n"
        let p = SymbolScanner.scan(python, language: .python, includeLocals: true)
        XCTAssertEqual(LocalScope.nearest(p, name: "value", line: 3)?.line, 2)
        XCTAssertNil(LocalScope.nearest(p, name: "value", line: 5))
    }

    func testCommentsAndStringsAreSkipped() {
        let kotlin = """
        /* class Hidden { fun nope() } /* nested */ still comment */
        val text = \"\"\"
            fun alsoHidden() {}
        \"\"\"
        // class Gone
        fun visible() {}
        """
        XCTAssertEqual(decls(kotlin, .kotlin), ["text@2:property", "visible@6:function"])
    }

    func testLanguagesForIndexing() {
        XCTAssertEqual(SymbolLanguages.language(path: "/a/B.kt"), .kotlin)
        XCTAssertEqual(SymbolLanguages.language(path: "/a/B.java"), .java)
        XCTAssertEqual(SymbolLanguages.language(path: "/a/b.tsx"), .typescript)
        XCTAssertNil(SymbolLanguages.language(path: "/a/build.gradle"))
        XCTAssertNil(SymbolLanguages.language(path: "/a/app.min.js"))
        XCTAssertNil(SymbolLanguages.language(path: "/a/README.md"))
        XCTAssertNil(SymbolLanguages.language(path: "/a/data.json"))
    }
}

final class FuzzyMatcherTests: XCTestCase {
    private func matches(_ pattern: String, _ name: String) -> Bool { FuzzyMatcher(pattern).match(name) != nil }

    func testCamelHumps() {
        XCTAssertTrue(matches("UsrSvc", "UserService"))
        XCTAssertTrue(matches("US", "UserService"))
        XCTAssertTrue(matches("usvc", "UserService"))
        XCTAssertTrue(matches("userser", "UserService"))
        XCTAssertTrue(matches("findby", "findById"))
        XCTAssertTrue(matches("fBI", "findById"))
        XCTAssertTrue(matches("HTTPSer", "HTTPServer"))
        XCTAssertTrue(matches("max_s", "MAX_SIZE"))
        XCTAssertFalse(matches("SU", "UserService"))
        XCTAssertTrue(matches("Svc", "UserService"))
        XCTAssertTrue(matches("serv", "UserService"))
        XCTAssertFalse(matches("xyz", "UserService"))
        // 대문자 패턴은 낱말 머리에만
        XCTAssertFalse(matches("uSer", "Userver"))
    }

    func testRanking() {
        let names = ["UserServiceImpl", "UserService", "AbstractUserService", "UserSessionValidator", "user_service_test"]
        let matcher = FuzzyMatcher("UserService")
        let ranked = names.compactMap { n in matcher.match(n).map { (n, $0.score) } }.sorted { $0.1 > $1.1 }.map(\.0)
        XCTAssertEqual(ranked.first, "UserService")
        XCTAssertEqual(ranked[1], "UserServiceImpl")
        let short = FuzzyMatcher("usvc")
        XCTAssertGreaterThan(short.match("UserService")!.score, short.match("UserSessionValidatorCache")?.score ?? Int.min)
    }

    func testTablePrefersTypesAndRespectsLimit() {
        var table = SymbolTable()
        table.set("a/UserService.kt", stamp: .init(modified: 1, size: 1), declarations: [
            SymbolDeclaration("UserService", line: 2, kind: .class),
            SymbolDeclaration("userService", line: 9, kind: .property, container: "Config"),
            SymbolDeclaration("UserService", line: 4, kind: .constructor, container: "UserService"),
        ])
        table.set("b/Other.kt", stamp: .init(modified: 1, size: 1), declarations: [
            SymbolDeclaration("UserSessionValidator", line: 0, kind: .class),
        ])
        let results = table.search("UsrS")
        XCTAssertEqual(results.map(\.hit.name), ["UserService", "userService", "UserSessionValidator"])
        XCTAssertFalse(results.contains { $0.hit.kind == .constructor })
        XCTAssertEqual(table.lookup("UserService").count, 2)
        // 이름 중간에서 맞은 것은 앞에서 맞은 것보다 뒤
        var events = SymbolTable()
        events.set("E.kt", stamp: .init(modified: 1, size: 1), declarations: [
            SymbolDeclaration("WeeklyCarViewEventService", line: 0, kind: .class),
            SymbolDeclaration("eventService", line: 1, kind: .property),
            SymbolDeclaration("EventService", line: 2, kind: .class),
        ])
        XCTAssertEqual(events.search("EvtSvc").map(\.hit.name), ["EventService", "eventService", "WeeklyCarViewEventService"])
        XCTAssertEqual(table.lookup("userService").first?.container, "Config")
        // 다시 넣으면 바뀌고, 지우면 빠진다
        table.set("a/UserService.kt", stamp: .init(modified: 2, size: 1), declarations: [SymbolDeclaration("Renamed", line: 0, kind: .class)])
        XCTAssertTrue(table.lookup("UserService").isEmpty)
        XCTAssertEqual(table.lookup("Renamed").first?.path, "a/UserService.kt")
        table.remove("b/Other.kt")
        XCTAssertTrue(table.lookup("UserSessionValidator").isEmpty)
        XCTAssertEqual(table.fileCount, 1)
        XCTAssertEqual(table.symbolCount, 1)
    }
}

final class IdentifierTests: XCTestCase {
    private func word(_ text: String, _ at: Int, _ language: SyntaxLanguage? = .kotlin) -> String? {
        let ns = text as NSString
        return Identifier.range(in: ns, at: at, language: language).map { ns.substring(with: $0) }
    }

    func testWordUnderCaret() {
        let text = "val user = repo.findById(id)"
        XCTAssertEqual(word(text, 4), "user")
        XCTAssertEqual(word(text, 6), "user")
        XCTAssertEqual(word(text, 8), "user") // 바로 뒤
        XCTAssertEqual(word(text, 17), "findById")
        XCTAssertEqual(word(text, 16), "findById")
        XCTAssertNil(word(text, 9)) // "= " 사이
        XCTAssertNil(word("x = 123", 5))
        XCTAssertEqual(word("\"$name\"", 3), "name") // Kotlin 문자열 틀의 $ 는 빼고
        XCTAssertEqual(word("const $el = 1", 7, .javascript), "$el")
        XCTAssertEqual(word("val 이름 = 1", 5), "이름")
        XCTAssertNil(word("", 0))
    }

    func testQualified() {
        let text = "repo.find(x); this.save(); find(); a .. b" as NSString
        XCTAssertTrue(Identifier.isQualified(text, range: NSRange(location: 5, length: 4)))
        XCTAssertFalse(Identifier.isQualified(text, range: NSRange(location: 19, length: 4)))
        XCTAssertFalse(Identifier.isQualified(text, range: NSRange(location: 27, length: 4)))
        XCTAssertFalse(Identifier.isQualified(text, range: NSRange(location: 40, length: 1)))
    }

    func testReceiverAndType() {
        let text = "val u = userService.findById(1); repo?.save(x); a.b().c; UserService.MAX" as NSString
        XCTAssertEqual(Identifier.receiver(text, range: text.range(of: "findById")), "userService")
        XCTAssertEqual(Identifier.receiver(text, range: text.range(of: "save")), "repo")
        XCTAssertNil(Identifier.receiver(text, range: text.range(of: "c;")))
        XCTAssertEqual(Identifier.receiver(text, range: text.range(of: "MAX")), "UserService")
        let kotlin = "class C(private val userService: UserService) {\n val repo = UserRepositoryImpl(db)\n}"
        XCTAssertEqual(Identifier.receiverType("userService", in: kotlin, language: .kotlin), "UserService")
        XCTAssertEqual(Identifier.receiverType("repo", in: kotlin, language: .kotlin), "UserRepositoryImpl")
        XCTAssertEqual(Identifier.receiverType("UserService", in: kotlin, language: .kotlin), "UserService")
        XCTAssertNil(Identifier.receiverType("unknown", in: kotlin, language: .kotlin))
        let java = "private final Map<String, User> cache;\nprivate final UserService userService;\nvar invoice = new Invoice(1);"
        XCTAssertEqual(Identifier.receiverType("userService", in: java, language: .java), "UserService")
        XCTAssertEqual(Identifier.receiverType("cache", in: java, language: .java), "Map")
        XCTAssertEqual(Identifier.receiverType("invoice", in: java, language: .java), "Invoice")
    }

    func testFirstWholeWord() {
        XCTAssertEqual(Identifier.firstWholeWord("id", in: "fun findById(id: Long)"), 13)
        XCTAssertNil(Identifier.firstWholeWord("Id", in: "findById"))
        XCTAssertEqual(Identifier.firstWholeWord("이름", in: "val 이름 = 1"), 4)
    }
}

final class UsageAndRankingTests: XCTestCase {
    func testUsagesSkipCommentsAndStrings() {
        let source = """
        class A {
            fun find() = 1 // find in comment
            val s = "find in string"
            fun other() = find() + finder() + this.find()
        }
        """
        var copy = source
        let usages = copy.withUTF8 { UsageFinder.find("find", in: $0, language: .kotlin) }
        XCTAssertEqual(usages.map { "\($0.line + 1):\($0.column)" }, ["2:8", "4:18", "4:43"])
        XCTAssertEqual(usages[1].text, "    fun other() = find() + finder() + this.find()")
        // 한글이 앞에 있어도 열은 UTF-16 단위
        var korean = "val 이름 = find()"
        let k = korean.withUTF8 { UsageFinder.find("find", in: $0, language: .kotlin) }
        XCTAssertEqual(k.first?.column, 9)
    }

    func testImportHints() {
        let kotlin = """
        package com.example.web
        import com.example.user.UserService
        import com.example.common.*
        import com.example.util.formatDate as fmt
        """
        let hints = ImportHints.parse(kotlin, language: .kotlin, directory: "/p/src")
        XCTAssertEqual(hints, [
            ImportHint(name: "UserService", path: "com/example/user/UserService", isFile: false),
            ImportHint(name: nil, path: "com/example/common", isFile: false),
            ImportHint(name: "fmt", path: "com/example/util/formatDate", isFile: false),
        ])
        let ts = "import { UserService, Role as R } from './services/user';\nimport App from '../App'"
        XCTAssertEqual(ImportHints.parse(ts, language: .typescript, directory: "/p/src/web"), [
            ImportHint(name: "UserService", path: "/p/src/web/services/user", isFile: true),
            ImportHint(name: "R", path: "/p/src/web/services/user", isFile: true),
            ImportHint(name: "App", path: "/p/src/App", isFile: true),
        ])
    }

    func testRankingOrderAndDecisive() {
        let file = "/p/app/src/main/kotlin/com/example/web/UserController.kt"
        let imports = [ImportHint(name: "UserService", path: "com/example/user/UserService", isFile: false)]
        let candidates = [
            NavigationCandidate(path: "/p/legacy/src/main/kotlin/com/old/UserService.kt", line: 3, kind: .class, name: "UserService"),
            NavigationCandidate(path: "/p/app/src/main/kotlin/com/example/user/UserService.kt", line: 5, kind: .class, name: "UserService"),
            NavigationCandidate(path: "/p/app/src/test/kotlin/com/example/fake/UserService.kt", line: 1, kind: .class, name: "UserService"),
        ]
        let ranked = CandidateRanker.rank(candidates, from: file, name: "UserService", imports: imports)
        XCTAssertEqual(ranked.first?.candidate.path, "/p/app/src/main/kotlin/com/example/user/UserService.kt")
        XCTAssertEqual(ranked.first?.tier, .imported)
        XCTAssertEqual(CandidateRanker.decisive(ranked, qualified: false)?.line, 5)

        // 같은 파일 하나 + 받는 쪽 없는 참조 → 바로, 받는 쪽 있으면 목록
        let local = [
            NavigationCandidate(path: file, line: 10, kind: .method, name: "save"),
            NavigationCandidate(path: "/p/app/src/main/kotlin/com/example/Repo.kt", line: 2, kind: .method, name: "save"),
        ]
        let rankedLocal = CandidateRanker.rank(local, from: file, name: "save", imports: [])
        XCTAssertEqual(rankedLocal.first?.tier, .sameFile)
        XCTAssertEqual(CandidateRanker.decisive(rankedLocal, qualified: false)?.line, 10)
        XCTAssertNil(CandidateRanker.decisive(rankedLocal, qualified: true))
        // 받는 쪽 타입: 같은 이름 클래스가 둘이어도 import 한 쪽 멤버로 바로
        let members = [
            NavigationCandidate(path: "/p/app/src/main/kotlin/com/example/legacy/UserService.kt", line: 3, kind: .method, name: "findById", container: "UserService"),
            NavigationCandidate(path: "/p/app/src/main/kotlin/com/example/user/UserRepository.kt", line: 3, kind: .method, name: "findById", container: "UserRepository"),
            NavigationCandidate(path: "/p/app/src/main/kotlin/com/example/user/UserService.kt", line: 13, kind: .method, name: "findById", container: "UserService"),
        ]
        let byReceiver = CandidateRanker.rank(members, from: file, name: "findById", imports: imports, receiverType: "UserService")
        XCTAssertEqual(byReceiver.first?.candidate.line, 13)
        XCTAssertEqual(CandidateRanker.decisive(byReceiver, qualified: true, receiverType: "UserService")?.line, 13)
        // 타입을 몰라도 감싼 클래스를 import 한 멤버가 하나면 바로, import 가 없으면 목록으로 고른다
        XCTAssertEqual(CandidateRanker.decisive(CandidateRanker.rank(members, from: file, name: "findById", imports: imports),
                                                qualified: true)?.line, 13)
        XCTAssertNil(CandidateRanker.decisive(CandidateRanker.rank(members, from: file, name: "findById", imports: []), qualified: true))
        // 같은 폴더가 먼 모듈보다 앞
        let near = [
            NavigationCandidate(path: "/p/other/x/Thing.kt", line: 0, kind: .class, name: "Thing"),
            NavigationCandidate(path: "/p/app/src/main/kotlin/com/example/web/Thing.kt", line: 0, kind: .class, name: "Thing"),
        ]
        XCTAssertEqual(CandidateRanker.rank(near, from: file, name: "Thing", imports: []).first?.tier, .sameDirectory)
    }
}

final class ReceiverResolutionTests: XCTestCase {
    private let user = NavigationCandidate(path: "/p/src/main/kotlin/com/example/user/UserService.kt", line: 13, kind: .method,
                                           name: "findById", container: "UserService")
    private let legacy = NavigationCandidate(path: "/p/src/main/kotlin/com/example/legacy/UserService.kt", line: 3, kind: .method,
                                             name: "findById", container: "UserService")
    private let repo = NavigationCandidate(path: "/p/src/main/kotlin/com/example/user/UserRepository.kt", line: 3, kind: .method,
                                           name: "findById", container: "UserRepository")
    private var packages: [String: String] {
        [user.path: "com.example.user", legacy.path: "com.example.legacy", repo.path: "com.example.user"]
    }

    /// obj.name 의 caret 범위에서 받는 쪽 타입까지(내비게이터와 같은 순서)
    private func receiverType(_ text: String, call: String, _ language: SyntaxLanguage) -> String? {
        let ns = text as NSString
        let range = ns.range(of: call, options: .backwards)
        guard range.location != NSNotFound else { XCTFail("\(call) 없음"); return nil }
        let name = NSRange(location: range.location + (call as NSString).range(of: ".", options: .backwards).location + 1,
                           length: (call as NSString).length - (call as NSString).range(of: ".", options: .backwards).location - 1)
        XCTAssertTrue(Identifier.isQualified(ns, range: name))
        return Identifier.receiver(ns, range: name).flatMap { Identifier.receiverType($0, in: text, language: language) }
    }

    func testPackageParse() {
        XCTAssertEqual(PackageInfo.parse("// c\n@file:JvmName(\"X\")\npackage com.example.user\n\nimport a.B"), "com.example.user")
        XCTAssertEqual(PackageInfo.parse("/* x */\npackage com.example.billing;\npublic class A {}"), "com.example.billing")
        XCTAssertNil(PackageInfo.parse("import a.B\nclass C"))
    }

    func testSameNamedClassesResolvedByImport() {
        let file = "/p/src/main/kotlin/com/example/web/UserController.kt"
        let text = """
        package com.example.web

        import com.example.user.UserService

        class UserController(private val userService: UserService) {
            fun get(id: Long) = userService.findById(id)
        }
        """
        let type = receiverType(text, call: "userService.findById", .kotlin)
        XCTAssertEqual(type, "UserService") // Kotlin 생성자 속성에서
        let imports = ImportHints.parse(text, language: .kotlin, directory: "/p/src/main/kotlin/com/example/web")
        let allowed = CandidateRanker.allowedPackages(for: "UserService", imports: imports, currentPackage: PackageInfo.parse(text))
        XCTAssertEqual(allowed, ["com.example.user"])
        // 이름 순으로는 legacy 가 앞이지만 import 한 클래스의 멤버만 남는다
        let restricted = CandidateRanker.restrict([legacy, repo, user], receiverType: "UserService", allowed: allowed, packages: packages)
        XCTAssertEqual(restricted, [user])
        let ranked = CandidateRanker.rank(restricted, from: file, name: "findById", imports: imports, receiverType: "UserService")
        XCTAssertEqual(CandidateRanker.decisive(ranked, qualified: true, receiverType: "UserService"), user)
        // 목록으로 돌아가도(제한 전 전체) import 한 쪽이 같은 이름 다른 클래스보다 앞
        let all = CandidateRanker.rank([legacy, repo, user], from: file, name: "findById", imports: imports, receiverType: "UserService")
        XCTAssertEqual(all.first?.candidate, user)
        XCTAssertLessThan(all.firstIndex { $0.candidate == user }!, all.firstIndex { $0.candidate == legacy }!)
        // 받는 쪽 타입을 모를 때((x as UserService).findById)도 import 한 클래스의 멤버가 앞, 하나뿐이면 바로
        let blind = CandidateRanker.rank([legacy, repo, user], from: file, name: "findById", imports: imports)
        XCTAssertEqual(blind.first?.candidate, user)
        XCTAssertEqual(blind.first?.tier, .imported)
        XCTAssertLessThan(blind.firstIndex { $0.candidate == user }!, blind.firstIndex { $0.candidate == legacy }!)
    }

    func testSamePackageWithoutImport() {
        // import 없이 같은 패키지의 UserService
        let allowed = CandidateRanker.allowedPackages(for: "UserService", imports: [], currentPackage: "com.example.legacy")
        XCTAssertEqual(CandidateRanker.restrict([user, legacy], receiverType: "UserService", allowed: allowed, packages: packages), [legacy])
        // 별표 import 도 후보 패키지
        let star = [ImportHint(name: nil, path: "com/example/user", isFile: false)]
        let both = CandidateRanker.allowedPackages(for: "UserService", imports: star, currentPackage: "com.example.web")
        XCTAssertEqual(both, ["com.example.user", "com.example.web"])
        XCTAssertEqual(CandidateRanker.restrict([user, legacy], receiverType: "UserService", allowed: both, packages: packages), [user])
        // 맞는 것이 없으면 빈 목록(부르는 쪽이 이름 전체 후보로 돌아간다)
        let none = CandidateRanker.allowedPackages(for: "UserService", imports: [], currentPackage: "com.other")
        XCTAssertTrue(CandidateRanker.restrict([user, legacy], receiverType: "UserService", allowed: none, packages: packages).isEmpty)
        // 패키지를 모르면(TS 등) 클래스 이름으로만
        XCTAssertEqual(CandidateRanker.restrict([user, legacy, repo], receiverType: "UserService", allowed: [], packages: [:]), [user, legacy])
    }

    func testJavaFieldAndThisReceiver() {
        let text = """
        package com.example.billing;

        import com.example.user.UserService;

        public class InvoiceService {
            private final UserService userService;
            public Invoice issue(long id) {
                var a = userService.findById(id);
                var b = this.userService.findById(id);
                return null;
            }
        }
        """
        XCTAssertEqual(receiverType(text, call: "a = userService.findById", .java), "UserService") // Java 필드에서
        XCTAssertEqual(receiverType(text, call: "this.userService.findById", .java), "UserService")
        let imports = ImportHints.parse(text, language: .java, directory: "/p/src/main/java/com/example/billing")
        let allowed = CandidateRanker.allowedPackages(for: "UserService", imports: imports, currentPackage: PackageInfo.parse(text))
        XCTAssertEqual(CandidateRanker.restrict([legacy, repo, user], receiverType: "UserService", allowed: allowed, packages: packages), [user])
    }

    func testCompanionAndTopLevelInClassFile() {
        let companion = NavigationCandidate(path: user.path, line: 10, kind: .constant, name: "MAX_PAGE", container: "UserService")
        let topLevel = NavigationCandidate(path: user.path, line: 30, kind: .function, name: "helper", container: nil)
        let elsewhere = NavigationCandidate(path: repo.path, line: 9, kind: .function, name: "helper", container: nil)
        XCTAssertEqual(CandidateRanker.restrict([companion, topLevel, elsewhere], receiverType: "UserService",
                                                allowed: ["com.example.user"], packages: packages), [companion, topLevel])
    }
}

final class NavigationHistoryTests: XCTestCase {
    func testBackAndForward() {
        var history = NavigationHistory<String>()
        XCTAssertNil(history.goBack(from: "a"))
        history.record("a:1")       // a:1 → b:5 로 건너뜀
        history.record("b:5")       // b:5 → c:9
        XCTAssertEqual(history.goBack(from: "c:9"), "b:5")
        XCTAssertEqual(history.goBack(from: "b:5"), "a:1")
        XCTAssertNil(history.goBack(from: "a:1"))
        XCTAssertEqual(history.goForward(from: "a:1"), "b:5")
        XCTAssertEqual(history.goForward(from: "b:5"), "c:9")
        XCTAssertNil(history.goForward(from: "c:9"))
        // 새로 건너뛰면 앞으로 기록은 사라진다
        _ = history.goBack(from: "c:9")
        history.record("b:5")
        XCTAssertFalse(history.canGoForward)
        // 같은 자리 기록은 겹쳐 쌓지 않는다
        var h2 = NavigationHistory<String>(limit: 3)
        h2.record("x"); h2.record("x"); h2.record("y"); h2.record("z"); h2.record("w")
        XCTAssertEqual(h2.back, ["y", "z", "w"])
    }
}
