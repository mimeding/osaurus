import Foundation
import XCTest
@testable import OsaurusCLICore

func temporaryPaths(file: StaticString = #filePath, line: UInt = #line) throws -> CoordinatorPaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-coord-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return CoordinatorPaths(root: root)
}

func posixMode(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber, file: file, line: line).intValue & 0o777
}

final class RecordingCoordinatorProcessRunner: CoordinatorProcessRunning {
    struct Stub {
        let matches: (CoordinatorProcessInvocation) -> Bool
        let result: Result<CoordinatorProcessResult, Error>
    }

    private(set) var invocations: [CoordinatorProcessInvocation] = []
    private var stubs: [Stub]

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func run(_ invocation: CoordinatorProcessInvocation) throws -> CoordinatorProcessResult {
        invocations.append(invocation)
        guard let index = stubs.firstIndex(where: { $0.matches(invocation) }) else {
            return CoordinatorProcessResult(
                invocation: invocation,
                exitCode: 127,
                stderr: "missing stub for \(invocation.command.joined(separator: " "))"
            )
        }
        let stub = stubs.remove(at: index)
        let result = try stub.result.get()
        return CoordinatorProcessResult(
            invocation: invocation,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}

func stub(
    command: [String],
    exitCode: Int32 = 0,
    stdout: String = "",
    stderr: String = ""
) -> RecordingCoordinatorProcessRunner.Stub {
    RecordingCoordinatorProcessRunner.Stub(
        matches: { $0.command == command },
        result: .success(
            CoordinatorProcessResult(
                invocation: CoordinatorProcessInvocation(command: command),
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr
            )
        )
    )
}

func throwingStub(command: [String], error: Error = CoordinatorTestError.processLaunch)
    -> RecordingCoordinatorProcessRunner.Stub
{
    RecordingCoordinatorProcessRunner.Stub(
        matches: { $0.command == command },
        result: .failure(error)
    )
}

enum CoordinatorTestError: Error {
    case processLaunch
}

func processResult(
    command: [String],
    exitCode: Int32 = 0,
    stdout: String = "",
    stderr: String = ""
) -> Result<CoordinatorProcessResult, Error> {
    .success(
        CoordinatorProcessResult(
            invocation: CoordinatorProcessInvocation(command: command),
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    )
}

let coordinatorTestDate = Date(timeIntervalSince1970: 1_775_000_000)
let coordinatorTestMainSHA = "2768f29cee9e339e56857b1191c44235d497138e"
