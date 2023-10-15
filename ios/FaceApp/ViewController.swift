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
    private var _rekognition: AWSRekognition?

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
        
        // Create layers for rendering faces
        createFaceBoundingBoxLayer()


        // Create a cube that will track the right wrist
        let node = SCNNode(geometry: SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.01))
        sceneView.scene.rootNode.addChildNode(node)
        _rightWristCube = node
        node.isHidden = true

        // Hide debug controls
        placeButton.isHidden = true
        distanceLabel.isHidden = true

        // AWS init
        let credentialsProvider = AWSStaticCredentialsProvider(accessKey: "", secretKey: "")
        let configuration = AWSServiceConfiguration(
            region: AWSRegionType.USWest1,
            credentialsProvider: credentialsProvider)
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        _rekognition = AWSRekognition.default()
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
        /*
         if !ARWorldTrackingConfiguration.supportsFrameSemantics([ .sceneDepth ]) {
            fatalError("Scene depth not supported on this device")
        }
        configuration.frameSemantics.insert([ .sceneDepth ])
        */
        return configuration
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if let currentFrame = session.currentFrame {
            let rgbFrame = currentFrame.capturedImage
            // Detect faces
            detectFaces(rgbBuffer: rgbFrame, displayTransform: currentFrame.displayTransform(for: .portrait, viewportSize: view.bounds.size), frame: currentFrame)
            
            /*
            let depthFrame = currentFrame.sceneDepth?.depthMap
            if let depthFrame = depthFrame {
                let (depthFrameMeters, width, height) = convertDepthFrameToMeters(depthBuffer: depthFrame)

                // Test code: read depth in centerr of screen
//                let idx = Int(0.5 * Float(height)) * width + Int(0.5 * Float(width))
//                let distance = depthFrameMeters[idx]
                distanceLabel.text = ""//String(format: "Distance: %1.1f cm", distance * 100.0)

      

                // Detect bodies
            
                detectBodyPose(rgbBuffer: rgbFrame, displayTransform: currentFrame.displayTransform(for: .portrait, viewportSize: view.bounds.size), depthBuffer: depthFrameMeters, depthBufferWidth: width, depthBufferHeight: height, frame: currentFrame)
            } else {
                distanceLabel.text = ""//Distance: ?"
            }*/
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

    struct Face {
        let boundingBox: CGRect // in display frame
        let image: UIImage?     // cropped image
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

    private var _lastRekognitionRequestAt: Double = 0

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
                    self.clearNameLabels()
                    self._faceBoundingBoxLayer.isHidden = true
                }
                return
            }

            //print("Found \(results.count) faces")

            guard let image = UIImage(pixelBuffer: rgbBuffer) else {
                DispatchQueue.main.async {
                    self._faceDetectionRequest = nil
                    self.clearNameLabels()
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

                // Extract cropped face images
                var faces: [Face] = []
                for i in 0..<faceBoundingBoxes.count {
                    faces.append(Face(boundingBox: faceBoundingBoxes[i], image: self.extractFaceCrop(of: results[i].boundingBox, from: image)))
                }

                // Send to recognition
                // Throttle requests
                let now = Date.timeIntervalSinceReferenceDate
                guard now - self._lastRekognitionRequestAt >= 1.0 else {
                    return
                }
                DispatchQueue.main.async {
                    self.clearNameLabels()
                }
                for face in faces {
                    self.sendImageToRekognition(face: face)
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

    // MARK: - AWS


    func sendImageToRekognition(face: Face) {
        _lastRekognitionRequestAt = Date.timeIntervalSinceReferenceDate

        guard let rekognitionObject = _rekognition else { return }

        guard let imageData = face.image?.jpegData(compressionQuality: 0.75) else {
            return
        }

        let awsImage = AWSRekognitionImage()
        awsImage?.bytes = imageData
        let request = AWSRekognitionSearchFacesByImageRequest()
        request?.image = awsImage
        request?.collectionId = "tedai-hackathon"
        request?.faceMatchThreshold = 90
        request?.maxFaces = 1

        rekognitionObject.searchFaces(byImage: request!) { (result, error) in
            if error != nil {
                print(error!)
                return
            }

            

            guard let result = result else { return }
            guard let faceMatches = result.faceMatches, faceMatches.count > 0 else { return }
            guard let faceMatch = faceMatches.first else { return }
            guard let theRealFace = faceMatch.face else { return }
            guard let name = theRealFace.externalImageId else { return }

            print("NAME = \(name)")
            DispatchQueue.main.async {  // on main thread
                self.showLabelForFace(face: face, name: name)
            }
        }
    }

    // Just for simplicity, we have a text layer per name
    private var _nameToLabelLayer: [String: CATextLayer] = [:]

    private func clearNameLabels() {
        // Initially disable all layers
        for (_, layer) in self._nameToLabelLayer {
            layer.isHidden = true
        }
    }

    private func showLabelForFace(face: Face, name: String) {
        //clearNameLabels()

        // Lazy instantiate a CATextLayer
        if _nameToLabelLayer[name] == nil {
            let layer = CATextLayer()
            _nameToLabelLayer[name] = layer
            layer.isHidden = true

            // Set layer size and text attributes
            layer.frame = CGRect(x: 100, y: 100, width: 60*5, height: 15*5)
            layer.fontSize = 30
            layer.foregroundColor = UIColor.white.cgColor
            layer.contentsScale = UIScreen.main.scale

            sceneView.layer.addSublayer(layer)
        }
        
        // last minute hack to add joke layer
        if _nameToLabelLayer["joke"] == nil {
            let layer = CATextLayer()
            _nameToLabelLayer["joke"] = layer
            layer.isHidden = true

            // Set layer size and text attributes
            layer.frame = CGRect(x: 10, y: 10, width: 100*5, height: 30*5)
            layer.fontSize = 24
            layer.foregroundColor = UIColor.green.cgColor
            layer.contentsScale = UIScreen.main.scale

            sceneView.layer.addSublayer(layer)
        }


        // Get layer for this name
        guard let layer = _nameToLabelLayer[name] else { return }
        guard let jokeLayer = _nameToLabelLayer["joke"] else { return }


        // hack to add metadataa
        if name == "travis" {
            layer.string = name + "\nFounding Solutions\nArchitect\nTwelve Labs"
            jokeLayer.string = "Icebreaker Joke:\nDoes Twelve Labs have a \n secret 13th lab for extra luck?"
            jokeLayer.isHidden = false
        } else {
            layer.string = name + "\n❤️"
        }
        // Set name
        layer.frame = CGRect(x: face.boundingBox.minX-50, y: face.boundingBox.minY+10, width: 60*5, height: 20*10)
        layer.isHidden = false  // show
    }

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
