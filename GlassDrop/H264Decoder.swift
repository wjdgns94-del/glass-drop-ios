import CoreMedia
import Foundation
import VideoToolbox

/// 한 프레임(NAL 묶음)씩 받아 VideoToolbox(VTDecompressionSession)로 풀어 화면에 보내요.
/// 키프레임(IDR)과 SPS/PPS가 올 때까지는 기다려요.
final class H264Decoder {
    private let surface: VideoSurface
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var paramsChanged = false
    private var failures = 0
    private(set) var framesDecoded = 0
    private(set) var framesWaitingForParams = 0

    /// 풀 수 없는 상태가 되면 불려요(연결을 다시 해야 해요).
    var onFatal: ((String) -> Void)?

    init(surface: VideoSurface) { self.surface = surface }

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        format = nil
    }

    func decode(accessUnit nals: [[UInt8]]) {
        var vcl: [[UInt8]] = []
        var isIDR = false
        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7:
                if sps != nil && sps! != nal { paramsChanged = true }
                sps = nal
            case 8:
                if pps != nil && pps! != nal { paramsChanged = true }
                pps = nal
            case 5:
                isIDR = true
                vcl.append(nal)
            case 1:
                vcl.append(nal)
            default:
                break
            }
        }
        guard !vcl.isEmpty else { return }

        if session == nil || (paramsChanged && isIDR) {
            guard isIDR else { return }
            guard sps != nil, pps != nil else {
                framesWaitingForParams += 1
                return
            }
            invalidate()
            guard makeSession() else { return }
            paramsChanged = false
        }
        guard let session = session, let format = format else { return }

        // AVCC 형식(앞에 4바이트 길이)으로 바꿔 담아요.
        var avcc = Data()
        for nal in vcl {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }
        let total = avcc.count

        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                    blockLength: total, blockAllocator: kCFAllocatorDefault,
                                                    customBlockSource: nil, offsetToData: 0, dataLength: total,
                                                    flags: 0, blockBufferOut: &block)
        guard st == noErr, let blockBuffer = block else { return fail("block \(st)") }
        st = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: total)
        }
        guard st == noErr else { return fail("copy \(st)") }

        var sample: CMSampleBuffer?
        var sizes = [total]
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                                       formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                       sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                                       sampleBufferOut: &sample)
        guard st == noErr, let sampleBuffer = sample else { return fail("sample \(st)") }

        let surface = self.surface
        var infoFlags = VTDecodeInfoFlags()
        let ds = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [],
                                                   infoFlagsOut: &infoFlags) { status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer = imageBuffer {
                surface.show(imageBuffer)
            }
        }
        if ds == noErr {
            failures = 0
            framesDecoded += 1
        } else {
            fail("decode \(ds)")
        }
    }

    private func fail(_ why: String) {
        failures += 1
        if failures >= 3 {
            failures = 0
            onFatal?("화면을 풀지 못했어요 (\(why))")
        }
    }

    private func makeSession() -> Bool {
        guard let sps = sps, let pps = pps else { return false }
        var fd: CMVideoFormatDescription?
        let st: OSStatus = sps.withUnsafeBufferPointer { sp in
            pps.withUnsafeBufferPointer { pp in
                let pointers: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard st == noErr, let desc = fd else {
            fail("format \(st)")
            return false
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var newSession: VTDecompressionSession?
        let cs = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: desc,
                                              decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &newSession)
        guard cs == noErr, let created = newSession else {
            fail("session \(cs)")
            return false
        }
        format = desc
        session = created
        return true
    }
}
