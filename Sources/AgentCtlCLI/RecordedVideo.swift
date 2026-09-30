#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AVFoundation
  import Foundation

  /// A video `simctl io recordVideo` has finished, made to cover the whole recording.
  ///
  /// `simctl` writes a frame only when the screen changes, and none when it stops: the frames end at the last change,
  /// though the file's header spans the recording from start to stop. Players that go by the header show the whole
  /// span; players and tools that go by the frames (ffmpeg's, a browser's) cut it short, and a still screen records
  /// as a single frame lasting a few milliseconds. agentctl-android holds frames the same way.
  enum RecordedVideo {
    struct Failure: Error, CustomStringConvertible {
      var description: String
    }

    /// Rewrites `video` so that its last frame lasts until the end of the recording, as the header records it, and
    /// returns the video's duration in seconds. Lossless: the frames are copied, not re-encoded.
    static func holdLastFrame(_ video: URL) throws -> Double {
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var result: Result<Double, any Error> = .failure(Failure(description: "not run"))
      Task {
        do { result = .success(try await hold(video)) } catch { result = .failure(error) }
        semaphore.signal()
      }
      semaphore.wait()
      return try result.get()
    }

    private static func hold(_ video: URL) async throws -> Double {
      let asset = AVURLAsset(url: video)
      let end = try await asset.load(.duration)
      guard let track = try await asset.loadTracks(withMediaType: .video).first,
        let format = try await track.load(.formatDescriptions).first
      else { throw Failure(description: "\(video.lastPathComponent) has no video track") }

      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      reader.add(output)
      let held = video.deletingLastPathComponent()
        .appending(path: ".\(video.deletingPathExtension().lastPathComponent)-held.\(video.pathExtension)")
      try? FileManager.default.removeItem(at: held)
      let writer = try AVAssetWriter(outputURL: held, fileType: video.pathExtension.lowercased() == "mov" ? .mov : .mp4)
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
      input.transform = try await track.load(.preferredTransform)
      input.expectsMediaDataInRealTime = false
      writer.add(input)
      guard reader.startReading(), writer.startWriting() else {
        throw Failure(description: "cannot rewrite \(video.lastPathComponent): \(String(describing: reader.error ?? writer.error))")
      }
      writer.startSession(atSourceTime: .zero)

      func append(_ sample: CMSampleBuffer) throws {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
        guard input.append(sample) else {
          throw Failure(description: "cannot rewrite \(video.lastPathComponent): \(String(describing: writer.error))")
        }
      }
      // Each frame is written once the next is read, so the last can be given the rest of the recording.
      var previous: CMSampleBuffer?
      while let sample = output.copyNextSampleBuffer() {
        // The reader also hands out empty buffers that only mark times; the header's span is kept by the session.
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        if let previous { try append(previous) }
        previous = sample
      }
      guard let last = previous else { throw Failure(description: "\(video.lastPathComponent) has no frames") }
      let start = CMSampleBufferGetPresentationTimeStamp(last)
      if end > start {
        var timing = CMSampleTimingInfo(
          duration: end - start, presentationTimeStamp: start, decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(last)
        )
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
          allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy
        )
        try append(copy ?? last)
      } else {
        try append(last)
      }
      input.markAsFinished()
      writer.endSession(atSourceTime: max(end, start))
      await writer.finishWriting()
      guard writer.status == .completed else {
        try? FileManager.default.removeItem(at: held)
        throw Failure(description: "cannot rewrite \(video.lastPathComponent): \(String(describing: writer.error))")
      }
      _ = try FileManager.default.replaceItemAt(video, withItemAt: held)
      return try await AVURLAsset(url: video).load(.duration).seconds
    }
  }
#endif
