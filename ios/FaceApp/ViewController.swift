//
//  ViewController.swift
//  FaceApp
//
//  Created by Bart Trzynadlowski on 10/14/23.
//

import UIKit
import SceneKit
import ARKit
import Vision

import AWSRekognition

class ViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    private var _faceDetectionRequest: VNDetectFaceRectanglesRequest?

    private struct BodyPoseRequestAttachments {
        public let depthBuffer: [Float]
        public let depthBufferWidth: Int
        public let depthBufferHeight: Int
        public let imageWidth: Int
        public let imageHeight: Int
        public let displayTransform: CGAffineTransform
        public let frame: ARFrame
    }
    
    private var _bodyPoseRequestAttachments: BodyPoseRequestAttachments?
    private var _jointLayers: [VNHumanBodyPoseObservation.JointName: CAShapeLayer] = [:]
    private var _rightWristCube: SCNNode?

    @IBOutlet var sceneView: ARSCNView!
    @IBOutlet weak var distanceLabel: UILabel!
    @IBOutlet weak var testImageView: UIImageView!
    @IBOutlet weak var placeButton: UIButton!

    @IBAction func onPlaceButtonTouched(_ sender: Any) {
        if let frame = sceneView.session.currentFrame {
            let position = frame.camera.transform.position
            let forward = frame.camera.transform.forward
            let up = frame.camera.transform.up
            
            // Test unproject
            
            // Create a plane in front of the camera, where plane is along xz and y is camera forward
            let planeTransform = simd_float4x4(
                translation: position - 1 * forward,
                rotation: simd_quatf.lookRotation(forward: up, up: forward),
                scale: simd_float3.one
            )
            
            let x = sceneView.bounds.width * 0.25
            let y = sceneView.bounds.height * 0.5
            if let worldPos = frame.camera.unprojectPoint(CGPoint(x: x, y: y), ontoPlane: planeTransform, orientation: .portrait, viewportSize: sceneView.bounds.size) {
                placeCube(position: worldPos)
            }
        }
    }
    
    private func placeCube(position: simd_float3) {
        // Place a debug cube
        let node = SCNNode(geometry: SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.01))
        node.simdPosition = position
        sceneView.scene.rootNode.addChildNode(node)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's delegate
        sceneView.delegate = self
        
        sceneView.session.delegate = self
        
        // Show statistics such as fps and timing information
        sceneView.showsStatistics = true
        
        // Create layers for rendering faces and body joints
        createFaceBoundingBoxLayer()
        //createJointLayers()

        // Create a cube that will track the right wrist
        let node = SCNNode(geometry: SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.01))
        sceneView.scene.rootNode.addChildNode(node)
        _rightWristCube = node
        node.isHidden = true

        // Hide debug controls
        placeButton.isHidden = true
        distanceLabel.isHidden = true
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = getARConfiguration()

        // Run the view's session
        sceneView.session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        sceneView.session.pause()
    }
    
    // MARK: - AR Configuration Setup
    
    private func getARConfiguration() -> ARConfiguration {
        let configuration = ARWorldTrackingConfiguration();
        if !ARWorldTrackingConfiguration.supportsFrameSemantics([ .sceneDepth ]) {
            fatalError("Scene depth not supported on this device")
        }
        configuration.frameSemantics.insert([ .sceneDepth ])
        return configuration
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if let currentFrame = session.currentFrame {
            let rgbFrame = currentFrame.capturedImage
            let depthFrame = currentFrame.sceneDepth?.depthMap
            if let depthFrame = depthFrame {
                let (depthFrameMeters, width, height) = convertDepthFrameToMeters(depthBuffer: depthFrame)

                // Test code: read depth in centerr of screen
//                let idx = Int(0.5 * Float(height)) * width + Int(0.5 * Float(width))
//                let distance = depthFrameMeters[idx]
                distanceLabel.text = ""//String(format: "Distance: %1.1f cm", distance * 100.0)

                // Detect faces
                detectFaces(rgbBuffer: rgbFrame, displayTransform: currentFrame.displayTransform(for: .portrait, viewportSize: view.bounds.size), frame: currentFrame)

                // Detect bodies
                detectBodyPose(rgbBuffer: rgbFrame, displayTransform: currentFrame.displayTransform(for: .portrait, viewportSize: view.bounds.size), depthBuffer: depthFrameMeters, depthBufferWidth: width, depthBufferHeight: height, frame: currentFrame)
            } else {
                distanceLabel.text = ""//Distance: ?"
            }
        }
    }

    // MARK: - Face Detection

    class FaceBoundingBoxLayer: CALayer {
        public var boundingBoxes: [CGRect] = []

        override func draw(in ctx: CGContext) {
            ctx.setStrokeColor(UIColor.red.cgColor)
            ctx.setLineWidth(2.0)

            for bb in boundingBoxes {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: bb.minX, y: bb.minY))
                ctx.addLine(to: CGPoint(x: bb.maxX, y: bb.minY))
                ctx.addLine(to: CGPoint(x: bb.maxX, y: bb.maxY))
                ctx.addLine(to: CGPoint(x: bb.minX, y: bb.maxY))
                ctx.addLine(to: CGPoint(x: bb.minX, y: bb.minY))
                ctx.strokePath()
            }
        }
    }

    private let _faceBoundingBoxLayer = FaceBoundingBoxLayer()

    private func createFaceBoundingBoxLayer() {
        _faceBoundingBoxLayer.isHidden = false
        _faceBoundingBoxLayer.frame = sceneView.layer.bounds
        sceneView.layer.addSublayer(_faceBoundingBoxLayer)
    }

    private func convertVisionPointToViewportPoint(point: CGPoint, displayTransform: CGAffineTransform) -> CGPoint {
        // Vision has (0,0) at bottom left but we want it to be in top left
        let normalizedPoint = CGPoint(x: point.x, y: 1.0 - point.y)

        // Required transform that maps to the viewport that displays the ARFrame, also apparently in some normalized coordinate form
        let normalizedViewportPoint = CGPointApplyAffineTransform(normalizedPoint, displayTransform)

        let viewportPoint = CGPoint(x: normalizedViewportPoint.x * sceneView.bounds.width, y: normalizedViewportPoint.y * sceneView.bounds.height)
        return viewportPoint
    }

    private func convertVisionRectToViewportRect(rect: CGRect, displayTransform: CGAffineTransform) -> CGRect {
        let min = convertVisionPointToViewportPoint(point: CGPoint(x: rect.minX, y: rect.minY), displayTransform: displayTransform)
        let max = convertVisionPointToViewportPoint(point: CGPoint(x: rect.maxX, y: rect.maxY), displayTransform: displayTransform)
        let visionRect = CGRect(x: min.x, y: min.y, width: max.x - min.x, height: max.y - min.y)
        return visionRect
    }

    private func extractFaceCrop(of rect: CGRect, from image: UIImage) -> UIImage? {
        let origin = CGPoint(x: rect.minX * image.size.width, y: (1.0 - rect.maxY) * image.size.height)
        let size = CGSize(width: rect.width * image.size.width, height: rect.height * image.size.height)

        // Take crop with rect that is expanded around the face to ensure whole face is captured
        let expandByPercent: CGFloat = 0.25
        let adjustedOrigin = CGPoint(x: origin.x - expandByPercent * size.width * 0.5, y: origin.y - expandByPercent * size.height * 0.5)
        let adjustedSize = CGSize(width: size.width * (1.0 + expandByPercent), height: size.height * (1.0 + expandByPercent))
        return image.crop(to: CGRect(origin: adjustedOrigin, size: adjustedSize))
    }

    private func detectFaces(rgbBuffer: CVPixelBuffer, displayTransform: CGAffineTransform, frame: ARFrame) {
        guard _faceDetectionRequest == nil else { return }  // only if no request in progress

        _faceDetectionRequest = VNDetectFaceRectanglesRequest(completionHandler: { (request, error) in
            if error != nil {
                print("FaceDetection error: \(String(describing: error))")
            }

            guard let faceDetectionRequest = request as? VNDetectFaceRectanglesRequest,
                  let results = faceDetectionRequest.results,
                  results.count > 0 else {
                DispatchQueue.main.async {
                    self._faceDetectionRequest = nil
                }
                return
            }

            print("Found \(results.count) faces")

            guard let image = UIImage(pixelBuffer: rgbBuffer) else {
                DispatchQueue.main.async {
                    self._faceDetectionRequest = nil
                }
                return
            }

            // Update and display
            DispatchQueue.main.async {
                // Convert bounding boxes to layer coordinate system and draw
                let faceBoundingBoxes: [CGRect] = results.map { self.convertVisionRectToViewportRect(rect: $0.boundingBox, displayTransform: displayTransform) }
                self._faceBoundingBoxLayer.boundingBoxes = faceBoundingBoxes
                self._faceBoundingBoxLayer.setNeedsDisplay()
                self._faceBoundingBoxLayer.isHidden = false

                // We can take another request now
                self._faceDetectionRequest = nil

                // Extract cropped images
                let faceCrops = results.compactMap { self.extractFaceCrop(of: $0.boundingBox, from: image) }
                if let firstFace = faceCrops.first {
                    self.testImageView.image = firstFace
                }
            }
        })

        let requestHandler = VNImageRequestHandler(cvPixelBuffer: rgbBuffer)
        do {
            try requestHandler.perform([ _faceDetectionRequest! ])
        } catch {
            print("Unable to perform request: \(error)")
        }
    }

    // MARK: - Body Pose
    
    private func createJointLayers() {
        _jointLayers = [
            .leftAnkle: CAShapeLayer(),
            .leftEar: CAShapeLayer(),
            .leftEye: CAShapeLayer(),
            .leftElbow: CAShapeLayer(),
            .leftKnee: CAShapeLayer(),
            .leftWrist: CAShapeLayer(),
            .rightAnkle: CAShapeLayer(),
            .rightEar: CAShapeLayer(),
            .rightEye: CAShapeLayer(),
            .rightElbow: CAShapeLayer(),
            .rightKnee: CAShapeLayer(),
            .rightWrist: CAShapeLayer(),
            .nose: CAShapeLayer(),
            .neck: CAShapeLayer(),
            .rightShoulder: CAShapeLayer(),
            .rightHip: CAShapeLayer(),
            .root: CAShapeLayer(),
            .leftHip: CAShapeLayer(),
            .leftShoulder: CAShapeLayer()
        ]
        for (_, layer) in _jointLayers {
            layer.path = UIBezierPath(roundedRect: CGRect(x: view.center.x - 2, y: view.center.y - 2, width: 4, height: 4), cornerRadius: 0).cgPath
            layer.fillColor = UIColor.red.cgColor
            layer.isHidden = true
            sceneView.layer.addSublayer(layer)
        }
        _jointLayers[.rightWrist]!.fillColor = UIColor.green.cgColor
        _jointLayers[.leftEye]!.fillColor = UIColor.yellow.cgColor
        _jointLayers[.rightEye]!.fillColor = UIColor.yellow.cgColor
        _jointLayers[.nose]!.fillColor = UIColor.blue.cgColor
    }
    
    private func detectBodyPose(rgbBuffer: CVPixelBuffer, displayTransform: CGAffineTransform, depthBuffer: [Float], depthBufferWidth: Int, depthBufferHeight: Int, frame: ARFrame) {
        // Only if no request in progress
        guard _bodyPoseRequestAttachments == nil else {
            return
        }
        
        // Submit body pose detection request
        _bodyPoseRequestAttachments = BodyPoseRequestAttachments(
            depthBuffer: depthBuffer,
            depthBufferWidth: depthBufferWidth,
            depthBufferHeight: depthBufferHeight,
            imageWidth: CVPixelBufferGetWidth(rgbBuffer),
            imageHeight: CVPixelBufferGetHeight(rgbBuffer),
            displayTransform: displayTransform,
            frame: frame
        )
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: rgbBuffer)
        let request = VNDetectHumanBodyPoseRequest(completionHandler: bodyPoseHandler)
        do {
            try requestHandler.perform([ request ])
        } catch {
            print("Unable to perform request: \(error)")
        }
    }
    
    private func bodyPoseHandler(request: VNRequest, error: Error?) {
        guard let attachments = _bodyPoseRequestAttachments else {
            return
        }
        _bodyPoseRequestAttachments = nil
        guard let observations = request.results as? [VNHumanBodyPoseObservation] else {
            return
        }
        
        for observation in observations {
            processBodyPose(observation: observation, attachments: attachments)
        }
    }
    
    private func processBodyPose(observation: VNHumanBodyPoseObservation, attachments: BodyPoseRequestAttachments) {
        guard let recognizedPoints = try? observation.recognizedPoints(.all) else {
            return
        }
        
        // Disable all layers
        for (_, layer) in _jointLayers {
            layer.isHidden = true
        }
        
        // Enable layers coresponding to observed joints and set their positions
        for (jointName, point) in recognizedPoints {
            if point.confidence > 0, let layer = _jointLayers[jointName] {
                let normalizedPoint = CGPoint(x: point.location.x, y: 1.0 - point.location.y)                               // Vision has (0,0) at bottom left but we want it to be in top left
                let normalizedViewportPoint = CGPointApplyAffineTransform(normalizedPoint, attachments.displayTransform)    // a required transform that maps to the viewport that displays the ARFrame, also apparently in some normalized coordinate form
                let viewportPoint = CGPoint(x: normalizedViewportPoint.x * sceneView.bounds.width, y: normalizedViewportPoint.y * sceneView.bounds.height)  // not even sure if this is really correct
                layer.path = UIBezierPath(roundedRect: CGRect(x: viewportPoint.x - 2, y: viewportPoint.y - 2, width: 4, height: 4), cornerRadius: 0).cgPath
                layer.isHidden = false
                
                // Test: right wrist
                if jointName == .rightWrist {
                    if let rightWristPos = updateRightWristCube(viewportPoint: viewportPoint, normalizedPoint: normalizedPoint, attachments: attachments) {
                    }
                }
            }
        }
    }
    
    private func convertDepthFrameToMeters(depthBuffer: CVPixelBuffer) -> ([Float], Int, Int) {
        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)

        // Cast depth frame to float and copy to our own buffer
        CVPixelBufferLockBaseAddress(depthBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depthBuffer), to: UnsafeMutablePointer<Float32>.self)
        let depth: [Float] = Array(UnsafeBufferPointer(start: floatBuffer, count: width * height))
        CVPixelBufferUnlockBaseAddress(depthBuffer, CVPixelBufferLockFlags(rawValue: 0))

        // Return our buffer to caller
        return (depth, width, height)
    }
    
    // MARK: - Depth Tracking of Body Points
    
    // viewportPoint is what ARKit's unproject expects, normalizedPoint corresponds to pixel buffer and should
    // be used to sample depth map
    private func updateRightWristCube(viewportPoint: CGPoint, normalizedPoint: CGPoint, attachments: BodyPoseRequestAttachments) -> Vector3? {
        let frame = attachments.frame
        let position = frame.camera.transform.position
        let forward = frame.camera.transform.forward
        let up = frame.camera.transform.up
        
        _rightWristCube?.isHidden = true
        
        // Create a plane in front of the camera, where plane is along xz and y is camera forward
        let planeTransform = simd_float4x4(
            translation: position - 1 * forward,
            rotation: Quaternion.lookRotation(forward: up, up: forward),
            scale: simd_float3.one
        )
        
        // Try to unproject the viewport point so that we can construct a ray from the camera position
        // into the world passing through the viewport point. If we can't do this, we cannot proceed.
        guard let planeWorldPos = frame.camera.unprojectPoint(viewportPoint, ontoPlane: planeTransform, orientation: .portrait, viewportSize: sceneView.bounds.size) else { return nil }
        let ray = Ray(origin: position, through: planeWorldPos)
        
        // Sample the depth map to figure out how far along the ray we are
        let distance = sampleDepthMap(attachments: attachments, normalizedPoint: normalizedPoint)
        
        // Move cube to that point
        let rightWristPos = position + ray.direction * distance
        _rightWristCube?.simdPosition = rightWristPos
        _rightWristCube?.isHidden = false
        
        return rightWristPos
    }
    
    private func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        return min(max(value, minValue), maxValue)
    }
    
    private func sampleDepthMap(attachments: BodyPoseRequestAttachments, normalizedPoint: CGPoint) -> Float {
        let x = clamp(Int(round(Float(normalizedPoint.x) * Float(attachments.depthBufferWidth))), min: 0, max: attachments.depthBufferWidth - 1)
        let y = clamp(Int(round(Float(normalizedPoint.y) * Float(attachments.depthBufferHeight))), min: 0, max: attachments.depthBufferHeight - 1)
        return attachments.depthBuffer[y * attachments.depthBufferWidth + x]
    }

    // MARK: - ARSCNViewDelegate
    
/*
    // Override to create and configure nodes for anchors added to the view's session.
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        let node = SCNNode()
     
        return node
    }
*/
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
        
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
        
    }
}
