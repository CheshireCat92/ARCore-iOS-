//
//  SceneWithCameraViewController.swift
//  NFC Test
//
//  Created by AK on 12.12.2019.
//  Copyright © 2019 AK. All rights reserved.
//

import UIKit
import ARKit
import ARCore
import CoreMotion

class SceneWithCameraViewController: UIViewController {

    private var kCameraZNear = CGFloat(0.01)
    private var kCameraZFar = CGFloat(100)
    private var rotation: UInt = 0
    @IBOutlet weak var sceneView: SCNView!
    private var captureDevice: AVCaptureDevice?
    private var captureSession: AVCaptureSession?
    private var cameraImageLayer: CALayer?

    private let kCentimetersToMeters: Float = 0.01
    private lazy var faceMeshConverter = FaceMeshGeometryConverter()
    private lazy var sceneCamera = SCNCamera()
    private lazy var faceNode = SCNNode()
    private lazy var faceTextureNode = SCNNode()
    private lazy var faceOccluderNode = SCNNode()
    private var faceTextureMaterial = SCNMaterial()
    private var faceOccluderMaterial = SCNMaterial()
    private var noseTipNode: SCNNode?
    private var foreheadLeftNode: SCNNode?
    private var foreheadRightNode: SCNNode?

    // MARK: - Motion properties

    private let kMotionUpdateInterval: TimeInterval = 0.1
    private lazy var motionManager = CMMotionManager()

    // MARK: - Face Session properties

    private var faceSession : GARAugmentedFaceSession?
    private var currentFaceFrame: GARAugmentedFaceFrame?
    private var nextFaceFrame: GARAugmentedFaceFrame?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.


        //        sceneView.scene = SCNScene()


        //        sceneView.backgroundColor = .clear


        setupScene()
        setupCamera()
        setupMotion()

        do {
            let fieldOfView = captureDevice?.activeFormat.videoFieldOfView ?? 0
            faceSession = try GARAugmentedFaceSession(fieldOfView: fieldOfView)
            faceSession?.delegate = self
        } catch let error as NSError {
            NSLog("Failed to initialize Face Session with error: %@", error.description)
        }

    }

    private func setupScene() {
        guard let faceImage = UIImage(named: "Models.scnassets/face_texture.png"),
            let scene = SCNScene(named: "Models.scnassets/fox_face.scn"),
            let modelRoot = scene.rootNode.childNode(withName: "asset", recursively: false)
            else {
                NSLog("Failed to load face scene!")
                return
        }

        // SceneKit uses meters for units, while the canonical face mesh asset uses centimeters.
        modelRoot.simdScale = simd_float3(1, 1, 1) * kCentimetersToMeters
        foreheadLeftNode = modelRoot.childNode(withName: "FOREHEAD_LEFT", recursively: true)
        foreheadRightNode = modelRoot.childNode(withName: "FOREHEAD_RIGHT", recursively: true)
        noseTipNode = modelRoot.childNode(withName: "NOSE_TIP", recursively: true)

        faceNode.addChildNode(faceTextureNode)
        faceNode.addChildNode(faceOccluderNode)
        scene.rootNode.addChildNode(faceNode)

        let cameraNode = SCNNode()
        cameraNode.camera = sceneCamera
        //        cameraNode.camera?.fieldOfView = CGFloat(180)
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 0)
        scene.rootNode.addChildNode(cameraNode)


        sceneView.scene = scene
        //        sceneView.frame = view.bounds
        sceneView.delegate = self
        sceneView.allowsCameraControl = true
        sceneView.rendersContinuously = true
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.backgroundColor = .clear

        faceTextureMaterial.diffuse.contents = faceImage
        // SCNMaterial does not premultiply alpha even with blendMode set to alpha, so do it manually.
        faceTextureMaterial.shaderModifiers =
            [SCNShaderModifierEntryPoint.fragment : "_output.color.rgb *= _output.color.a;"]
        faceOccluderMaterial.colorBufferWriteMask = []
    }

    private func setupCamera() {
        let position = AVCaptureDevice.Position.front
        guard let device =
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device)
            else {
                print("Failed to create capture device from front camera.")
                return
        }



        let output = AVCaptureVideoDataOutput()
        //        if UIScreen.main.traitCollection.displayGamut
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInteractive))

        let session = AVCaptureSession()
        session.sessionPreset = .high
        session.addInput(input)
        session.addOutput(output)

        let connection = output.connection(with: .video)
        connection?.videoOrientation = .portrait
        connection?.isVideoMirrored = true

        captureSession = session
        captureDevice = device

        cameraImageLayer = CALayer()
        cameraImageLayer?.bounds = sceneView.bounds
        cameraImageLayer?.contentsFormat = .RGBA16Float
        cameraImageLayer?.anchorPoint = CGPoint(x: 0, y: 1)
        sceneView.scene?.background.contents = cameraImageLayer
        startCameraCapture()
    }

    private func startCameraCapture() {
        getVideoPermission(permissionHandler: { granted in
            guard granted else {
                NSLog("Permission not granted to use camera.")
                return
            }
            self.captureSession?.startRunning()
        })
    }

    private func setupMotion() {
        guard motionManager.isDeviceMotionAvailable else {
            NSLog("Device does not have motion sensors.")
            return
        }
        motionManager.deviceMotionUpdateInterval = kMotionUpdateInterval
        motionManager.startDeviceMotionUpdates()
    }

    private func getVideoPermission(permissionHandler: @escaping (Bool) -> ()) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionHandler(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: permissionHandler)
        default:
            permissionHandler(false)
        }
    }
    /*
     // MARK: - Navigation

     // In a storyboard-based application, you will often want to do a little preparation before navigation
     override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
     // Get the new view controller using segue.destination.
     // Pass the selected object to the new view controller.
     }
     */

    @IBAction func onSliderPositionChange(_ sender: UISlider) {
        rotation = UInt(sender.value)
    }


}

extension SceneWithCameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let deviceMotion = motionManager.deviceMotion {
            let frameTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

            //            let rotation =  2 * .pi - atan2(deviceMotion.gravity.x, deviceMotion.gravity.y) + .pi
            //            let rotationDegrees = (UInt)(rotation * 180 / .pi) % 360

            faceSession?.update(with: pBuffer, timestamp: frameTime, recognitionRotation: 0)
        }
    }
}

extension SceneWithCameraViewController: GARAugmentedFaceSessionDelegate {
    public func didUpdate(_ frame: GARAugmentedFaceFrame) {
        sceneCamera.projectionTransform = SCNMatrix4.init(
            frame.projectionMatrix(
                forViewportSize: sceneView.frame.size,
                presentationOrientation: .landscapeRight,
                mirrored: false,
                zNear: kCameraZNear,
                zFar: kCameraZFar)
        )

        nextFaceFrame = frame
    }
}

extension SceneWithCameraViewController: SCNSceneRendererDelegate {
    public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard nextFaceFrame != nil && nextFaceFrame != currentFaceFrame else { return }

        currentFaceFrame = nextFaceFrame

        if let face = currentFaceFrame?.face {
            let faceGeometry = faceMeshConverter.geometryFromFace(face)
            faceTextureNode.geometry = faceGeometry
            faceTextureNode.geometry?.firstMaterial = faceTextureMaterial
            //            faceTextureNode.geometry?.firstMaterial?.diffuse.contents = UIColor.red
            faceOccluderNode.geometry = faceGeometry?.copy() as? SCNGeometry
            faceOccluderNode.geometry?.firstMaterial = faceOccluderMaterial

            faceNode.simdWorldTransform = face.centerTransform
            let nodePos = faceNode.position

            updateTransform(face.transform(for: .nose), for: noseTipNode)
            updateTransform(face.transform(for: .foreheadLeft), for: foreheadLeftNode)
            updateTransform(face.transform(for: .foreheadRight), for: foreheadRightNode)
        }
        // Only show AR content when a face is detected
        sceneView.scene?.rootNode.isHidden = currentFaceFrame?.face == nil
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let frame = currentFaceFrame else {return}
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        self.cameraImageLayer?.contents = frame.capturedImage
        CATransaction.commit()
    }

    private func updateTransform(_ transform: simd_float4x4, for regionNode: SCNNode?) {
        guard let node = regionNode else { return }

        let localScale = node.simdScale
        node.simdWorldTransform = transform
        node.simdScale = localScale
        let nodePos = node.position
//        node.position = SCNVector3Make(nodePos.x, nodePos.y, -40)
        node.simdLocalRotate(by: simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0)))
        

    }
}
