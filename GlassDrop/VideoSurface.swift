import AVFoundation
import SwiftUI
import UIKit

/// 풀어낸 화면 한 장 한 장을 받아서 화면 레이어에 올려 주는 곳.
final class VideoSurface {
    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?
    private var firstFrameSent = false
    /// 첫 화면이 도착했을 때 한 번 불려요(메인 스레드).
    var onFirstFrame: (() -> Void)?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    func reset() {
        lock.lock()
        firstFrameSent = false
        let l = layer
        lock.unlock()
        l?.flushAndRemoveImage()
    }

    func show(_ pixelBuffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format = format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample = sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        lock.lock()
        let l = layer
        let first = !firstFrameSent
        firstFrameSent = true
        lock.unlock()
        guard let l = l else { return }
        if l.status == .failed { l.flush() }
        l.enqueue(sample)
        if first {
            let cb = onFirstFrame
            DispatchQueue.main.async { cb?() }
        }
    }
}

final class DisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct VideoSurfaceView: UIViewRepresentable {
    let surface: VideoSurface

    func makeUIView(context: Context) -> DisplayView {
        let v = DisplayView()
        v.backgroundColor = .black
        v.displayLayer.videoGravity = .resizeAspect
        surface.attach(v.displayLayer)
        return v
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {}
}
