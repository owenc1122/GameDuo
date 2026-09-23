import AVFoundation
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/Users/owen/Downloads/IMG_4653.mov")
let asset = AVURLAsset(url: url)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 900, height: 900)
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let duration = CMTimeGetSeconds(asset.duration)
print("Duration", duration)
for index in 0..<12 {
    let seconds = duration * Double(index) / 12
    let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!
    try data.write(to: out.appendingPathComponent(String(format: "reference-%02d.png", index)))
}
