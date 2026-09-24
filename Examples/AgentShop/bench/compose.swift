// Composes the three-mode demo video: the XCUITest recording, the bridge recording and the headless run, side by
// side, each with a title and a running timer that stops when that mode finishes. `bench/video.py` records the
// inputs and calls this; run it by hand as
//
//   swift bench/compose.swift --uitest ui.mp4 --uitest-start 1.2 --uitest-seconds 64.0 \
//     --bridge bridge.mp4 --bridge-start 0.8 --bridge-seconds 12.1 \
//     [--uitest-freeze 63.0] [--bridge-freeze 13.7] \
//     --headless headless.txt --headless-seconds 0.21 --caption "…" --out out.mp4
//
// `--*-start` is where the run begins in its recording, `--*-seconds` how long it ran. Only AVFoundation, CoreText
// and CoreImage: this machine's ffmpeg has no text rendering.

import AVFoundation
import CoreImage
import CoreText
import Foundation

struct Options {
  var uitest = "", bridge = "", headless = "", out = "", caption = ""
  var uitestStart = 0.0, uitestSeconds = 0.0, bridgeStart = 0.0, bridgeSeconds = 0.0, headlessSeconds = 0.0
  var uitestFreeze: Double?, bridgeFreeze: Double?

  init(_ arguments: [String]) {
    var iterator = arguments.dropFirst().makeIterator()
    while let flag = iterator.next() {
      let value = iterator.next() ?? ""
      switch flag {
      case "--uitest": uitest = value
      case "--uitest-start": uitestStart = Double(value) ?? 0
      case "--uitest-seconds": uitestSeconds = Double(value) ?? 0
      case "--uitest-freeze": uitestFreeze = Double(value)
      case "--bridge": bridge = value
      case "--bridge-start": bridgeStart = Double(value) ?? 0
      case "--bridge-seconds": bridgeSeconds = Double(value) ?? 0
      case "--bridge-freeze": bridgeFreeze = Double(value)
      case "--headless": headless = value
      case "--headless-seconds": headlessSeconds = Double(value) ?? 0
      case "--caption": caption = value
      case "--out": out = value
      default: fatalError("unknown option \(flag)")
      }
    }
  }
}

/// Reads a recording's frames in order and hands out the one showing at a given time. Simulator recordings have a
/// variable frame rate (a frame only when the screen changes), so "the frame at t" is the last one at or before t.
final class FrameSource {
  let reader: AVAssetReader
  let output: AVAssetReaderTrackOutput
  let size: CGSize
  private var current: CGImage?
  private var pending: (time: Double, image: CGImage)?
  private let context = CIContext()

  init(path: String) async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      fatalError("no video track in \(path)")
    }
    let natural = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let rect = CGRect(origin: .zero, size: natural).applying(transform)
    size = CGSize(width: abs(rect.width), height: abs(rect.height))
    reader = try AVAssetReader(asset: asset)
    output = AVAssetReaderTrackOutput(
      track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    reader.add(output)
    reader.startReading()
  }

  /// The frame showing at `time` seconds into the recording (the last frame once the recording has ended).
  func frame(at time: Double) -> CGImage? {
    while true {
      if let pending {
        guard pending.time <= time else { return current }
        current = pending.image
        self.pending = nil
      }
      guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
        return current
      }
      let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent)
      if let image {
        pending = (seconds, image)
      }
    }
  }

  /// The last frame at or before `time` that shows the app rather than the home screen. AgentShop's screens are
  /// mostly white and the home screen is a dark wallpaper, so the frame's average brightness tells them apart.
  /// XCTest quits the app as a test ends, before xcodebuild reports it, so the frame at `time` is often the home screen.
  func lastAppFrame(upTo time: Double) -> CGImage? {
    var found: CGImage?
    var next = 0.0
    while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
      let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard seconds <= time else { break }
      guard seconds >= next else { continue }
      next = seconds + 0.2
      let image = CIImage(cvPixelBuffer: buffer)
      if brightness(of: image) > 0.75 {
        found = context.createCGImage(image, from: image.extent)
      }
    }
    return found
  }

  private func brightness(of image: CIImage) -> Double {
    let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
    return (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
  }
}

// MARK: Drawing

let width = 1920
let height = 1200
let fps = 30.0
let headerHeight = 150.0
let footerHeight = 70.0
let margin = 24.0

let background = CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
let panelColor = CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let grey = CGColor(red: 0.62, green: 0.65, blue: 0.70, alpha: 1)
let green = CGColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1)
let amber = CGColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1)

func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat, color: CGColor, bold: Bool = false, mono: Bool = false, width: CGFloat? = nil, center: Bool = false) {
  let name = mono ? (bold ? "Menlo-Bold" : "Menlo-Regular") : (bold ? "HelveticaNeue-Bold" : "HelveticaNeue")
  let font = CTFontCreateWithName(name as CFString, size, nil)
  let attributed = NSAttributedString(
    string: text,
    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
  )
  let line = CTLineCreateWithAttributedString(attributed)
  var x = point.x
  if center, let width {
    x += (width - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2
  }
  context.textPosition = CGPoint(x: x, y: point.y)
  CTLineDraw(line, context)
}

func clock(_ seconds: Double) -> String {
  let minutes = Int(seconds) / 60
  let rest = seconds - Double(minutes * 60)
  return String(format: "%02d:%04.1f", minutes, rest)
}

struct Panel {
  var title: String
  var subtitle: String
  var rect: CGRect
  /// Seconds this mode ran.
  var seconds: Double
}

/// Draws a panel's frame, title, timer and (once finished) its done badge. Coordinates are CoreGraphics' (origin at
/// the bottom left).
func drawChrome(_ panel: Panel, in context: CGContext, at time: Double) {
  let top = CGFloat(height) - headerHeight
  let finished = time >= panel.seconds
  draw(panel.title, in: context, at: CGPoint(x: panel.rect.minX, y: top + 96), size: 30, color: white, bold: true, width: panel.rect.width, center: true)
  draw(panel.subtitle, in: context, at: CGPoint(x: panel.rect.minX, y: top + 64), size: 18, color: grey, width: panel.rect.width, center: true)
  draw(
    clock(min(time, panel.seconds)), in: context, at: CGPoint(x: panel.rect.minX, y: top + 14), size: 40,
    color: finished ? green : amber, bold: true, mono: true, width: panel.rect.width, center: true
  )
  if finished {
    let badge = CGRect(x: panel.rect.minX + 16, y: panel.rect.minY + 16, width: panel.rect.width - 32, height: 56)
    context.setFillColor(CGColor(red: 0.08, green: 0.30, blue: 0.18, alpha: 0.92))
    context.fill(badge)
    draw("✓ done in \(clock(panel.seconds))", in: context, at: CGPoint(x: badge.minX, y: badge.minY + 18), size: 24, color: green, bold: true, width: badge.width, center: true)
  }
}

func fit(_ image: CGImage, in rect: CGRect) -> CGRect {
  let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
  let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
  return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
}

// MARK: Main

let options = Options(CommandLine.arguments)
let uitest = try await FrameSource(path: options.uitest)
let bridge = try await FrameSource(path: options.bridge)
// What each simulator panel holds once its run is done.
let uitestHold = try await FrameSource(path: options.uitest)
  .lastAppFrame(upTo: options.uitestFreeze ?? options.uitestStart + options.uitestSeconds)
let bridgeHold = try await FrameSource(path: options.bridge)
  .frame(at: options.bridgeFreeze ?? options.bridgeStart + options.bridgeSeconds)
let headlessLines = (try? String(contentsOfFile: options.headless, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []

let panelTop = Double(height) - headerHeight
let panelHeight = panelTop - footerHeight
let simWidth = (panelHeight * uitest.size.width / uitest.size.height).rounded()
let panels = [
  Panel(title: "XCUITest", subtitle: "taps and types through the UI", rect: CGRect(x: margin, y: footerHeight, width: simWidth, height: panelHeight), seconds: options.uitestSeconds),
  Panel(title: "AgentCtl · simulator", subtitle: "the real app, driven via its bridge", rect: CGRect(x: margin * 2 + simWidth, y: footerHeight, width: simWidth, height: panelHeight), seconds: options.bridgeSeconds),
  Panel(title: "AgentCtl · headless", subtitle: "the same scenarios on the Mac, no simulator", rect: CGRect(x: margin * 3 + simWidth * 2, y: footerHeight, width: Double(width) - margin * 4 - simWidth * 2, height: panelHeight), seconds: options.headlessSeconds),
]
let duration = max(options.uitestSeconds, options.bridgeSeconds, options.headlessSeconds) + 3

let url = URL(fileURLWithPath: options.out)
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
  AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
  kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frameCount = Int(duration * fps)
for index in 0..<frameCount {
  let time = Double(index) / fps
  while !input.isReadyForMoreMediaData { usleep(2000) }
  var buffer: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
  guard let buffer else { fatalError("no pixel buffer") }
  CVPixelBufferLockBaseAddress(buffer, [])
  let context = CGContext(
    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
  )!
  context.setFillColor(background)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))

  for (panel, source, start, hold) in [
    (panels[0], uitest, options.uitestStart, uitestHold),
    (panels[1], bridge, options.bridgeStart, bridgeHold),
  ] {
    context.setFillColor(panelColor)
    context.fill(panel.rect)
    // Once a run is done, its panel holds a settled frame rather than whatever the recording shows at that
    // moment: an animation, or the home screen after the app has quit.
    let live = time < panel.seconds ? source.frame(at: start + time) : nil
    if let image = live ?? hold ?? source.frame(at: start + panel.seconds) {
      context.draw(image, in: fit(image, in: panel.rect.insetBy(dx: 6, dy: 6)))
    }
    drawChrome(panel, in: context, at: time)
  }

  // The headless panel: the terminal output, all of it once the run is over (it takes a fraction of a second).
  let terminal = panels[2]
  context.setFillColor(CGColor(red: 0.03, green: 0.04, blue: 0.05, alpha: 1))
  context.fill(terminal.rect)
  let shown = time >= terminal.seconds ? headlessLines.count : Int(Double(headlessLines.count) * time / max(terminal.seconds, 0.001))
  var y = terminal.rect.maxY - 36
  for line in headlessLines.prefix(shown) where y > terminal.rect.minY + 90 {
    let color = line.hasPrefix("PASS") ? green : line.hasPrefix("FAIL") ? CGColor(red: 1, green: 0.4, blue: 0.4, alpha: 1) : (line.hasPrefix("$") ? white : grey)
    draw(line, in: context, at: CGPoint(x: terminal.rect.minX + 20, y: y), size: 17, color: color, mono: true)
    y -= 26
  }
  drawChrome(terminal, in: context, at: time)

  draw(options.caption, in: context, at: CGPoint(x: 0, y: 24), size: 22, color: grey, width: CGFloat(width), center: true)

  CVPixelBufferUnlockBaseAddress(buffer, [])
  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
}

input.markAsFinished()
await writer.finishWriting()
if writer.status != .completed {
  fatalError("writing failed: \(String(describing: writer.error))")
}
print("wrote \(options.out) (\(String(format: "%.1f", duration)) s)")
