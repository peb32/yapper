import AVFoundation
import SwiftUI

struct VideoFrame
{
  let id: UInt32
  let keyframe: Bool
  let data: [UInt8]
}

// Puts video frames back together from their UDP fragments, which can arrive in any order or not at all
struct FrameAssembler
{
  // Frames older than this many are given up on, their missing fragments aren't coming
  private static let maxPartialFrames = 8

  private struct Partial
  {
    var fragments: [[UInt8]]
    var received = 0
    var keyframe = false
  }

  private var partial: [UInt32: Partial] = [:]

  mutating func add(frameId: UInt32, index: UInt16, count: UInt16, keyframe: Bool, data: [UInt8]) -> VideoFrame?
  {
    guard count > 0, Int(count) <= Limits.maxVideoFragments, index < count, !data.isEmpty else
    {
      return nil
    }

    var frame = partial[frameId] ?? Partial(fragments: Array(repeating: [], count: Int(count)))
    guard frame.fragments.count == Int(count), frame.fragments[Int(index)].isEmpty else
    {
      return nil
    }

    frame.fragments[Int(index)] = data
    frame.keyframe = frame.keyframe || keyframe
    frame.received += 1

    if frame.received < Int(count)
    {
      partial[frameId] = frame
      while partial.count > Self.maxPartialFrames, let oldest = partial.keys.min()
      {
        partial[oldest] = nil
      }
      return nil
    }

    // Anything older can't be used anymore, the decoder has moved past it
    partial = partial.filter { $0.key > frameId }
    return VideoFrame(id: frameId, keyframe: frame.keyframe, data: frame.fragments.flatMap { $0 })
  }
}

// Decodes the sharer's H.264 (Annex B, from openh264) with the system decoder inside AVSampleBufferDisplayLayer.
// push() runs on the network queue.
final class ScreenViewer
{
  private static let keyframeRequestGap = 0.5

  let layer = AVSampleBufferDisplayLayer()

  private let requestKeyframe: () -> Void
  private var format: CMVideoFormatDescription?
  private var sps: [UInt8] = []
  private var pps: [UInt8] = []
  private var lastFrameId: UInt32 = 0
  private var waitingForKeyframe = true
  private var lastRequest = Date.distantPast

  init(requestKeyframe: @escaping () -> Void)
  {
    self.requestKeyframe = requestKeyframe
    layer.videoGravity = .resizeAspect
  }

  private func askForKeyframe()
  {
    waitingForKeyframe = true
    if Date().timeIntervalSince(lastRequest) > Self.keyframeRequestGap
    {
      lastRequest = Date()
      requestKeyframe()
    }
  }

  func push(_ frame: VideoFrame)
  {
    // Late or repeated
    if frame.id <= lastFrameId
    {
      return
    }

    // Each frame builds on the one before it, so after a lost frame everything is garbage until the next keyframe
    if !frame.keyframe, waitingForKeyframe || frame.id != lastFrameId + 1
    {
      return askForKeyframe()
    }
    lastFrameId = frame.id

    // The layer goes into .failed after a decode error or a trip to the background
    if layer.status == .failed
    {
      layer.flush()
      if !frame.keyframe
      {
        return askForKeyframe()
      }
    }

    // Annex B start codes to 4-byte lengths, pulling out the parameter sets for the format
    var avcc: [UInt8] = []
    for nal in Self.splitAnnexB(frame.data)
    {
      switch nal[nal.startIndex] & 0x1F
      {
      case 7:
        updateFormat(sps: Array(nal), pps: pps)
      case 8:
        updateFormat(sps: sps, pps: Array(nal))
      default:
        let length = UInt32(nal.count)
        avcc += [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        avcc += nal
      }
    }

    guard let format, !avcc.isEmpty, let sample = Self.makeSample(avcc, format: format) else
    {
      return askForKeyframe()
    }

    waitingForKeyframe = false
    layer.enqueue(sample)
  }

  private func updateFormat(sps: [UInt8], pps: [UInt8])
  {
    self.sps = sps
    self.pps = pps
    guard !sps.isEmpty, !pps.isEmpty else
    {
      return
    }

    sps.withUnsafeBufferPointer { spsPointer in
      pps.withUnsafeBufferPointer { ppsPointer in
        let pointers = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
        let sizes = [sps.count, pps.count]
        var created: CMVideoFormatDescription?
        if CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                               parameterSetCount: 2,
                                                               parameterSetPointers: pointers,
                                                               parameterSetSizes: sizes,
                                                               nalUnitHeaderLength: 4,
                                                               formatDescriptionOut: &created) == noErr
        {
          format = created
        }
      }
    }
  }

  private static func splitAnnexB(_ data: [UInt8]) -> [ArraySlice<UInt8>]
  {
    // Where each NAL unit starts, right after a 00 00 01 start code (a 00 00 00 01 one ends the same way)
    var starts: [Int] = []
    var i = 0
    while i + 2 < data.count
    {
      if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1
      {
        starts.append(i + 3)
        i += 3
      }
      else
      {
        i += 1
      }
    }

    var nals: [ArraySlice<UInt8>] = []
    for (n, start) in starts.enumerated()
    {
      var end = n + 1 < starts.count ? starts[n + 1] - 3 : data.count
      // Trailing zeros belong to the next 4-byte start code
      while end > start, data[end - 1] == 0
      {
        end -= 1
      }
      if end > start
      {
        nals.append(data[start..<end])
      }
    }
    return nals
  }

  private static func makeSample(_ avcc: [UInt8], format: CMVideoFormatDescription) -> CMSampleBuffer?
  {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                             memoryBlock: nil,
                                             blockLength: avcc.count,
                                             blockAllocator: kCFAllocatorDefault,
                                             customBlockSource: nil,
                                             offsetToData: 0,
                                             dataLength: avcc.count,
                                             flags: 0,
                                             blockBufferOut: &block) == noErr,
          let block,
          avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }) == noErr
    else
    {
      return nil
    }

    var sample: CMSampleBuffer?
    var size = avcc.count
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                    dataBuffer: block,
                                    formatDescription: format,
                                    sampleCount: 1,
                                    sampleTimingEntryCount: 0,
                                    sampleTimingArray: nil,
                                    sampleSizeEntryCount: 1,
                                    sampleSizeArray: &size,
                                    sampleBufferOut: &sample) == noErr,
          let sample
    else
    {
      return nil
    }

    // No timestamps, show each frame as soon as it's decoded
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0
    {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary,
                           Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                           Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}

struct VideoView: UIViewRepresentable
{
  let layer: AVSampleBufferDisplayLayer

  final class LayerView: UIView
  {
    var videoLayer: CALayer?

    override func layoutSubviews()
    {
      super.layoutSubviews()
      videoLayer?.frame = bounds
    }
  }

  func makeUIView(context: Context) -> LayerView
  {
    let view = LayerView()
    view.layer.addSublayer(layer)
    view.videoLayer = layer
    return view
  }

  func updateUIView(_ view: LayerView, context: Context)
  {
  }
}
