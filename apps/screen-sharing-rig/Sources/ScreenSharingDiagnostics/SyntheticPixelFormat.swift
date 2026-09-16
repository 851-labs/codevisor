/// Pixel format the synthetic source hands to WebRTC. BGRA reproduces the
/// original input path; NV12 matches what ScreenCaptureKit delivers.
package enum SyntheticPixelFormat: String, Sendable { case bgra, nv12 }
