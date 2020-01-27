//
//  ViewController.swift
//  TextDetector
//
//  Created by Tarek Sabry on 1/14/20.
//  Copyright © 2020 Tarek Sabry. All rights reserved.
//

import UIKit
import AVFoundation
import CoreVideo
import Firebase

infix operator ~~

extension CGFloat {
    
    static func ~~ (lhs: CGFloat, rhs: CGFloat) -> Bool {
        
        return abs(lhs - rhs) < 0.5
    }
}

extension CGFloat {
    func roundTo(places: Int) -> CGFloat {
        let divisor = pow(10.0, CGFloat(places))
        return (self * divisor).rounded() / divisor
    }
}
struct Line {
    let text: String
    var row: CGFloat
    let frame: CGRect
    let cornerPoints: [NSValue]?
    let elements: [VisionTextElement]
    var isExcluded: Bool
}

class ViewController: UIViewController {
    
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private lazy var captureSession = AVCaptureSession()
    private lazy var sessionQueue = DispatchQueue(label: Constant.sessionQueueLabel)
    private lazy var vision = Vision.vision()
    private var lastFrame: CMSampleBuffer?
    private var captureDevice: AVCaptureDevice!
    var tableView: UIView?
    
    private lazy var previewOverlayView: UIImageView = {
        precondition(isViewLoaded)
        let previewOverlayView = UIImageView(frame: .zero)
        previewOverlayView.contentMode = UIView.ContentMode.scaleAspectFill
        previewOverlayView.translatesAutoresizingMaskIntoConstraints = false
        return previewOverlayView
    }()
    
    private lazy var annotationOverlayView: UIView = {
        precondition(isViewLoaded)
        let annotationOverlayView = UIView(frame: .zero)
        annotationOverlayView.translatesAutoresizingMaskIntoConstraints = false
        return annotationOverlayView
    }()
    
    private var recognizableWords = [
        "calories",
        "sugar",
        "fat",
        "saturated",
        "salt",
        "serving",
        "energy",
        "nutrition",
        "facts"
    ]
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        self.view.layer.addSublayer(previewLayer)
        setupCaptureSessionOutput()
        setupCaptureSessionInput()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        startSession()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        stopSession()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.frame
    }
    
    private func recognizeTextOnDevice(in image: VisionImage, width: CGFloat, height: CGFloat) {
        let textRecognizer = vision.onDeviceTextRecognizer()
        textRecognizer.process(image) { text, error in
            self.removeDetectionAnnotations()
            self.tableView?.removeFromSuperview()
            guard error == nil, let text = text else {
                return
            }
            
            var lines = [Line]()
            
            text
                .blocks
                .flatMap { $0.lines }
                .forEach { line in
                    let text = line.elements.map { $0.text }.joined(separator: " ")
                    let x = line.elements.map { $0.frame.origin.x }.min() ?? 0.0
                    let y = line.elements.map { $0.frame.origin.y }.min() ?? 0.0
                    let widthSum = line.elements.map { $0.frame.width }.reduce(0, +)
                    let heightSum = line.elements.map { $0.frame.height }.reduce(0, +)
                    let line = Line(text: text, row: -1, frame: .init(x: x, y: y, width: widthSum, height: heightSum), cornerPoints: line.cornerPoints, elements: line.elements, isExcluded: false)
                    lines.append(line)
            }
            
            
            var averageSum = lines
                .map { element in
                    element.frame.width
            }.reduce(0, +)
            
            averageSum = averageSum / CGFloat(lines.count)
            
            for (index, line) in lines.enumerated() {
                lines[index].row = ((line.frame.width / 2 + line.frame.origin.x) / averageSum).roundTo(places: 2)
                if !self.recognizableWords.contains(where: { word in line.text.lowercased().contains(word) }) {
                    lines[index].isExcluded = true
                }
            }
            
            for (index, line) in lines.enumerated() {
                if !line.text.isEmpty, String(line.text.first!).rangeOfCharacter(from: CharacterSet.decimalDigits) != nil && lines.filter({
                    let almostEqual = $0.row ~~ line.row
                    if almostEqual && $0.isExcluded == false && $0.text != line.text {
                        return true
                    }
                    return false
                }).count > 0 {
                    lines[index].isExcluded = false
                }
            }
            
            for line in lines where !line.isExcluded {
                let points = self.convertedPoints(from: line.cornerPoints, width: width, height: height)
                UIUtilities.addShape(withPoints: points, to: self.view, color: .green)
            }
            
            lines
                .filter { !$0.isExcluded }
                .flatMap { $0.elements }
                .forEach { element in
                    let normalizedRect = CGRect(
                        x: element.frame.origin.x / width,
                        y: element.frame.origin.y / height,
                        width: element.frame.size.width / width,
                        height: element.frame.size.height / height
                    )
                    
                    let convertedRect = self.previewLayer.layerRectConverted(
                        fromMetadataOutputRect: normalizedRect
                    )
                    
                    let label = UILabel(frame: convertedRect)
                    label.text = element.text
                    label.font = .systemFont(ofSize: 14, weight: .regular)
                    label.adjustsFontSizeToFitWidth = true
                    label.restorationIdentifier = "detectedText"
                    self.view.addSubview(label)
            }
            
            self.createTableView(with: lines.filter({ !$0.isExcluded }))
        }
    }
    
    // MARK: - Private
    
    private func setupCaptureSessionOutput() {
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high
            
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA,
            ]
            let outputQueue = DispatchQueue(label: Constant.videoDataOutputQueueLabel)
            output.setSampleBufferDelegate(self, queue: outputQueue)
            guard self.captureSession.canAddOutput(output) else {
                print("Failed to add capture session output.")
                return
            }
            self.captureSession.addOutput(output)
            self.captureSession.commitConfiguration()
        }
    }
    
    private func setupCaptureSessionInput() {
        sessionQueue.async {
            let cameraPosition: AVCaptureDevice.Position = .back
            guard let device = self.captureDevice(forPosition: cameraPosition) else {
                print("Failed to get capture device for camera position: \(cameraPosition)")
                return
            }
            self.captureDevice = device
            do {
                self.captureSession.beginConfiguration()
                let currentInputs = self.captureSession.inputs
                for input in currentInputs {
                    self.captureSession.removeInput(input)
                }
                
                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else {
                    print("Failed to add capture session input.")
                    return
                }
                self.captureSession.addInput(input)
                self.captureSession.commitConfiguration()
            } catch {
                print("Failed to create capture device input: \(error.localizedDescription)")
            }
        }
    }
    
    private func startSession() {
        sessionQueue.async {
            self.captureSession.startRunning()
        }
    }
    
    private func stopSession() {
        sessionQueue.async {
            self.captureSession.stopRunning()
        }
    }
    
    private func captureDevice(forPosition position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices.first { $0.position == position }
    }
    
    private func removeDetectionAnnotations() {
        for view in view.subviews where view.restorationIdentifier == "shapeView" || view.restorationIdentifier == "detectedText" {
            view.removeFromSuperview()
        }
    }
    
    
    private func convertedPoints(
        from points: [NSValue]?,
        width: CGFloat,
        height: CGFloat
    ) -> [NSValue]? {
        return points?.map {
            let cgPointValue = $0.cgPointValue
            let normalizedPoint = CGPoint(x: cgPointValue.x / width, y: cgPointValue.y / height)
            let cgPoint = previewLayer.layerPointConverted(fromCaptureDevicePoint: normalizedPoint)
            let value = NSValue(cgPoint: cgPoint)
            return value
        }
    }
    
    private func normalizedPoint(
        fromVisionPoint point: VisionPoint,
        width: CGFloat,
        height: CGFloat
    ) -> CGPoint {
        let cgPoint = CGPoint(x: CGFloat(point.x.floatValue), y: CGFloat(point.y.floatValue))
        var normalizedPoint = CGPoint(x: cgPoint.x / width, y: cgPoint.y / height)
        normalizedPoint = previewLayer.layerPointConverted(fromCaptureDevicePoint: normalizedPoint)
        return normalizedPoint
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        
        let bounds = UIScreen.main.bounds
        
        let touchPoint = touches.first! as UITouch
        let screenSize = bounds.size
        let focusPoint = CGPoint(x: touchPoint.location(in: view).y / screenSize.height, y: 1.0 - touchPoint.location(in: view).x / screenSize.width)
        
        if let device = AVCaptureDevice.default(for:AVMediaType.video) {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = focusPoint
                    device.focusMode = AVCaptureDevice.FocusMode.autoFocus
                }
                device.unlockForConfiguration()
                
            } catch {
                // Handle errors here
                print("There was an error focusing the device's camera")
            }
        }
    }
    
    func createTableView(with detectedLines: [Line]) {
        guard detectedLines.count != 0 else { return }
        tableView = UIView()
        let stackView = UIStackView()
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        tableView?.backgroundColor = .black
        tableView?.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView!)
        tableView?.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            tableView!.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            tableView!.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView!.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor)
        ])
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: tableView!.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: tableView!.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: tableView!.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: tableView!.bottomAnchor)
        ])
        
        
        let rows = detectedLines.map { $0.row }
        var groupedLines = [CGFloat: [String]]()
        
        for row in rows {
            for line in detectedLines {
                let isAlmostEqual = line.row ~~ row
                if isAlmostEqual && groupedLines.values.flatMap({ $0 }).contains(line.text) == false {
                    if groupedLines[row] == nil {
                        groupedLines[row] = [line.text]
                    } else {
                        groupedLines[row]?.append(line.text)
                    }
                }
            }
        }
        
        for (_, texts) in groupedLines.sorted(by: { $0.key < $1.key }) {
            let horizontalStackView = UIStackView()
            horizontalStackView.spacing = 8
            horizontalStackView.distribution = .fillEqually
            for text in texts {
                let label = UILabel()
                label.textColor = .white
                label.text = text
                horizontalStackView.addArrangedSubview(label)
            }
            stackView.addArrangedSubview(horizontalStackView)
        }
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to get image buffer from sample buffer.")
            return
        }
        
        lastFrame = sampleBuffer
        let visionImage = VisionImage(buffer: sampleBuffer)
        let metadata = VisionImageMetadata()
        let orientation = UIUtilities.imageOrientation(fromDevicePosition: .back)
        
        let visionOrientation = UIUtilities.visionImageOrientation(from: orientation)
        metadata.orientation = visionOrientation
        visionImage.metadata = metadata
        let imageWidth = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        recognizeTextOnDevice(in: visionImage, width: imageWidth, height: imageHeight)
        
    }
}

private enum Constant {
    static let videoDataOutputQueueLabel = "com.google.firebaseml.visiondetector.VideoDataOutputQueue"
    static let sessionQueueLabel = "com.google.firebaseml.visiondetector.SessionQueue"
    static let noResultsMessage = "No Results"
    static let originalScale: CGFloat = 1.0
}
