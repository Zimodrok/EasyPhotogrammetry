import Foundation
import Network
import AppleArchive
import System

// MARK: - Archive Utilities
@available(iOS 14.0, macOS 11.0, *)
enum ArchiveHelper {
    static func zip(directory: URL, to: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: to.path) {
            try fileManager.removeItem(at: to)
        }
        
        let sourcePath = FilePath(directory.path)
        let destPath = FilePath(to.path)
        
        guard let writeStream = ArchiveByteStream.fileStream(
            path: destPath,
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw NSError(domain: "Archive", code: 1, userInfo: nil) }
        defer { try? writeStream.close() }
        
        guard let encodeStream = ArchiveByteStream.compressionStream(
            using: .lzfse,
            writingTo: writeStream
        ) else { throw NSError(domain: "Archive", code: 2, userInfo: nil) }
        defer { try? encodeStream.close() }
        
        guard let encodeHeader = ArchiveStream.encodeStream(writingTo: encodeStream) else { throw NSError(domain: "Archive", code: 3, userInfo: nil) }
        defer { try? encodeHeader.close() }
        
        try encodeHeader.writeDirectoryContents(
            archiveFrom: sourcePath,
            keySet: ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM")!
        )
    }
    
    static func unzip(file: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        
        let sourcePath = FilePath(file.path)
        let destPath = FilePath(directory.path)
        
        guard let readStream = ArchiveByteStream.fileStream(
            path: sourcePath,
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw NSError(domain: "Archive", code: 4, userInfo: nil) }
        defer { try? readStream.close() }
        
        guard let decodeStream = ArchiveByteStream.decompressionStream(readingFrom: readStream) else { throw NSError(domain: "Archive", code: 5, userInfo: nil) }
        defer { try? decodeStream.close() }
        
        guard let decodeHeader = ArchiveStream.decodeStream(readingFrom: decodeStream) else { throw NSError(domain: "Archive", code: 6, userInfo: nil) }
        defer { try? decodeHeader.close() }
        
        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: destPath,
            flags: [.ignoreOperationNotPermitted]
        ) else { throw NSError(domain: "Archive", code: 7, userInfo: nil) }
        defer { try? extractStream.close() }
        
        try ArchiveStream.process(readingFrom: decodeHeader, writingTo: extractStream)
    }
}

// MARK: - Transfer Engine (Network)
@MainActor
final class TransferEngine: ObservableObject {
    
    enum State: Equatable {
        case idle
        case advertising
        case searching
        case connected(peer: String)
        case transferring(progress: Double, detail: String)
        case processingOnMac
        case success
        case failed(String)
    }
    
    @Published var state: State = .idle
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    
    private let serviceType = "_macvision._tcp"
    private var activeReceiveFile: URL?
    private var incomingDataBuffer = Data()
    private var expectedLength: UInt64 = 0
    
    // Server setup callback when file is completely received
    var onFileReceived: ((URL) -> Void)?
    var onModelReceived: ((URL) -> Void)?
    
    // MARK: - Mac Node (Server)
    
    func startMacServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            
            let newListener = try NWListener(using: parameters)
            newListener.service = NWListener.Service(name: "MacVisionServer", type: serviceType)
            
            newListener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch newState {
                    case .ready:
                        self.state = .advertising
                        print("✅ Server successfully broadcasting Bonjour service.")
                    case .failed(let error):
                        print("❌ Bonjour Listener failed: \(error.localizedDescription)")
                        
                        if error.localizedDescription.contains("PolicyDenied") || error.localizedDescription.contains("EPERM") {
                            print(" Local network pending authorization. Retrying in 2 seconds...")
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                self.startMacServer()
                            }
                        } else {
                            self.state = .failed("Listener failed: \(error.localizedDescription)")
                        }
                    default:
                        break
                    }
                }
            }
            
            newListener.newConnectionHandler = { [weak self] newConnection in
                Task { @MainActor in
                    self?.accept(connection: newConnection)
                }
            }
            
            self.listener = newListener
            newListener.start(queue: .main)
        } catch {
            state = .failed("Failed to start server: \(error.localizedDescription)")
        }
    }

    private func accept(connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                switch newState {
                case .ready:
                    self?.state = .connected(peer: "iOS Client")
                    self?.receiveMetadata() // Start listening loop
                case .failed(let error):
                    self?.state = .failed("Connection lost: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }
    
    // MARK: - iOS Node (Client)
    
    func connectToMac() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: parameters)
        browser?.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                if case .ready = newState {
                    self?.state = .searching
                    
                    // 10 second timeout if Mac isn't found
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        if self?.state == .searching {
                            self?.state = .failed("Could not find Mac. Ensure MacVisionBuilder is open and on the exact same Wi-Fi or USB connection.")
                            self?.browser?.cancel()
                        }
                    }
                }
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let result = results.first else { return }
            Task { @MainActor in
                self?.connect(to: result.endpoint)
            }
        }
        
        browser?.start(queue: .main)
        state = .searching
    }
    
    private func connect(to endpoint: NWEndpoint) {
        browser?.cancel()
        browser = nil
        
        let parameters = NWParameters.tcp
        connection = NWConnection(to: endpoint, using: parameters)
        connection?.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                switch newState {
                case .ready:
                    self?.state = .connected(peer: "Mac Server")
                    self?.receiveMetadata() // iOS also needs to receive the USDZ later
                case .failed(let error):
                    self?.state = .failed("Connection failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection?.start(queue: .main)
    }
    
    // MARK: - Sending
    
    func send(fileURL: URL, contextTag: String) {
        guard let connection = connection, connection.state == .ready else {
            state = .failed("Not connected")
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            // Header: 8 bytes for data length + 1 byte for tag size + N bytes for tag
            let tagData = contextTag.data(using: .utf8)!
            var length = UInt64(data.count).littleEndian
            var tagLength = UInt8(tagData.count)
            
            var header = Data()
            withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
            header.append(tagLength)
            header.append(tagData)
            
            // Send Header
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    Task { @MainActor in self?.state = .failed(error.localizedDescription) }
                    return
                }
                
                // Send Payload
                Task { @MainActor in self?.state = .transferring(progress: 0.1, detail: "Sending \(contextTag)...") }
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        if let error = error {
                            self?.state = .failed(error.localizedDescription)
                        } else {
                            if contextTag == "payload.zip" {
                                self?.state = .processingOnMac
                            } else if contextTag.hasPrefix("chunk:") {
                                // Chunk streamer will handle transition, don't change state here
                            } else {
                                self?.state = .success
                            }
                        }
                    }
                })
            })
        } catch {
            state = .failed("File read failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - ACK Handshake & Chunk Streaming Support
    
    func sendAck(tag: String) {
        guard let connection = connection, connection.state == .ready else { return }
        let ackData = Data([1]) // 1-byte dummy payload
        var length = UInt64(ackData.count).littleEndian
        let tagData = tag.data(using: .utf8)!
        var tagLength = UInt8(tagData.count)
        
        var header = Data()
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(tagLength)
        header.append(tagData)
        
        connection.send(content: header, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Failed to send ACK header: \(error.localizedDescription)")
                return
            }
            connection.send(content: ackData, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send ACK payload: \(error.localizedDescription)")
                } else {
                    print(" Sent ACK: \(tag)")
                }
            })
        })
    }
    
    private var ackContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private let ackLock = NSLock()
    
    func waitForAck(chunkIndex: Int, sessionID: String) async {
        let key = "\(chunkIndex):\(sessionID)"
        await withCheckedContinuation { continuation in
            ackLock.lock()
            ackContinuations[key] = continuation
            ackLock.unlock()
        }
    }
    
    func resumeForAck(chunkIndex: Int, sessionID: String) {
        let key = "\(chunkIndex):\(sessionID)"
        ackLock.lock()
        if let continuation = ackContinuations.removeValue(forKey: key) {
            continuation.resume()
        }
        ackLock.unlock()
    }
    
    func startChunkedUpload(imagesDirectory: URL, sessionID: String) async {
        let fm = FileManager.default
        
        // Gather all captured images in imagesDirectory
        guard let files = try? fm.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            state = .failed("Failed to read session directory")
            return
        }
        
        let imageExtensions = Set(["jpg", "jpeg", "heic", "heif", "png"])
        let imageFiles = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                              .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        
        if imageFiles.isEmpty {
            state = .failed("No images found to transfer")
            return
        }
        
        // Group images into batches of 50
        let batchSize = 50
        let totalChunks = Int(ceil(Double(imageFiles.count) / Double(batchSize)))
        
        print(" Starting Chunked Streamed Transfer: \(imageFiles.count) images in \(totalChunks) chunks")
        
        for chunkIndex in 0..<totalChunks {
            let start = chunkIndex * batchSize
            let end = min(start + batchSize, imageFiles.count)
            let chunkImages = Array(imageFiles[start..<end])
            
            // Collect all files related to this chunk
            var chunkFiles: [URL] = []
            for imgURL in chunkImages {
                chunkFiles.append(imgURL)
                
                // Match depth data sidecars in depth/
                let baseName = imgURL.deletingPathExtension().lastPathComponent
                let depthDir = imagesDirectory.appendingPathComponent("depth")
                
                let cameraURL = depthDir.appendingPathComponent("\(baseName)_camera.json")
                if fm.fileExists(atPath: cameraURL.path) { chunkFiles.append(cameraURL) }
                
                let depthBinURL = depthDir.appendingPathComponent("\(baseName)_depth.bin")
                if fm.fileExists(atPath: depthBinURL.path) { chunkFiles.append(depthBinURL) }
                
                let confBinURL = depthDir.appendingPathComponent("\(baseName)_confidence.bin")
                if fm.fileExists(atPath: confBinURL.path) { chunkFiles.append(confBinURL) }
            }
            
            // If it is the last chunk, append session metadata and structural RoomPlan/LiDAR files
            let isLast = chunkIndex == totalChunks - 1
            if isLast {
                let structuralNames = ["roomplan.json", "roomplan.usdz", "roomplan.usdz", "lidar.usdz", "metadata.json"]
                for name in structuralNames {
                    let fileURL = imagesDirectory.appendingPathComponent(name)
                    if fm.fileExists(atPath: fileURL.path) {
                        chunkFiles.append(fileURL)
                    }
                }
            }
            
            // Create a temporary batch folder to zip
            let batchDir = fm.temporaryDirectory.appendingPathComponent("batch_\(sessionID)_\(chunkIndex)")
            try? fm.removeItem(at: batchDir)
            try? fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
            
            // Copy files to batchDir, preserving depth/ subfolder
            for fileURL in chunkFiles {
                let isDepthFile = fileURL.path.contains("/depth/")
                let destDir = isDepthFile ? batchDir.appendingPathComponent("depth") : batchDir
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                
                let destURL = destDir.appendingPathComponent(fileURL.lastPathComponent)
                try? fm.copyItem(at: fileURL, to: destURL)
            }
            
            // Zip the batch directory
            let zipURL = fm.temporaryDirectory.appendingPathComponent("chunk_\(sessionID)_\(chunkIndex).zip")
            try? fm.removeItem(at: zipURL)
            
            do {
                try ArchiveHelper.zip(directory: batchDir, to: zipURL)
                
                let progress = Double(chunkIndex) / Double(totalChunks)
                self.state = .transferring(
                    progress: progress,
                    detail: "Transferring chunk \(chunkIndex + 1)/\(totalChunks)..."
                )
                
                // Send over network
                let tag = "chunk:\(chunkIndex):\(totalChunks):\(sessionID)"
                self.send(fileURL: zipURL, contextTag: tag)
                
                // Wait for Mac Acknowledgement (ACK)
                print("⏳ Waiting for ACK on chunk \(chunkIndex)")
                await self.waitForAck(chunkIndex: chunkIndex, sessionID: sessionID)
                print("✅ Received ACK on chunk \(chunkIndex)!")
                
                // ACK received! Keep the original files on the iPhone so they are never lost.
                
                // Clean up temp batch folder and zip
                try? fm.removeItem(at: batchDir)
                try? fm.removeItem(at: zipURL)
                
            } catch {
                print("❌ Chunk transfer failed at index \(chunkIndex): \(error.localizedDescription)")
                self.state = .failed("Chunk transfer failed: \(error.localizedDescription)")
                return
            }
        }
        
        // All chunks sent and acknowledged!
        self.state = .processingOnMac
    }
    
    // MARK: - Receiving
    
    private func receiveMetadata() {
        guard let connection = connection else { return }
        
        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self = self, let data = data else { return }
                
                let lengthUInt64 = data.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
                self.expectedLength = lengthUInt64
                let tagLen = data[8]
                
                self.connection?.receive(minimumIncompleteLength: Int(tagLen), maximumLength: Int(tagLen)) { [weak self] tagData, _, _, _ in
                    Task { @MainActor in
                        guard let self = self, let tagData = tagData, let tagText = String(data: tagData, encoding: .utf8) else { return }
                        
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        self.activeReceiveFile = tempURL
                        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                        
                        self.state = .transferring(progress: 0.0, detail: "Receiving \(tagText)...")
                        self.receivePayloadChunk(receivedSoFar: 0, tag: tagText)
                    }
                }
            }
        }
    }
    
    private func receivePayloadChunk(receivedSoFar: UInt64, tag: String) {
        guard let connection = connection, let fileURL = activeReceiveFile else { return }
        
        let remaining = expectedLength - receivedSoFar
        let maxChunk = min(remaining, UInt64(10 * 1024 * 1024))
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: Int(maxChunk)) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self, let data = data else { return }
                
                if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
                
                let current = receivedSoFar + UInt64(data.count)
                self.state = .transferring(progress: Double(current) / Double(self.expectedLength), detail: "Receiving \(current / 1_000_000) MB...")
                
                if current >= self.expectedLength {
                    if tag == "payload.zip" {
                        self.state = .processingOnMac
                        self.onFileReceived?(fileURL)
                    } else if tag == "model.usdz" {
                        self.state = .success
                        self.onModelReceived?(fileURL)
                    } else if tag.hasPrefix("chunk:") {
                        // Tag format: "chunk:\(i):\(K):\(sessionID)"
                        let parts = tag.components(separatedBy: ":")
                        if parts.count >= 4 {
                            let chunkIndex = Int(parts[1]) ?? 0
                            let totalChunks = Int(parts[2]) ?? 1
                            let sessionID = parts[3]
                            
                            let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID)
                            
                            // Unzip chunk to session directory
                            print(" Received chunk \(chunkIndex + 1)/\(totalChunks) for session \(sessionID). Unzipping...")
                            do {
                                try ArchiveHelper.unzip(file: fileURL, to: sessionDir)
                            } catch {
                                print("❌ Failed to unzip chunk \(chunkIndex): \(error.localizedDescription)")
                            }
                            try? FileManager.default.removeItem(at: fileURL) // clean up temp zip file
                            
                            // Send ACK back to iPhone
                            self.sendAck(tag: "chunk_ack:\(chunkIndex):\(sessionID)")
                            
                            // If this was the last chunk, trigger processing!
                            if chunkIndex == totalChunks - 1 {
                                print(" All \(totalChunks) chunks received for session \(sessionID)!")
                                self.state = .processingOnMac
                                self.onFileReceived?(sessionDir)
                            }
                        }
                    } else if tag.hasPrefix("chunk_ack:") {
                        // Tag format: "chunk_ack:\(i):\(sessionID)"
                        let parts = tag.components(separatedBy: ":")
                        if parts.count >= 3 {
                            let chunkIndex = Int(parts[1]) ?? 0
                            let sessionID = parts[2]
                            print(" Received ACK for chunk \(chunkIndex) of session \(sessionID)")
                            self.resumeForAck(chunkIndex: chunkIndex, sessionID: sessionID)
                        }
                        try? FileManager.default.removeItem(at: fileURL) // clean up temp ACK payload
                    }
                    self.receiveMetadata()
                } else {
                    self.receivePayloadChunk(receivedSoFar: current, tag: tag)
                }
            }
        }
    }
    
    // Lifecycle
    func stop() {
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        state = .idle
    }
}
