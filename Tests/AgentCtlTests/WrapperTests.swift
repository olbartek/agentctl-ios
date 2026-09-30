#if os(macOS)
  import Foundation
  import Testing

  /// What this guards: `Templates/appctl`, the wrapper every host copies. It is run as it ships, by `/bin/sh`, over
  /// a fake `swift` on `PATH` whose builds fail or pass as each test scripts them, so the recovery from a stale
  /// SwiftPM cache is proved without a real build: clean once and rebuild on those two signatures, exit 3 on anything
  /// else or on a second failure.
  struct WrapperTests {
    struct Run {
      var status: Int32
      var stdout: String
      var stderr: String
      /// The fake `swift`'s invocations, one per line.
      var swiftCalls: [String]
      /// Whatever the wrapper left in its temporary directory.
      var leftovers: [String]
    }

    static let missingInputs =
      "error: couldn't build /r/.build/debug/AgentCtlCLI.build/AppTest.swift.o because of missing inputs: "
      + "/r/.build/checkouts/agentctl-ios/Sources/AgentCtlCLI/AppTest.swift"
    static let outputFileMap =
      "error: unable to load output file map '/r/.build/debug/AgentCtlCLI.build/output-file-map.json': "
      + "No such file or directory"

    /// Runs the template with `builds[i]` as the output of the fake's i-th `swift build` (`nil`: it succeeds).
    func run(builds: [String?]) throws -> Run {
      let fileManager = FileManager.default
      let root = fileManager.temporaryDirectory.appending(path: "appctl-wrapper-\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: root) }
      let bin = root.appending(path: "bin")
      let tmp = root.appending(path: "tmp")
      let product = root.appending(path: "Packages/AppCtl/.build/debug")
      for directory in [bin, tmp, product] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      let template = PackageRoot.url.appending(path: "Templates/appctl")
      try fileManager.copyItem(at: template, to: root.appending(path: "appctl"))

      // The i-th build prints `build-<i>.out` and fails when that file exists, and succeeds otherwise.
      let fake = """
        #!/bin/sh
        echo "$*" >> "\(root.path)/swift-calls"
        [ "$1" = build ] || exit 0
        n=$(cat "\(root.path)/builds" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "\(root.path)/builds"
        [ -f "\(root.path)/build-$n.out" ] || exit 0
        cat "\(root.path)/build-$n.out"
        exit 1

        """
      for (index, output) in builds.enumerated() {
        guard let output else { continue }
        try (output + "\n").write(to: root.appending(path: "build-\(index + 1).out"), atomically: true, encoding: .utf8)
      }
      try write(fake, to: bin.appending(path: "swift"))
      try write("#!/bin/sh\necho \"ran $* in $APPCTL_ROOT\"\n", to: product.appending(path: "appctl"))

      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = [root.appending(path: "appctl").path, "run", "open 2"]
      process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "TMPDIR": tmp.path]
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      let out = stdout.fileHandleForReading.readDataToEndOfFile()
      let err = stderr.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let calls = (try? String(contentsOf: root.appending(path: "swift-calls"), encoding: .utf8)) ?? ""
      return Run(
        status: process.terminationStatus,
        stdout: String(decoding: out, as: UTF8.self),
        stderr: String(decoding: err, as: UTF8.self),
        swiftCalls: calls.split(separator: "\n").map { String($0).replacingOccurrences(of: root.path, with: "<root>") },
        leftovers: try fileManager.contentsOfDirectory(atPath: tmp.path)
      )
    }

    func write(_ text: String, to url: URL) throws {
      try text.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static let build = "build --package-path <root>/Packages/AppCtl --product appctl --configuration debug -q"
    static let clean = "package clean --package-path <root>/Packages/AppCtl"

    @Test func aGoodBuildExecsTheCLI() throws {
      let run = try run(builds: [])
      #expect(run.status == 0)
      #expect(run.stdout.hasPrefix("ran run open 2 in "), "\(run.stdout)")
      #expect(run.swiftCalls == [Self.build])
      #expect(run.leftovers.isEmpty)
    }

    @Test(arguments: [missingInputs, outputFileMap])
    func aStaleCacheIsCleanedAndBuiltOnceMore(signature: String) throws {
      let run = try run(builds: [signature])
      #expect(run.status == 0, "\(run.stderr)")
      #expect(run.stdout.hasPrefix("ran run open 2 in "), "\(run.stdout)")
      #expect(run.swiftCalls == [Self.build, Self.clean, Self.build])
      #expect(run.stderr.contains(signature), "the first build's log is still shown")
      #expect(run.stderr.contains("appctl: the build cache is stale; cleaning Packages/AppCtl and building again\n"))
      #expect(run.leftovers.isEmpty)
    }

    @Test func aStaleCacheTwiceExits3() throws {
      let run = try run(builds: [Self.outputFileMap, Self.outputFileMap])
      #expect(run.status == 3)
      #expect(run.stdout.isEmpty)
      #expect(run.swiftCalls == [Self.build, Self.clean, Self.build])
      #expect(run.leftovers.isEmpty)
    }

    @Test func anyOtherFailureExits3WithoutCleaning() throws {
      let run = try run(builds: ["error: cannot find 'x' in scope"])
      #expect(run.status == 3)
      #expect(run.stdout.isEmpty)
      #expect(run.stderr.contains("error: cannot find 'x' in scope"))
      #expect(run.swiftCalls == [Self.build])
      #expect(run.leftovers.isEmpty)
    }
  }
#endif
