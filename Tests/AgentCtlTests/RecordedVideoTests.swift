#if os(macOS)
  import AVFoundation
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: a recording covers the whole span from start to stop, however still the screen was. The
    /// fixture is `simctl io recordVideo` of a still screen for about three seconds: one frame that lasts 67 ms, in a
    /// file whose header says 3.1 s, so tools that go by the frames showed a 0.07 s video.
    @MainActor
    @Suite struct RecordedVideoTests {
      static let fixture = PackageRoot.url.appending(path: "Tests/AgentCtlTests/Fixtures/simctl-still-screen.mp4")

      /// The frames' count and the end of the last one, as a player that goes by the frames sees them.
      static func frames(_ video: URL) async throws -> (count: Int, end: Double) {
        let asset = AVURLAsset(url: video)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        var end = 0.0
        while let sample = output.copyNextSampleBuffer() {
          guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
          count += 1
          let frameEnd = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
          end = max(end, frameEnd.seconds)
        }
        return (count, end)
      }

      func copyOfFixture() throws -> URL {
        let directory = try CLICommandTests.temporaryDirectory()
        let video = directory.appending(path: "still.mp4")
        try FileManager.default.copyItem(at: Self.fixture, to: video)
        return video
      }

      @Test func aStillScreensLastFrameLastsUntilStop() async throws {
        let video = try copyOfFixture()
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        let header = try await AVURLAsset(url: video).load(.duration).seconds
        let before = try await Self.frames(video)
        #expect(before.count == 1 && before.end < 0.1, "the fixture is simctl's short still frame: \(before)")

        let seconds = try RecordedVideo.holdLastFrame(video)

        #expect(abs(seconds - header) < 0.01, "reported \(seconds) s, recorded \(header) s")
        let after = try await Self.frames(video)
        #expect(after.count == 1)
        #expect(abs(after.end - header) < 0.01, "the frames end at \(after.end) s")
        // Still a playable file: one frame decodes.
        let asset = AVURLAsset(url: video)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(
          track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(decoded)
        reader.startReading()
        #expect(decoded.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer) != nil)
        #expect(
          try FileManager.default.contentsOfDirectory(atPath: video.deletingLastPathComponent().path) == ["still.mp4"],
          "no temporary file is left behind"
        )
      }

      @Test func holdingTwiceChangesNothing() throws {
        let video = try copyOfFixture()
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        let first = try RecordedVideo.holdLastFrame(video)
        #expect(abs(try RecordedVideo.holdLastFrame(video) - first) < 0.01)
      }

      @Test func aFileThatIsNoVideoIsAnError() throws {
        let directory = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "broken.mp4")
        try Data("not a video".utf8).write(to: video)
        #expect(throws: (any Error).self) { try RecordedVideo.holdLastFrame(video) }
      }
    }
  }
#endif
