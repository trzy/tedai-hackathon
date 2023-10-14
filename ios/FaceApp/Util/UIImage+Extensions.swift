//
//  UIImage+Extensions.swift
//  FaceApp
//
//  Created by Bart Trzynadlowski on 10/14/23.
//

import UIKit
import CoreVideo
import VideoToolbox

extension UIImage {
    /// Creates a `UIImage` from a `CVPixelBuffer`. Not all `CVPixelBuffer` formats are supported.
    /// - Parameter pixelBuffer: The pixel buffer to create the image from.
    /// - Returns: `nil` if unsuccessful, otherwise `UIImage`.
    public convenience init?(pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let cgImage = cgImage else {
            print("[UIImage] Unable to create UIImage from pixel buffer")
            return nil
        }
        self.init(cgImage: cgImage)
    }

    public func crop(to rect: CGRect) -> UIImage? {
        guard let srcImage = self.cgImage else {
            print("[UIImage] Unable to obtain CGImage")
            return nil
        }

        guard let croppedImage = srcImage.cropping(to: rect) else {
            print("[UIImage] Failed to produce cropped CGImage")
            return nil
        }

        return UIImage(cgImage: croppedImage, scale: self.imageRendererFormat.scale, orientation: self.imageOrientation)
    }

    public func centerCropped(to cropSize: CGSize) -> UIImage? {
        guard let srcImage = self.cgImage else {
            print("[UIImage] Unable to obtain CGImage")
            return nil
        }

        // Must be careful to avoid rounding up anywhere!
        let xOffset = (size.width - cropSize.width) / 2.0
        let yOffset = (size.height - cropSize.height) / 2.0
        let cropRect = CGRect(x: CGFloat(Int(xOffset)), y: CGFloat(Int(yOffset)), width: CGFloat(Int(cropSize.width)), height: CGFloat(Int(cropSize.height)))

        guard let croppedImage = srcImage.cropping(to: cropRect) else {
            print("[UIImage] Failed to produce cropped CGImage")
            return nil
        }

        return UIImage(cgImage: croppedImage, scale: self.imageRendererFormat.scale, orientation: self.imageOrientation)
    }

    /// Converts a `UIImage` to an ARGB-formatted `CVPixelBuffer`. The `UIImage` is assumed to be
    /// opaque and the alpha channel is ignored. The resulting pixel buffer has all alpha values set to `0xFF`.
    /// - Returns: `CVPixelBuffer` if successful otherwise `nil`.
    public func toPixelBuffer() -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)

        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attributes,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess,
              let pixelBuffer = pixelBuffer else {
            print("[UIImage] Error: Unable to create pixel buffer")
            return nil
        }

        let lockFlags = CVPixelBufferLockFlags(rawValue: 0)

        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
            print("[UIImage] Error: Unable to lock pixel buffer")
            return nil
        }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags)
            print("[UIImage] Error: Unable to create CGContext")
            return nil
        }

        UIGraphicsPushContext(ctx)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        return pixelBuffer
    }
}
