//
//  GameViewController.swift
//  3D Image Capture V1
//
//  Created by Taylor Hinchliffe on 11/3/24.
//

import Cocoa
import SceneKit
import QuartzCore   // for animations
import AVFoundation

class GameViewController: NSViewController {

    var scene: SCNScene!
    var scnView: SCNView!
    var cameraNode: SCNNode!
    var depthData: AVDepthData!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create a new scene
        scene = SCNScene()

        // Create and add a camera to the scene
        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)

        // Create and configure the SCNView
        scnView = SCNView(frame: self.view.bounds)
        scnView.autoresizingMask = [.width, .height]
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.showsStatistics = true
        scnView.backgroundColor = NSColor.black

        // Add the SCNView to the main view
        self.view.addSubview(scnView)

        // Add a click gesture recognizer
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        scnView.addGestureRecognizer(clickGesture)

        // Create the load photo button
        let loadPhotoButton = NSButton(title: "Load Photo", target: self, action: #selector(loadPhotoButtonClicked))
        loadPhotoButton.frame = CGRect(x: 20, y: 20, width: 100, height: 30)
        loadPhotoButton.bezelStyle = .rounded

        // Add the button to the main view
        self.view.addSubview(loadPhotoButton)
    }

    @objc func handleClick(_ gestureRecognizer: NSGestureRecognizer) {
        // ... existing code ...
    }

    @objc func loadPhotoButtonClicked() {
        requestPhotoLibraryAccessAndLoadPhoto()
    }

    func requestPhotoLibraryAccessAndLoadPhoto() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.title = "Select a Photo"
        
        openPanel.begin { [weak self] result in
            if result == .OK, let url = openPanel.url {
                self?.loadAndDisplayImageWithSquares(from: url)
            }
        }
    }

    func loadAndDisplayImageWithSquares(from url: URL) {
        
        // Added imageSource (before loading image) to capture depth data
        DispatchQueue.main.async {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                print("Failed to create image source from URL.")
                return
            }

            // Extract depth data
            var depthData: AVDepthData? = nil
            if let auxDataInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeDisparity) as? [AnyHashable: Any] {
                do {
                    // Looks for disparity data
                    let disparityData = try AVDepthData(fromDictionaryRepresentation: auxDataInfo)
                    // Convert disparity data to depth data
                    depthData = disparityData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
                    print("Disparity data converted to depth data.")
                } catch {
                    print("Failed to create AVDepthData from disparity data: \(error)")
                }
                // Otherwise checks for depth data in the kCVPixelFormatType_DepthFloat32 format
            } else if let auxDataInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeDepth) as? [AnyHashable: Any] {
                do {
                    depthData = try AVDepthData(fromDictionaryRepresentation: auxDataInfo)
                    if depthData?.depthDataType != kCVPixelFormatType_DepthFloat32 {
                        depthData = depthData?.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
                    }
                    print("Depth data extracted.")
                } catch {
                    print("Failed to create AVDepthData from depth data: \(error)")
                }
            } else {
                print("No depth or disparity data found.")
            }

            guard let depthData = depthData else {
                print("No depth data available.")
                return
            }

            // Load the image
            guard let image = NSImage(contentsOf: url) else {
                print("Failed to load image from URL.")
                return
            }

            // Adjust camera settings based on image size
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
         //       let width = cgImage.width
         //       let height = cgImage.height

                // Switch back to perspective projection to better visualize depth
                self.cameraNode.camera?.usesOrthographicProjection = false
                self.cameraNode.camera?.orthographicScale = 1.0
                self.cameraNode.position = SCNVector3(x: 0, y: 0, z: 500)
                self.cameraNode.camera?.zNear = 1
                self.cameraNode.camera?.zFar = 10000
            }
            // Depth data passed to renderPixelSquares
            self.renderPixelSquares(from: image, depthData: depthData, step: 4) // Adjust step as needed
        }
    }
    
    
    

    func renderPixelSquares(from image: NSImage, depthData: AVDepthData, step: Int = 1) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data,
              let dataPointer = CFDataGetBytePtr(data) else {
            print("Failed to get image data.")
            return
        }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        // Parameters for square size
        let squareSize: Float = 1.0 // Adjust as needed

        var vertices: [Float] = []
        var colors: [Float] = []
        var indices: [UInt32] = []
        var currentIndex: UInt32 = 0

        // Remove existing nodes
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

        //Added depth information above x and y strides
        // Get depth pixel buffer
        let depthPixelBuffer = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer) else {
            print("Failed to get depth base address.")
            return
        }

        let depthWidth = CVPixelBufferGetWidth(depthPixelBuffer)
        let depthHeight = CVPixelBufferGetHeight(depthPixelBuffer)
    //    let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthPixelBuffer)
        let depthFloatBuffer = depthBaseAddress.assumingMemoryBound(to: Float32.self)

        // Compute minDepth and maxDepth
        var minDepth: Float = .greatestFiniteMagnitude
        var maxDepth: Float = .leastNormalMagnitude

        let depthCount = depthWidth * depthHeight
        for i in 0..<depthCount {
            let depthValue = depthFloatBuffer[i]
            if !depthValue.isFinite || depthValue <= 0 {
                continue
            }
            minDepth = min(minDepth, depthValue)
            maxDepth = max(maxDepth, depthValue)
        }

        print("Depth range: \(minDepth) to \(maxDepth)")

        // Scaling factors to map image coordinates to depth coordinates
        let scaleX = Float(depthWidth) / Float(imageWidth)
        let scaleY = Float(depthHeight) / Float(imageHeight)

        for y in stride(from: 0, to: imageHeight, by: step) {
            for x in stride(from: 0, to: imageWidth, by: step) {
                // Flip the y-axis
                let flippedY = imageHeight - y - 1

                // Adjust x and y
                let adjustedX = Float(x) - Float(imageWidth) / 2.0
                let adjustedY = Float(flippedY) - Float(imageHeight) / 2.0

                // Get pixel color
                let pixelIndex = x * bytesPerPixel + y * bytesPerRow

                // Ensure we don't read out of bounds
                if pixelIndex + 3 >= CFDataGetLength(data) {
                    continue
                }

                // Extract color components (assuming RGBA format)
                let r = Float(dataPointer[pixelIndex]) / 255.0
                let g = Float(dataPointer[pixelIndex + 1]) / 255.0
                let b = Float(dataPointer[pixelIndex + 2]) / 255.0
                let a = Float(dataPointer[pixelIndex + 3]) / 255.0 // Alpha channel

                // Get corresponding depth coordinates
                let depthX = Int(Float(x) * scaleX)
                let depthY = Int(Float(y) * scaleY)

                if depthX >= depthWidth || depthY >= depthHeight {
                    continue
                }

                let depthIndex = depthX + depthY * depthWidth
                let depthValue = depthFloatBuffer[depthIndex]

                // Skip invalid depth values
                if !depthValue.isFinite || depthValue <= 0 {
                    continue
                }

                // Normalize depth value
                let normalizedDepth = (depthValue - minDepth) / (maxDepth - minDepth)
                let depthScale: Float = 500.0 // Adjust as needed
                let scaledDepth = normalizedDepth * depthScale
                let zPos = -scaledDepth // Negative to match SceneKit coordinate system

                // Define the four corners of the square
                let halfSize = squareSize / 2.0

                let topLeft = SCNVector3(adjustedX - halfSize, adjustedY + halfSize, zPos)
                let topRight = SCNVector3(adjustedX + halfSize, adjustedY + halfSize, zPos)
                let bottomLeft = SCNVector3(adjustedX - halfSize, adjustedY - halfSize, zPos)
                let bottomRight = SCNVector3(adjustedX + halfSize, adjustedY - halfSize, zPos)

                // Append vertices
                vertices.append(contentsOf: [Float(topLeft.x), Float(topLeft.y), Float(topLeft.z)])
                vertices.append(contentsOf: [Float(bottomLeft.x), Float(bottomLeft.y), Float(bottomLeft.z)])
                vertices.append(contentsOf: [Float(topRight.x), Float(topRight.y), Float(topRight.z)])
                vertices.append(contentsOf: [Float(bottomRight.x), Float(bottomRight.y), Float(bottomRight.z)])

                // Append colors for each vertex (same color for all four vertices)
                for _ in 0..<4 {
                    colors.append(contentsOf: [r, g, b, a])
                }

                // Define two triangles for the square
                indices.append(contentsOf: [
                    currentIndex, currentIndex + 1, currentIndex + 2,
                    currentIndex + 2, currentIndex + 1, currentIndex + 3
                ])

                currentIndex += 4
            }
        }

        // Create geometry sources
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<Float>.size)
        let vertexSource = SCNGeometrySource(data: vertexData,
                                             semantic: .vertex,
                                             vectorCount: vertices.count / 3,
                                             usesFloatComponents: true,
                                             componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size,
                                             dataOffset: 0,
                                             dataStride: MemoryLayout<Float>.size * 3)

        // Create color source
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(data: colorData,
                                            semantic: .color,
                                            vectorCount: colors.count / 4,
                                            usesFloatComponents: true,
                                            componentsPerVector: 4, // RGBA
                                            bytesPerComponent: MemoryLayout<Float>.size,
                                            dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 4)

        // Create geometry element
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let geometryElement = SCNGeometryElement(data: indexData,
                                                 primitiveType: .triangles,
                                                 primitiveCount: indices.count / 3,
                                                 bytesPerIndex: MemoryLayout<UInt32>.size)

        // Create geometry with vertex and color sources
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [geometryElement])

        // Configure material to use vertex colors
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        material.locksAmbientWithDiffuse = true
        geometry.materials = [material]

        // Create node
        let node = SCNNode(geometry: geometry)

        // Add node to the scene
        scene.rootNode.addChildNode(node)
    }
    
    
    
}
