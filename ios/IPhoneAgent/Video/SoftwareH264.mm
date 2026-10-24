#import "SoftwareH264.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <codec_api.h>
#include <algorithm>
#include <vector>

@implementation SoftwareH264 {
    ISVCDecoder *_decoder;
    NSInteger _lastStatus, _width, _height;
    uint64_t _outputTimestamp;
}
- (instancetype)init {
    if ((self = [super init])) [self reset];
    return self;
}
- (void)dealloc {
    if (_decoder) { _decoder->Uninitialize(); WelsDestroyDecoder(_decoder); }
}
- (void)reset {
    _width = 0; _height = 0; _outputTimestamp = 0;
    if (_decoder) { _decoder->Uninitialize(); WelsDestroyDecoder(_decoder); _decoder = nullptr; }
    _lastStatus = WelsCreateDecoder(&_decoder);
    if (!_lastStatus && _decoder) {
        SDecodingParam param{};
        param.eEcActiveIdc = ERROR_CON_DISABLE; // Never present concealed pixels as trustworthy input.
        param.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
        _lastStatus = _decoder->Initialize(&param);
        int level = WELS_LOG_QUIET;
        _decoder->SetOption(DECODER_OPTION_TRACE_LEVEL, &level);
    }
}
- (NSInteger)lastStatus { return _lastStatus; }
- (NSInteger)width { return _width; }
- (NSInteger)height { return _height; }
- (uint64_t)outputTimestamp { return _outputTimestamp; }
- (NSData *)decode:(NSData *)annexB timestamp:(uint64_t)timestamp jpegQuality:(double)quality emit:(BOOL)emit {
    if (!_decoder || annexB.length > INT_MAX) { _lastStatus = -1; return nil; }
    unsigned char *planes[3]{};
    SBufferInfo info{};
    info.uiInBsTimeStamp = timestamp;
    _lastStatus = _decoder->DecodeFrameNoDelay((const unsigned char *)annexB.bytes,
                                              (int)annexB.length, planes, &info);
    // High-profile AVC retains a decoded picture for display reordering even
    // without B frames. AirPlay may now stay quiet indefinitely. Drain that
    // picture without discarding reference frames, and keep its own timestamp.
    if (!_lastStatus) {
        int remaining = 0;
        _decoder->GetOption(DECODER_OPTION_NUM_OF_FRAMES_REMAINING_IN_BUFFER, &remaining);
        for (int i = 0; i < remaining; ++i) {
            unsigned char *flushed[3]{};
            SBufferInfo pending{};
            _lastStatus = _decoder->FlushFrame(flushed, &pending);
            if (_lastStatus) return nil;
            if (pending.iBufferStatus == 1 && (info.iBufferStatus != 1 ||
                pending.uiOutYuvTimeStamp >= info.uiOutYuvTimeStamp)) {
                info = pending; std::copy(flushed, flushed + 3, planes);
            }
        }
    }
    if (_lastStatus || info.iBufferStatus != 1 || !emit) return nil;
    _outputTimestamp = info.uiOutYuvTimeStamp;
    int w = info.UsrData.sSystemBuffer.iWidth, h = info.UsrData.sSystemBuffer.iHeight;
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) { _lastStatus = -2; return nil; }
    _width = w; _height = h;
    const int ys = info.UsrData.sSystemBuffer.iStride[0], cs = info.UsrData.sSystemBuffer.iStride[1];
    // Explicit CPU conversion; CoreImage/Metal rendering can be unavailable in the background.
    std::vector<uint8_t> rgb((size_t)w * h * 4);
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int c = std::max(0, int(planes[0][y * ys + x]) - 16);
        int d = int(planes[1][(y / 2) * cs + x / 2]) - 128;
        int e = int(planes[2][(y / 2) * cs + x / 2]) - 128;
        auto *p = rgb.data() + ((size_t)y * w + x) * 4;
        p[0] = std::clamp((298 * c + 409 * e + 128) >> 8, 0, 255);
        p[1] = std::clamp((298 * c - 100 * d - 208 * e + 128) >> 8, 0, 255);
        p[2] = std::clamp((298 * c + 516 * d + 128) >> 8, 0, 255); p[3] = 255;
    }
    auto color = CGColorSpaceCreateDeviceRGB();
    auto provider = CGDataProviderCreateWithData(nullptr, rgb.data(), rgb.size(), nullptr);
    auto image = CGImageCreate(w, h, 8, 32, (size_t)w * 4, color, kCGImageAlphaNoneSkipLast,
                               provider, nullptr, false, kCGRenderingIntentDefault);
    NSMutableData *out = [NSMutableData data];
    auto dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                 (__bridge CFStringRef)UTTypeJPEG.identifier, 1, nullptr);
    if (image && dest) {
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)});
        if (!CGImageDestinationFinalize(dest)) { out = nil; _lastStatus = -3; }
    } else { out = nil; _lastStatus = -3; }
    if (dest) CFRelease(dest); if (image) CGImageRelease(image);
    CGDataProviderRelease(provider); CGColorSpaceRelease(color);
    return out;
}
@end
