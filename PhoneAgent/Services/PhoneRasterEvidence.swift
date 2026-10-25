import Foundation
import CoreGraphics
import CryptoKit

enum PhoneRasterEvidence {
    static func raster(_ image: CGImage, maxWidth: Int = 320) -> PhoneRasterImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let width=min(maxWidth,image.width), height=Int((Double(image.height)*Double(width)/Double(image.width)).rounded())
        guard width>0,height>0,height<=2048 else { return nil }
        var pixels=[UInt8](repeating:0,count:width*height*4)
        let result=pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        return result ? .init(width:width,height:height,rgba:pixels) : nil
    }
    static func sha256(_ bytes: Data) -> String { SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() }
}
