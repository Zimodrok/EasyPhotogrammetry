import SwiftUI
import RealityKit
import ARKit
import Photos
import QuickLook
import Combine
import PhotosUI
@preconcurrency import SceneKit
import SceneKit.ModelIO
import ModelIO
import Foundation
import UniformTypeIdentifiers

// MARK: - GLOBAL ENUMS & PROCESSORS

enum GalleryState: Equatable {
    case pickPhotos
    case processing(progress: Double)
    case completed(URL)
    case failed(String)
    case transferringToMac
    case macProcessing(progress: Double, detail: String)
    
    static func == (lhs: GalleryState, rhs: GalleryState) -> Bool {
        switch (lhs, rhs) {
        case (.pickPhotos, .pickPhotos): return true
        case (.processing(let a), .processing(let b)): return a == b
        case (.completed(let a), .completed(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        case (.transferringToMac, .transferringToMac): return true
        case (.macProcessing(let pa, _), .macProcessing(let pb, _)): return pa == pb
        default: return false
        }
    }
}

@MainActor
final class GalleryProcessor: ObservableObject {
    @Published var state: GalleryState = .pickPhotos
    @Published var selectedImages: [Data] = []
    @Published var selectedUIImages: [UIImage] = [] // For previewing only
    @Published var selectedQuality: ModelQuality = .reduced
    
    private var imagesDirectory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionScan_Gallery_\(sessionID)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private let sessionID = UUID().uuidString
    
    let engine = TransferEngine()
    
    init() {
        setupTransferEngine()
    }
    
    private func setupTransferEngine() {
        engine.onModelReceived = { [weak self] url in
            self?.state = .completed(url)
        }
    }
    
    func processSelectedPhotos() {
        guard !selectedImages.isEmpty else { return }
        
        state = .processing(progress: 0.0)
        
        let dir = imagesDirectory
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outputURL = docDir.appendingPathComponent("model.usdz")
        let images = selectedImages
        
        try? FileManager.default.removeItem(at: outputURL)
        
        Task {
            for (i, data) in images.enumerated() {
                let ext: String
                if data.count > 2 && data[0] == 0xFF && data[1] == 0xD8 {
                    ext = "jpg"
                } else if data.count > 8 &&
                          data[4] == 0x66 && data[5] == 0x74 &&
                          data[6] == 0x79 && data[7] == 0x70 {
                    ext = "heic"
                } else {
                    ext = "jpg"
                }
                let fileURL = dir.appendingPathComponent("photo_\(String(format: "%03d", i)).\(ext)")
                try? data.write(to: fileURL)
            }
            
            let result = await Self.runPhotogrammetry(
                imagesDirectory: dir,
                outputURL: outputURL,
                imageCount: images.count,
                detail: selectedQuality.detail,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.state = .processing(progress: fraction)
                    }
                }
            )
            
            if let url = result.url {
                state = .completed(url)
            } else {
                let msg = result.error ?? "Unknown error"
                state = .failed(msg)
            }
        }
    }
    
    func sendToMac() {
        guard !selectedImages.isEmpty else { return }
        state = .transferringToMac
        
        let dir = imagesDirectory
        let images = selectedImages
        
        Task {
            for (i, data) in images.enumerated() {
                let ext = (data.count > 2 && data[0] == 0xFF && data[1] == 0xD8) ? "jpg" : "heic"
                let fileURL = dir.appendingPathComponent("photo_\(String(format: "%03d", i)).\(ext)")
                try? data.write(to: fileURL)
            }
            
            await MainActor.run {
                engine.connectToMac()
                var cancellable: AnyCancellable?
                cancellable = engine.$state.sink { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .connected(_):
                        cancellable?.cancel()
                        Task {
                            await self.engine.startChunkedUpload(imagesDirectory: dir, sessionID: self.sessionID)
                        }
                    case .transferring(let p, let d):
                        self.state = .macProcessing(progress: p, detail: d)
                    case .failed(let e):
                        self.state = .failed("Mac transfer failed: \(e)")
                        cancellable?.cancel()
                    default: break
                    }
                }
                if let c = cancellable { self.cancellables.insert(c) }
            }
        }
    }
    private var cancellables = Set<AnyCancellable>()
    
    nonisolated static func runPhotogrammetry(
        imagesDirectory: URL,
        outputURL: URL,
        imageCount: Int,
        detail: RealityKit.PhotogrammetrySession.Request.Detail,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async -> (url: URL?, error: String?) {
        do {

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let room = RoomPhotogrammetry()
            try await room.process(
                imagesDirectory: imagesDirectory,
                outputURL: outputURL,
                onProgress: onProgress
            )
            
            // Wait for file system to flush
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            
            let exists = FileManager.default.fileExists(atPath: outputURL.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.size] as? Int ?? 0
            
            if exists && size > 0 {
                return (url: outputURL, error: nil)
            } else {
                return (url: nil, error: "Model file was not created. Take more overlapping photos from different angles.")
            }
        } catch {
            return (url: nil, error: error.localizedDescription)
        }
    }

    
    

    func reset() {
        state = .pickPhotos
        selectedImages.removeAll()
        selectedUIImages.removeAll()
        try? FileManager.default.removeItem(at: imagesDirectory)
    }
}

enum EditingTool: Equatable {
    case crop, wand, brush
}

enum DebugViewMode: String, CaseIterable {
    case result = "Result"
    case photogrammetry = "Photogrammetry"
    case lidarRoomScan = "LiDAR/RoomScan"
}


// MARK: - MAIN ENTRY CONTENT VIEW

struct ContentView: View {
    var body: some View {
        ToolsGridView()
    }
}

// MARK: - TOOLS GRID VIEW (MIGRATED CORES & NAVIGATION)

struct ToolsGridView: View {
        static let sampleData: [GridItemData] = [
            GridItemData(name: "Capture", status: "Room / Object", iconName: "camera.viewfinder", subOptions: [
                GridItemData(name: "Scan Room", status: "RoomPlan", iconName: "house.fill", subOptions: nil, targetViewId: "route_scan_room"),
                GridItemData(name: "Scan Object", status: "LiDAR", iconName: "cube.transparent", subOptions: nil, targetViewId: "route_scan_object"),
                GridItemData(name: "Connect to Mac", status: "How to connect Mac", iconName: "macbook", subOptions: nil, targetViewId: "action_connect_mac")
            ], targetViewId: nil),
            GridItemData(name: "Photogrammetry", status: "Build from Photos", iconName: "photo.on.rectangle.angled", subOptions: [
                GridItemData(name: "Select Photos", status: "Import", iconName: "photo.badge.plus", subOptions: nil, targetViewId: "action_select_photos"),
                GridItemData(name: "Generate on iPhone", status: "Local RealityKit", iconName: "iphone.circle", subOptions: nil, targetViewId: "action_generate_iphone"),
                GridItemData(name: "Send to Mac", status: "High Quality Mac", iconName: "macbook.and.iphone", subOptions: nil, targetViewId: "action_build_mac")
            ], targetViewId: nil),
            GridItemData(name: "Explore Room", status: "Bundled Model", iconName: "figure.walk", subOptions: nil, targetViewId: "route_explore_room"),
            GridItemData(name: "Tools", status: "Additional utilities", iconName: "gearshape.2.fill", subOptions: [
                GridItemData(name: "Measure Object", status: "AR Ruler", iconName: "ruler.fill", subOptions: nil, targetViewId: "route_measure"),
                GridItemData(name: "Reprocess Folder", status: "VisionScan Raw", iconName: "folder.fill.badge.gearshape", subOptions: nil, targetViewId: "action_reprocess_folder"),
                GridItemData(name: "Object Library", status: "TO BE SOON", iconName: "ruler.fill", subOptions: nil, targetViewId: "nil"),

                GridItemData(name: "Debug View", status: "Asset Asset", iconName: "cube.fill", subOptions: nil, targetViewId: "action_debug_asset")
            ], targetViewId: nil),
            GridItemData(name: "Debugging", status: "UI/Features Testing", iconName: "hammer.fill", subOptions: [
                GridItemData(name: "Test 3D Preview", status: "Bypass to Editor", iconName: "paintbrush.pointed.fill", subOptions: nil, targetViewId: "dev_bypass_to_preview"),
                GridItemData(name: "Test Review Sheet", status: "Bypass to Photos UI", iconName: "photo.stack", subOptions: nil, targetViewId: "dev_bypass_to_review"),
                GridItemData(name: "Test AR Completed", status: "Bypass to Done HUD", iconName: "checkmark.circle", subOptions: nil, targetViewId: "dev_bypass_to_completed")
            ], targetViewId: nil)
        ]
        
    @State private var currentItems: [GridItemData] = ToolsGridView.sampleData
    @State private var navigationHistory: [[GridItemData]] = []
    @State private var activeTargetViewId: String? = nil
    
    @StateObject private var processor = GalleryProcessor()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pressedItemId: UUID? = nil
    @State private var loadingPhotos = false
    @State private var showQuickLook = false
    @State private var modelURL: URL? = nil
    
    @EnvironmentObject var engine: TransferEngine
    
    @StateObject private var appState = AppState()
    @State private var showDevReviewSheet = false
    @State private var cleanModelActive = false
    @State private var activeTool: EditingTool = .wand
    @State private var debugViewMode: DebugViewMode = .result
    
    @State private var showARCapture = false
    @State private var showRoomScan = false
    @State private var showMeasure = false
    @State private var showExplorer = false
    @State private var showUSDZPicker = false
    @State private var showMacConnection = false
    @State private var explorerURL: URL? = nil
    
    @StateObject private var folderReprocessor = FolderReprocessor()
    @State private var showFolderPicker = false
    
    @State private var cropHeight: Float = 0
    @State private var cropInfo = ""
    @State private var yRange: (min: Float, max: Float) = (0, 1)
    @State private var showingCropped = false
    
    @State private var eraserSensitivity: Float = 0.10
    @State private var brushRadius: Float = 0.05
    @State private var unifiedUndoCount = 0
    
    @State private var calibrateScaleActive = false
    @State private var calibPointA: SCNVector3? = nil
    @State private var calibPointB: SCNVector3? = nil
    @State private var showCalibSheet = false
    @State private var calibInputText = ""
    @State private var modelScaleFactor: Float = 1.0
    @State private var modelBoundingBox: (w: Float, h: Float, d: Float)? = nil
    
    @State private var showPhotosPickerInline = false
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder
    private var darkModeAmbientBackground: some View {
        ZStack {
            Image("interior")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .overlay(Color.black.opacity(0.7))
            
            Color.white
                .mask(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black, location: 0.0),      .init(color: .black.opacity(0.85), location: 0.25),                           .init(color: .black.opacity(0.15), location: 0.45),                             .init(color: .clear, location: 0.60)                          ]),
                        center: .top,
                        startRadius: 0,
                        endRadius: 750
                    )
                )
                .ignoresSafeArea()
            
            GeometryReader { geo in
                Color.black
                    // Covers the top half of the screen space
                    .frame(height: geo.size.height * 0.45)
                    // Softens the bottom edge where it meets the image
                    .mask(
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: .black, location: 0.0),       // Intense, pure shine core
                                .init(color: .black.opacity(0.75), location: 0.35), // Holds brightness out further
                                .init(color: .clear, location: 0.38), // Hard, sharp threshold drop-off
                                .init(color: .black, location: 0.7)       // Quickly collapses into pure black
                            ]),
                            center: .top,
                            startRadius: 0,
                            endRadius: 750
                        )
                    )
            }
        }
        .ignoresSafeArea()
    }
    struct TactileButtonStyle: PrimitiveButtonStyle {
        @State private var isPressed = false
        
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.97 : 1.0)
                .opacity(isPressed ? 0.85 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
                .background(isPressed ? Color.blue : Color.green)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressed { isPressed = true }
                        }
                        .onEnded { _ in
                            isPressed = false
                            configuration.trigger()
                        }
                )
        }
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch processor.state {
            case .pickPhotos:
                galleryPickerView
            case .processing(let progress):
                ProcessingView(progress: progress)
            case .transferringToMac:
                ProcessingView(progress: 0.1)
            case .macProcessing(let progress, let detail):
                VStack(spacing: 20) {
                    ProgressView(value: progress)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    Text(detail)
                        .font(.headline)
                        .foregroundColor(.white)
                }
            case .completed(let url):
                ModelPreviewView(
                    url: url,
                    processor: processor,
                    cleanModelActive: $cleanModelActive,
                    activeTool: $activeTool,
                    debugViewMode: $debugViewMode,
                    cropHeight: $cropHeight,
                    cropInfo: $cropInfo,
                    yRange: $yRange,
                    showingCropped: $showingCropped,
                    eraserSensitivity: $eraserSensitivity,
                    brushRadius: $brushRadius,
                    unifiedUndoCount: $unifiedUndoCount,
                    calibrateScaleActive: $calibrateScaleActive,
                    calibPointA: $calibPointA,
                    calibPointB: $calibPointB,
                    showCalibSheet: $showCalibSheet,
                    modelScaleFactor: $modelScaleFactor,
                    modelBoundingBox: $modelBoundingBox,
                    showQuickLook: $showQuickLook,
                    modelURL: $modelURL,
                    pressedItemId: $pressedItemId,
                    launchRoomExplorerAction: { self.launchRoomExplorer() }
                )            case .failed(let error):
                GalleryFailedView(error: error, processor: processor)
            }
        }
        .fullScreenCover(isPresented: $showQuickLook) {
            if let url = modelURL {
                QuickLookView(urls: [url], isPresented: $showQuickLook).ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showARCapture) {
            if #available(iOS 17.0, *) {
                ARCaptureModeView(isRoomMode: false) { url in
                    if let url = url { processor.state = .completed(url) }
                    showARCapture = false
                }
            }
        }
        .fullScreenCover(isPresented: $showRoomScan) {
            if #available(iOS 17.0, *) {
                ARCaptureModeView(isRoomMode: true) { url in
                    if let url = url { processor.state = .completed(url) }
                    showRoomScan = false
                }
            }
        }
        .fullScreenCover(isPresented: $showMeasure) {
            MeasurementModeView()
        }
        .fullScreenCover(isPresented: $showExplorer) {
            if let url = explorerURL { RoomExplorerView(url: url) }
        }
        .sheet(isPresented: $showMacConnection) {
            MacConnectionView()
        }
        .sheet(isPresented: $showDevReviewSheet) {
            ReviewSheetView(
                imageURLs: [
                    URL(string: "https://images.unsplash.com/photo-1579546929518-9e396f3cc809")!,
                    URL(string: "https://images.unsplash.com/photo-1557683316-973673baf926")!
                ],
                onConfirm: { showDevReviewSheet = false },
                onBuildOnMac: { showDevReviewSheet = false },
                roomPlanSummary: "Dev Sandbox Mode Active (3 Booths, 1 Door)",
                onCancel: { showDevReviewSheet = false }
            )
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let folderURL = urls.first else { return }
                Task { await folderReprocessor.reprocessFolder(at: folderURL) }
            case .failure(let error):
                print("Failed to select folder: \(error)")
            }
        }
        .fileImporter(isPresented: $showUSDZPicker, allowedContentTypes: [UTType(filenameExtension: "usdz") ?? .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                let fm = FileManager.default
                let tempURL = fm.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? fm.removeItem(at: tempURL)
                do {
                    try fm.copyItem(at: url, to: tempURL)
                    self.explorerURL = tempURL
                    self.showExplorer = true
                } catch {
                    print("Error copying picked USDZ: \(error)")
                }
                url.stopAccessingSecurityScopedResource()
            case .failure(let error):
                print("Failed to pick USDZ file: \(error)")
            }
        }
        .onChange(of: folderReprocessor.resultURL) { _, url in
            if let url = url {
                self.modelURL = url
                processor.state = .completed(url)
            }
        }
        .photosPicker(isPresented: $showPhotosPickerInline, selection: $pickerItems, maxSelectionCount: 500, matching: .images)
        .onChange(of: pickerItems) { _, newItems in loadSelectedPhotos(newItems) }
    }
    
    private var galleryPickerView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Image(systemName: "cube.transparent.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color("LightSaddle").opacity(0.9))
                .shadow(color:Color("LightSaddle"), radius: 30, x:5, y:15)
                .padding(30)
            HStack {
                Text("EasyPhotogrammetry")
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(Color("LightSaddle"))
            }
            .padding(.top, 15)
                if !processor.selectedImages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(0..<processor.selectedUIImages.count, id: \.self) { i in
                                    Image(uiImage: processor.selectedUIImages[i])
                                        .resizable().scaledToFill().frame(width: 70, height: 70).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }.padding(.horizontal)
                        }.frame(height: 75)
                        Text("\(processor.selectedImages.count) photos selected").font(.caption2).foregroundColor(.gray).padding(.horizontal)
                    }.padding(.top, 10)
                }
                HStack {
                    Button(action: goBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                            Text("Back")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5)
                        )
                        .foregroundColor(Color("LightSaddle"))
                    }
                    .opacity(navigationHistory.isEmpty ? 0.0 : 1.0)
                    .disabled(navigationHistory.isEmpty)
//                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: navigationHistory.isEmpty)
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 60)

                ScrollView {
//                    if currentItems.contains(where: { $0.targetViewId == "action_generate_iphone" }) {
//                        qualityPicker(for: $processor.selectedQuality)
//                    } else if currentItems.contains(where: { $0.targetViewId == "action_reprocess_folder" }) {
//                        qualityPicker(for: $folderReprocessor.selectedQuality)
//                    }
                    
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(currentItems) { item in
                            Button(action: { handleTileTap(item) }) {
                                tileView(for: item)
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }.padding()
                    
                    if folderReprocessor.isProcessing {
                        VStack(spacing: 8) {
                            ProgressView(value: folderReprocessor.progress, total: 1.0).tint(.pink)
                            Text(folderReprocessor.statusMessage).font(.caption2).foregroundStyle(.white)
                        }
                        .padding().background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 14)).padding()
                    }
                }
            }
            .background {
                Group {
                    if colorScheme == .light {
                        Color.black
                            .ignoresSafeArea()
                            .overlay(
                                darkModeAmbientBackground
                            )
                    } else {
                        Color.black
                            .ignoresSafeArea()
                    }
                }
            }            .animation(.easeInOut(duration: 0.22), value: currentItems)
        }
    }
    
    @ViewBuilder
    private func tileView(for item: GridItemData) -> some View {
        Rectangle()
            .fill(.black.opacity(0.7))
            .background(Material.thin)
            .aspectRatio(4/3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .leading) {
                VStack(alignment: .leading) {
                    Image(systemName: item.iconName)
                        .imageScale(.large).symbolRenderingMode(.hierarchical).font(.title)
                        .shadow(color: Color("ClassicSaddle"), radius: 20, x: 5, y: 10)
                    Spacer().frame(maxWidth: .infinity).clipped()
                    Text(item.name).font(.headline).foregroundColor(Color("LightSaddle"))
                    Text(item.status).font(.callout).foregroundColor(.gray)
                }.padding(10).foregroundStyle(Color("LightSaddle"))
            }
    }
    
//    @ViewBuilder
//    private func qualityPicker(for selected: Binding<ModelQuality>) -> some View {
//        VStack(spacing: 8) {
//            Text("Select Reconstruction Quality")
//                .font(.system(size: 13, weight: .semibold))
//                .foregroundColor(Color("LightSaddle"))
//                .shadow(color: .black.opacity(0.5), radius: 2)
//            
//            HStack(spacing: 4) {
//                ForEach(ModelQuality.allCases) { quality in
//                    Button {
//                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
//                            selected.wrappedValue = quality
//                        }
//                    } label: {
//                        Text(quality.rawValue)
//                            .font(.system(size: 11, weight: .bold))
//                            .foregroundColor(selected.wrappedValue == quality ? .black : Color("LightSaddle"))
//                            .padding(.vertical, 8)
//                            .frame(maxWidth: .infinity)
//                            .background(
//                                RoundedRectangle(cornerRadius: 8)
//                                    .fill(selected.wrappedValue == quality ? Color("LightSaddle") : Color.clear)
//                            )
//                    }
//                }
//            }
//            .padding(4)
//            .background(Color.black.opacity(0.4))
//            .background(.ultraThinMaterial)
//            .cornerRadius(10)
//            .overlay(
//                RoundedRectangle(cornerRadius: 10)
//                    .stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5)
//            )
//        }
//        .padding(.horizontal)
//        .padding(.top, 8)
//        .padding(.bottom, 4)
//    }
    
    private func handleTileTap(_ item: GridItemData) {
        if item.hasSubOptions, let sub = item.subOptions {
            navigationHistory.append(currentItems)
            currentItems = sub
        } else if let actionId = item.targetViewId {
            switch actionId {
            case "route_scan_object": showARCapture = true
            case "route_scan_room": showRoomScan = true
            case "route_measure": showMeasure = true
            case "route_explore_room": launchRoomExplorer()
            case "action_select_photos": showPhotosPickerInline = true
            case "action_generate_iphone": processor.processSelectedPhotos()
            case "action_build_mac": processor.sendToMac()
            case "action_reprocess_folder": showFolderPicker = true
            case "action_connect_mac": showMacConnection = true
            case "action_debug_asset":
                if let bundleURL = Bundle.main.url(forResource: nil, withExtension: "usdz") {
                    processor.state = .completed(bundleURL)
                }
            case "dev_bypass_to_preview":
                if let testModelURL = Bundle.main.url(forResource: "model", withExtension: "usdz") ??
                                      Bundle.main.url(forResource: "mode", withExtension: "usdz") {
                    processor.state = .completed(testModelURL)
                } else {
                    print("⚠️ Помилка: Додай файл 'model.usdz' у свій Xcode проект (Build Phase -> Copy Bundle Resources)!")
                }
                
            case "dev_bypass_to_review":
                showDevReviewSheet = true
            case "dev_bypass_to_completed":
                if let testModelURL = Bundle.main.url(forResource: "model", withExtension: "usdz") {
                    showARCapture = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        appState.captureManager.state = .completed(testModelURL)
                    }
                }
            default: break
            }
        }
    }
    
    private func goBack() {
        if let previousLevel = navigationHistory.popLast() {
            currentItems = previousLevel
        }
    }
    
    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        loadingPhotos = true
        Task {
            var rawData: [Data] = []
            var uiImages: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    rawData.append(data)
                    if let image = UIImage(data: data) { uiImages.append(image) }
                }
            }
            await MainActor.run {
                processor.selectedImages = rawData
                processor.selectedUIImages = uiImages
                loadingPhotos = false
            }
        }
    }
    
    private func launchRoomExplorer() {
        self.showUSDZPicker = true
    }
}


struct GalleryFailedView: View {
    let error: String
    @ObservedObject var processor: GalleryProcessor
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(.red)
            Text("Error").font(.title2).fontWeight(.bold).foregroundStyle(.white)
            Text(error).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            Button { processor.reset() } label: {
                Text("Try Again").fontWeight(.semibold).frame(maxWidth: .infinity).padding().background(Color.blue).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }.padding().background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
    }
}

struct ProcessingView: View {
    let progress: Double
    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress).scaleEffect(1.5).tint(.blue)
            Text("Processing: \(Int(progress * 100))%").font(.headline).foregroundStyle(.white)
            Text("This may take 5-10 minutes").font(.subheadline).foregroundStyle(.white.opacity(0.8))
        }.padding().background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let urls: [URL]
    @Binding var isPresented: Bool
    
    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        ql.delegate = context.coordinator
        return UINavigationController(rootViewController: ql)
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(urls: urls, isPresented: $isPresented) }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let urls: [URL]; @Binding var isPresented: Bool
        init(urls: [URL], isPresented: Binding<Bool>) { self.urls = urls; self._isPresented = isPresented }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { urls[index] as NSURL }
        nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) { Task { @MainActor in isPresented = false } }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - AR CAPTURE MODE (FULL SCREEN CONTROLLER)

@MainActor
final class AppState: ObservableObject {
    @Published var captureManager = CaptureManager()
}

struct ARCaptureModeView: View {
    var isRoomMode: Bool = false
    let onDismiss: (URL?) -> Void
    
    @StateObject private var appState = AppState()
    @State private var showReviewSheet: Bool = false
    @EnvironmentObject var engine: TransferEngine
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ARCameraView(manager: appState.captureManager).ignoresSafeArea(edges: .all)
            
            let hideCamera: Bool = {
                switch appState.captureManager.state {
                case .idle, .capturing: return false
                default: return true
                }
            }()
            
            if hideCamera { Color.black.ignoresSafeArea() }
            
            let isProcessingOnMac: Bool = {
                switch appState.captureManager.state {
                case .bakingGeometry, .processingOnMac: return true
                case .processing:
                    if case .idle = engine.state { return false }
                    return true
                default: return false
                }
            }()
            
            if isProcessingOnMac {
                MacTransferOverlayView(
                    engineState: engine.state,
                    isZipping: (engine.state == .idle || engine.state == .failed("") || engine.state == .connected(peer: "Mac Server") || appState.captureManager.state == .bakingGeometry)
                )
            } else if case .failed(let err) = engine.state, isProcessingOnMac {
                ARFailedView(error: "Mac transfer failed: \(err)", manager: appState.captureManager, onBackToReview: {
                    engine.state = .idle
                    appState.captureManager.state = .idle
                    showReviewSheet = true
                })
            } else if case .failed(let err) = appState.captureManager.state {
                ARFailedView(error: err, manager: appState.captureManager, onBackToReview: {
                    engine.state = .idle
                    appState.captureManager.state = .idle
                    showReviewSheet = true
                })
            } else {
                VStack {
                    HStack {
                        TopStatusBar(state: appState.captureManager.state)
                        Button { onDismiss(nil) } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.8)) }
                    }.padding()
                    
                    if isRoomMode, let rpm = appState.captureManager.roomPlanManager, rpm.isScanning {
                        HStack(spacing: 8) {
                            Image(systemName: "building.2.fill").foregroundStyle(.cyan)
                            Text(rpm.statusText).font(.caption.bold()).foregroundStyle(.white)
                        }.padding(.horizontal, 14).padding(.vertical, 8).background(.ultraThinMaterial).clipShape(Capsule()).animation(.easeInOut, value: rpm.statusText)
                    }
                    Spacer()
                    ARBottomControls(manager: appState.captureManager, onModelReady: { url in onDismiss(url) }).padding(.bottom, 40)
                }
            }
        }
        .sheet(isPresented: $showReviewSheet) {
            ReviewSheetView(
                imageURLs: appState.captureManager.capturedImageURLs,
                onConfirm: { Task { try? await appState.captureManager.stopCapture() }; showReviewSheet = false },
                onBuildOnMac: { showReviewSheet = false; sendToMac() },
                roomPlanSummary: appState.captureManager.roomPlanManager?.statusText,
                onCancel: { showReviewSheet = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowReviewSheet"))) { _ in showReviewSheet = true }
        .onChange(of: appState.captureManager.state) { _, newState in if case .completed(let url) = newState { onDismiss(url) } }
        .onAppear { appState.captureManager.isRoomMode = isRoomMode }
    }
    
    private func sendToMac() {
        let cm = appState.captureManager
        let dir = cm.imagesDirectory
        
        // Step 1: Finalise capture (exports roomplan.json, lidar.usdz, metadata.json)
        // This MUST happen before zipping. Previously this was skipped, so the Mac
        // received a ZIP with only images and no structural data.
        Task {
            // stopCapture writes all assets and transitions state to .bakingGeometry
            do {
                try await cm.stopCapture(exportOnly: true)
            } catch {
                // Insufficient images or other early error — already handled inside stopCapture
                print("⚠️ stopCapture error (may be ok if already in processing): \(error.localizedDescription)")
            }
            
            // ONLY after the await scope closes, proceed to transmission
            await MainActor.run { cm.state = .processingOnMac }
            
            // Step 2: Wire receive handler BEFORE sending
            // The Mac sends back "model.usdz". Copy it to the session folder (permanent
            // Documents location) so QuickLook and the gallery can open it reliably.
            let permanentModelURL = dir.appendingPathComponent("model_result.usdz")
            engine.onModelReceived = { [weak cm] tempURL in
                let permanentModelURL = dir.appendingPathComponent("model_result.usdz")
                try? FileManager.default.removeItem(at: permanentModelURL)
                do {
                    try FileManager.default.copyItem(at: tempURL, to: permanentModelURL)
                    print("✅ Model saved to permanent location: \(permanentModelURL.lastPathComponent)")
                    
                    DispatchQueue.main.async {
                        cm?.state = .completed(permanentModelURL)
                    }
                } catch {
                    print("❌ Failed to copy received model: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        cm?.state = .completed(tempURL) // fallback
                    }
                }
            }
            
            // Step 3: Stream the now-complete session folder in chunks
            await MainActor.run {
                if case .connected = engine.state {
                    Task {
                        await self.engine.startChunkedUpload(imagesDirectory: dir, sessionID: cm.sessionID)
                    }
                } else {
                    engine.connectToMac()
                    var cancellable: AnyCancellable?
                    cancellable = engine.$state.sink { state in
                        switch state {
                        case .connected:
                            cancellable?.cancel()
                            Task {
                                await self.engine.startChunkedUpload(imagesDirectory: dir, sessionID: cm.sessionID)
                            }
                        case .failed(let e):
                            cm.state = .failed("Mac transfer failed: \(e)")
                            cancellable?.cancel()
                        default: break
                        }
                    }
                    if let c = cancellable { self.cancellables.insert(c) }
                }
            }
        }
    }
}

struct ARCameraView: UIViewRepresentable {
    let manager: CaptureManager
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        arView.session.run(config)
        manager.connectToARView(arView)
        return arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct TileButton: View {
    let title: String
    var isHighlighted: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color("LightSaddle"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 10)
                .background(Material.thin)
                .background(Color.black.opacity(isHighlighted ? 0.4 : 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color("ClassicSaddle").opacity(isHighlighted ? 0.6 : 0.25), lineWidth: 0.5)
                )
                .shadow(color: isHighlighted ? Color("ClassicSaddle").opacity(0.3) : .clear, radius: 10, x: 0, y: 4)
        }
    }
}

// MARK: - AR HUD & CONTROLS

struct TopStatusBar: View {
    let state: CaptureState
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor, radius: 4)
            Text(statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color("LightSaddle"))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.5))
        .background(Material.thin.opacity(0.5))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

    }
    
    private var statusColor: Color {
        switch state {
        case .idle: return .green
        case .capturing: return .orange
        case .bakingGeometry: return .purple
        case .processingOnMac: return .cyan
        case .processing: return Color("LightSaddle")
        case .completed: return .green
        case .failed: return .red
        }
    }
    
    private var statusText: String {
        switch state {
        case .idle: return "Ready"
        case .capturing: return "Taking Photos"
        case .bakingGeometry: return "Baking Geometry..."
        case .processingOnMac: return "Processing on Mac..."
        case .processing: return "Processing..."
        case .completed: return "Complete!"
        case .failed: return "Error"
        }
    }
}

struct ARBottomControls: View {
    @ObservedObject var manager: CaptureManager
    var onModelReady: ((URL) -> Void)? = nil
    var body: some View {
        Group {
            switch manager.state {
            case .idle: IdleView(manager: manager)
            case .capturing: CapturingView(manager: manager)
            case .bakingGeometry: ARProcessingView(progress: 0.0)
            case .processingOnMac: ARProcessingView(progress: 0.5)
            case .processing(let p): ARProcessingView(progress: p)
            case .completed(let u): ARCompletedView(url: u, manager: manager, onModelReady: onModelReady)
            case .failed(let e): ARFailedView(error: e, manager: manager)
            }
        }
        .animation(.easeInOut, value: manager.state)
    }
}

struct IdleView: View {
    @ObservedObject var manager: CaptureManager
    var body: some View {
        VStack(spacing: 16) {
            Text(manager.isRoomMode ? "Point camera around the room" : "Point camera at object")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color("LightSaddle"))
                .shadow(color: Color("ClassicSaddle"), radius: 10, x: 0, y: 5)
                .padding(10)
                .background(Color.black.opacity(0.5))
                .background(Material.thin.opacity(0.5))
                .environment(\.colorScheme, .dark)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            // Premium Glassmorphic Quality Selector for Live Capture
//            VStack(spacing: 8) {
//                Text("Select Reconstruction Quality")
//                    .font(.system(size: 12, weight: .semibold))
//                    .foregroundColor(Color("LightSaddle"))
                
//                HStack(spacing: 4) {
//                    ForEach(ModelQuality.allCases) { quality in
//                        Button {
//                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
//                                manager.selectedQuality = quality
//                            }
//                        } label: {
//                            Text(quality.rawValue)
//                                .font(.system(size: 11, weight: .bold))
//                                .foregroundColor(manager.selectedQuality == quality ? .black : Color("LightSaddle"))
//                                .padding(.vertical, 8)
//                                .frame(maxWidth: .infinity)
//                                .background(
//                                    RoundedRectangle(cornerRadius: 8)
//                                        .fill(manager.selectedQuality == quality ? Color("LightSaddle") : Color.clear)
//                                )
//                        }
//                    }
//                }
//                .padding(4)
//                .background(Color.black.opacity(0.4))
//                .background(.ultraThinMaterial)
//                .cornerRadius(10)
//                .overlay(
//                    RoundedRectangle(cornerRadius: 10)
//                        .stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5)
//                )
//            }
//            .padding(.bottom, 8)
            
            Button { manager.startCapture() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 18, weight: .medium))
                    Text("Start Scanning")
                        .font(.system(size: 18, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.black.opacity(0.5))
                .background(Material.thin.opacity(0.5))
                .environment(\.colorScheme, .dark)
                .foregroundStyle(Color("LightSaddle"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color("LightSaddle").opacity(0.5), lineWidth: 0.5)
                )
                .shadow(color: Color("LightSaddle").opacity(0.4), radius: 15, x: 0, y: 8)
            }
        }
        .padding(.horizontal, 24)
    }
}

struct CapturingView: View {
    @ObservedObject var manager: CaptureManager
    
    var body: some View {
        VStack(spacing: 16) {
            // Stats HUD
            VStack(spacing: 8) {
                Text("Photos: \(manager.statistics.imagesCaptured)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color("LightSaddle"))
                Text("Minimum: 50 photos")
                    .font(.caption)
                    .foregroundStyle(.gray)
                ProgressView(value: manager.statistics.coveragePercentage)
                    .tint(Color("LightSaddle"))
            }
            .padding(16)
            .background(Color.black.opacity(0.5))
            .background(Material.thin.opacity(0.5))
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color("LightSaddle").opacity(0.5), lineWidth: 0.5)
            )
            
            // Capture Controls
            HStack(spacing: 12) {
                // Auto-Capture Toggle Tile
                VStack(spacing: 6) {
                    Toggle("", isOn: $manager.isAutoCaptureEnabled).labelsHidden().tint(Color("ClassicSaddle"))
                    Text("Auto")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color("LightSaddle"))
                }
                .frame(width: 70, height: 70)
                .background(Color.black.opacity(0.5))
                .background(Material.thin.opacity(0.5))
                .environment(\.colorScheme, .dark)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color("LightSaddle").opacity(0.5), lineWidth: 0.5)
                )
                
                // Main Shutter Button
                Button { manager.capturePhoto() } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color("LightSaddle"))
                        .frame(width: 76, height: 76)
                        .background(Color.black.opacity(manager.isAutoCaptureEnabled ? 0.6 : 0.3))
                        .background(Material.thin.opacity(0.5))
                        .environment(\.colorScheme, .dark)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color("LightSaddle").opacity(0.5), lineWidth: 1)
                        )
                        .shadow(color: manager.isAutoCaptureEnabled ? .clear : Color("LightSaddle").opacity(0.4), radius: 10, x: 0, y: 4)
                }
                .disabled(manager.isAutoCaptureEnabled)
                
                // Done Button
                Button {
                    NotificationCenter.default.post(name: Notification.Name("ShowReviewSheet"), object: nil)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .bold))
                        Text("Done")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color("LightSaddle"))
                    .frame(width: 70, height: 70)
                    .background(Color.black.opacity(0.5))
                    .background(Material.thin.opacity(0.5))
                    .environment(\.colorScheme, .dark)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color("LightSaddle").opacity(0.5), lineWidth: 0.5)
                    )
                }
                .disabled(manager.statistics.imagesCaptured < 6)
                .opacity(manager.statistics.imagesCaptured < 6 ? 0.4 : 1.0)
            }
        }
        .padding(.horizontal, 24)
    }
}
struct ARProcessingView: View {
    let progress: Double
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .tint(Color("LightSaddle"))
            Text("Processing... \(Int(progress * 100))%")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color("LightSaddle"))
        }
        .padding(20)
        .background(Color.black.opacity(0.5))
        .background(Material.thin.opacity(0.5))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color("LightSaddle").opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: Color("LightSaddle").opacity(0.3), radius: 15, x: 0, y: 6)
        .padding(.horizontal, 24)
    }
}
//  ARCompletedView: Redesigned using sleek vertical tiles to save space
struct ARCompletedView: View {
    let url: URL
    @ObservedObject var manager: CaptureManager
    var onModelReady: ((URL) -> Void)? = nil
    
    @State private var showShare = false
    @State private var showRoomPlanShare = false
    @State private var showRawShare = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "cube.transparent.fill")
                    .font(.title2)
                    .foregroundStyle(Color("LightSaddle"))
                    .shadow(color: Color("ClassicSaddle"), radius: 10)
                Text("3D Model Ready!")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color("LightSaddle"))
            }
            .padding(.bottom, 4)
            
            // Sleek Action Stack
            TileButton(title: "Open in Editor", isHighlighted: true) { onModelReady?(url) }
            
            HStack(spacing: 10) {
                TileButton(title: "Share USDZ") { showShare = true }
                    .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
                
                if let rpURL = manager.roomPlanURL {
                    TileButton(title: "RoomPlan") { showRoomPlanShare = true }
                        .sheet(isPresented: $showRoomPlanShare) { ShareSheet(items: [rpURL]) }
                }
            }
            
            TileButton(title: "Export Raw Dataset") { showRawShare = true }
                .sheet(isPresented: $showRawShare) { ShareSheet(items: [manager.imagesDirectory]) }
            
            TileButton(title: "Scan Another Object") { manager.reset() }
        }
        .padding(20)
        .background(Material.thin)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, 20)
    }
}

// MARK: - REVIEW SHEET VIEW (Dark Aesthetic)
struct ReviewSheetView: View {
    let imageURLs: [URL]; let onConfirm: () -> Void; var onBuildOnMac: (() -> Void)? = nil; var roomPlanSummary: String? = nil; let onCancel: () -> Void
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
    @State private var saveStatus: String? = nil; @State private var isSaving = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea() // Deep dark background
                
                ScrollView {
                    VStack {
                        if let summary = roomPlanSummary {
                            HStack(spacing: 8) {
                                Image(systemName: "building.2.fill").foregroundStyle(Color("LightSaddle"))
                                Text(summary).font(.caption.bold()).foregroundStyle(Color("LightSaddle"))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity)
                            .background(Material.thin).background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                            .padding(.horizontal).padding(.top, 8)
                        }
                        if imageURLs.isEmpty {
                            Text("No photos captured yet.").foregroundStyle(.gray).padding()
                        } else {
                            if imageURLs.count < 20 {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Too few photos!")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.orange)
                                        Text("Photogrammetry requires a minimum of 20 photos to reconstruct a 3D model. Please go back and capture more.")
                                            .font(.caption)
                                            .foregroundStyle(.orange.opacity(0.9))
                                    }
                                }
                                .padding()
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                                .padding(.horizontal)
                                .padding(.top, 4)
                            }
                            
                            if let status = saveStatus {
                                Text(status).font(.footnote)
                                    .foregroundColor(status.contains("✅") ? .green : Color("LightSaddle")).padding(.horizontal)
                            }
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(imageURLs, id: \.self) { url in ReviewThumbnail(url: url) }
                            }.padding()
                        }
                    }
                }
            }
            .navigationTitle("Review (\(imageURLs.count) Photos)")
            .navigationBarTitleDisplayMode(.inline)
            // Toolbar styling adapted for dark theme
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).foregroundStyle(.gray)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { saveAllToPhotos() } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text(isSaving ? "Saving..." : "Save to Photos")
                        }
                        .font(.system(size: 14, weight: .medium))
                    }
                    .disabled(imageURLs.isEmpty || isSaving)
                    .foregroundStyle(Color("LightSaddle"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        if let onMac = onBuildOnMac {
                            Button { onMac() } label: { Text("Mac Build") }
                                .foregroundStyle(Color("ClassicSaddle"))
                        }
                        Button("Process", action: onConfirm)
                            .fontWeight(.bold)
                            .foregroundStyle(Color("LightSaddle"))
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
    
    private func saveAllToPhotos() {
        Task { @MainActor in
            isSaving = true
            saveStatus = "Saving \(imageURLs.count) photos..."
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveStatus = "⚠️ Photo library access denied"; isSaving = false; return
            }
            var saved = 0; var failed = 0
            for url in imageURLs {
                let targetURL = url
                do {
                    try await performPhotoLibraryChange(for: targetURL)
                    saved += 1
                } catch { failed += 1 }
                saveStatus = "Saving... \(saved + failed)/\(imageURLs.count)"
            }
            saveStatus = failed == 0 ? "✅ Saved all \(saved) photos" : "⚠️ Saved \(saved)/\(imageURLs.count)"
            isSaving = false
        }
    }
    
    nonisolated private func performPhotoLibraryChange(for fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: nil)
        }
    }
}

struct ReviewThumbnail: View {
    let url: URL
    var body: some View {
        if let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable().scaledToFill().frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5))
        } else {
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: 100, height: 100)
                .overlay(ProgressView().tint(Color("LightSaddle")))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
// MARK: - INTERACTIVE 3D MODEL EDITOR WITH COORDINATOR

struct ModelEditorView: UIViewRepresentable {
    let url: URL
    @Binding var cleanModelActive: Bool
    @Binding var activeTool: EditingTool
    @Binding var debugViewMode: DebugViewMode
    
    @Binding var cropHeight: Float
    @Binding var cropInfo: String
    let yRange: Binding<(min: Float, max: Float)>
    @Binding var showingCropped: Bool
    
    @Binding var eraserSensitivity: Float
    @Binding var brushRadius: Float
    @Binding var unifiedUndoCount: Int
    var onCropSaved: ((URL) -> Void)? = nil
    
    @Binding var calibrateScaleActive: Bool
    @Binding var calibPointA: SCNVector3?
    @Binding var calibPointB: SCNVector3?
    var onCalibPointsSet: (() -> Void)? = nil
    @Binding var modelScaleFactor: Float
    @Binding var modelBoundingBox: (w: Float, h: Float, d: Float)?
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.autoenablesDefaultLighting = false
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X
        
        let scene: SCNScene
        var initialDiffuseMap: CGImage? = nil
        if let unified = MeshCropper.loadUnifiedScene(from: url) {
            scene = unified.scene
            initialDiffuseMap = unified.diffuseMap
        } else if let direct = try? SCNScene(url: url) {
            scene = direct
        } else {
            scene = SCNScene()
        }
        
        // Extract all existing children of the loaded scene
        let existingChildren = scene.rootNode.childNodes
        for child in existingChildren {
            child.removeFromParentNode()
        }
        
        let resultContainer = SCNNode()
        resultContainer.name = "resultContainer"
        resultContainer.isHidden = false
        for child in existingChildren {
            resultContainer.addChildNode(child.clone())
        }
        scene.rootNode.addChildNode(resultContainer)
        
        let photoContainer = SCNNode()
        photoContainer.name = "photoContainer"
        photoContainer.isHidden = true
        
        let dir = url.deletingLastPathComponent()
        let photoURL = dir.appendingPathComponent("model_result.usdz")
        let altPhotoURL = dir.appendingPathComponent("model.usdz")
        let finalPhotoURL = FileManager.default.fileExists(atPath: photoURL.path) ? photoURL : altPhotoURL
        if let photoScene = try? SCNScene(url: finalPhotoURL) {
            for child in photoScene.rootNode.childNodes {
                photoContainer.addChildNode(child.clone())
            }
        } else {
            // Fallback: extract photogrammetry nodes from the main scene
            if let fillNode = resultContainer.childNode(withName: "photogrammetry_fill", recursively: true) {
                photoContainer.addChildNode(fillNode.clone())
            } else {
                for child in existingChildren {
                    if child.name != "lidar_geometry" && child.name != "lidar_objects" && !(child.name?.hasPrefix("wall_") ?? false) && !(child.name?.hasPrefix("floor_") ?? false) {
                        photoContainer.addChildNode(child.clone())
                    }
                }
            }
        }
        scene.rootNode.addChildNode(photoContainer)
        
        let lidarContainer = SCNNode()
        lidarContainer.name = "lidarContainer"
        lidarContainer.isHidden = true
        
        let lidarURL = dir.appendingPathComponent("room_lidar_merged.usdz")
        let altLidarURL = dir.appendingPathComponent("lidar.usdz")
        let texturedRoomURL = dir.appendingPathComponent("room_textured.usdz")
        let finalLidarURL = FileManager.default.fileExists(atPath: lidarURL.path) ? lidarURL :
                            (FileManager.default.fileExists(atPath: altLidarURL.path) ? altLidarURL : texturedRoomURL)
        if let lidarScene = try? SCNScene(url: finalLidarURL) {
            for child in lidarScene.rootNode.childNodes {
                lidarContainer.addChildNode(child.clone())
            }
        } else {
            // Fallback: extract LiDAR nodes from the main scene
            if let fillNode = resultContainer.childNode(withName: "lidar_geometry", recursively: true) ??
                              resultContainer.childNode(withName: "lidar_objects", recursively: true) {
                lidarContainer.addChildNode(fillNode.clone())
            } else {
                for child in existingChildren {
                    if child.name?.hasPrefix("wall_") ?? false || child.name?.hasPrefix("floor_") ?? false || child.name?.hasPrefix("door_") ?? false || child.name?.hasPrefix("window_") ?? false {
                        lidarContainer.addChildNode(child.clone())
                    }
                }
            }
        }
        scene.rootNode.addChildNode(lidarContainer)
        
        let ambientLight = SCNNode(); ambientLight.light = SCNLight(); ambientLight.light!.type = .ambient; ambientLight.light!.color = UIColor(white: 0.4, alpha: 1.0); scene.rootNode.addChildNode(ambientLight)
        let dirLight = SCNNode(); dirLight.light = SCNLight(); dirLight.light!.type = .directional; dirLight.light!.color = UIColor(white: 0.8, alpha: 1.0); dirLight.light!.castsShadow = true; dirLight.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0); scene.rootNode.addChildNode(dirLight)
        let fillLight = SCNNode(); fillLight.light = SCNLight(); fillLight.light!.type = .directional; fillLight.light!.color = UIColor(white: 0.3, alpha: 1.0); fillLight.eulerAngles = SCNVector3(Float.pi / 4, -Float.pi / 3, 0); scene.rootNode.addChildNode(fillLight)
        
        let (minB, maxB) = scene.rootNode.boundingBox
        let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        let sizeVec = SCNVector3(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)
        let maxDim = max(sizeVec.x, max(sizeVec.y, sizeVec.z))
        
        let cameraOrbitNode = SCNNode(); cameraOrbitNode.position = center
        let cameraNode = SCNNode(); cameraNode.camera = SCNCamera(); cameraNode.camera!.automaticallyAdjustsZRange = true
        cameraNode.position = SCNVector3(0, maxDim * 0.3, maxDim * 2.0); cameraNode.look(at: SCNVector3(0,0,0))
        cameraOrbitNode.addChildNode(cameraNode); scene.rootNode.addChildNode(cameraOrbitNode)
        scnView.pointOfView = cameraNode
        
        scene.background.contents = UIColor.darkGray
        scnView.scene = scene
        
        let coord = context.coordinator
        coord.scnView = scnView; coord.originalURL = url; coord.originalScene = scene; coord.diffuseTexture = initialDiffuseMap
        coord.yMin = minB.y; coord.yMax = maxB.y; coord.modelWidth = max(sizeVec.x, sizeVec.z) * 1.5
        coord.resultContainerNode = resultContainer; coord.photogrammetryContainerNode = photoContainer; coord.lidarContainerNode = lidarContainer
        
        NotificationCenter.default.addObserver(forName: Notification.Name("ApplyCalibrationScale"), object: nil, queue: .main) { [weak coord] note in
            if let cm = note.userInfo?["cm"] as? Float { Task { @MainActor in coord?.applyCalibrationScale(realCm: cm) } }
        }
        
        DispatchQueue.main.async { self.yRange.wrappedValue = (min: minB.y, max: maxB.y); self.cropHeight = minB.y }
        
        let planeGeom = SCNPlane(width: CGFloat(coord.modelWidth), height: CGFloat(coord.modelWidth))
        let mat = SCNMaterial(); mat.diffuse.contents = UIColor.red.withAlphaComponent(0.25); mat.isDoubleSided = true; planeGeom.materials = [mat]
        let planeNode = SCNNode(geometry: planeGeom); planeNode.eulerAngles.x = -.pi / 2; planeNode.isHidden = true; planeNode.name = "cropPlane"
        scene.rootNode.addChildNode(planeNode); coord.cropPlaneNode = planeNode
        
        let calibTap = UITapGestureRecognizer(target: coord, action: #selector(Coordinator.handleCalibTap(_:)))
        calibTap.delegate = coord; scnView.addGestureRecognizer(calibTap); coord.calibTapGesture = calibTap
        
        let panGesture = UIPanGestureRecognizer(target: coord, action: #selector(Coordinator.handlePan(_:)))
        panGesture.delegate = coord; scnView.addGestureRecognizer(panGesture); coord.panGesture = panGesture
        
        let toolGesture = UILongPressGestureRecognizer(target: coord, action: #selector(Coordinator.handleToolDrag(_:)))
        toolGesture.minimumPressDuration = 0.0; toolGesture.delegate = coord; scnView.addGestureRecognizer(toolGesture); coord.toolGesture = toolGesture
        
        let twoFingerPan = UIPanGestureRecognizer(target: coord, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2; twoFingerPan.maximumNumberOfTouches = 2; twoFingerPan.delegate = coord; scnView.addGestureRecognizer(twoFingerPan)
        
        let pinchGesture = UIPinchGestureRecognizer(target: coord, action: #selector(Coordinator.handlePinch(_:)))
        pinchGesture.delegate = coord; scnView.addGestureRecognizer(pinchGesture)
        
        coord.cameraOrbitNode = cameraOrbitNode; coord.cameraDistance = maxDim * 2.0
        
        let cursorGeo = SCNSphere(radius: 0.05); let cursorMat = SCNMaterial(); cursorMat.diffuse.contents = UIColor.systemPink.withAlphaComponent(0.6); cursorMat.readsFromDepthBuffer = false; cursorGeo.materials = [cursorMat]
        let cursorNode = SCNNode(geometry: cursorGeo); cursorNode.isHidden = true; cursorNode.renderingOrder = 200; scene.rootNode.addChildNode(cursorNode); coord.brushCursorNode = cursorNode
        
        return scnView
    }

    
    func updateUIView(_ uiView: SCNView, context: Context) {
        let coord = context.coordinator
        coord.cleanModelActiveBinding = $cleanModelActive; coord.activeToolBinding = $activeTool; coord.cropHeightBinding = $cropHeight; coord.cropInfoBinding = $cropInfo; coord.showingCroppedBinding = $showingCropped
        coord.eraserSensitivityBinding = $eraserSensitivity; coord.brushRadiusBinding = $brushRadius; coord.unifiedUndoCountBinding = $unifiedUndoCount; coord.onCropSaved = onCropSaved
        coord.calibrateScaleActiveBinding = $calibrateScaleActive; coord.calibPointABinding = $calibPointA; coord.calibPointBBinding = $calibPointB; coord.onCalibPointsSet = onCalibPointsSet
        coord.modelScaleFactorBinding = $modelScaleFactor; coord.modelBoundingBoxBinding = $modelBoundingBox
        
        if !showingCropped && coord.scnView?.scene !== coord.originalScene { coord.resetCrop() }
        
        let toolActive = cleanModelActive
        let cropActive = cleanModelActive && activeTool == .crop
        let wandActive = cleanModelActive && activeTool == .wand
        let brushActive = cleanModelActive && activeTool == .brush
        
        coord.panGesture?.isEnabled = cropActive
        coord.toolGesture?.isEnabled = wandActive || brushActive
        coord.calibTapGesture?.isEnabled = calibrateScaleActive && !cleanModelActive
        uiView.allowsCameraControl = !toolActive && !calibrateScaleActive
        coord.cropPlaneNode?.isHidden = !cropActive
        coord.brushCursorNode?.isHidden = !brushActive
        
        if brushActive, let sphere = coord.brushCursorNode?.geometry as? SCNSphere { sphere.radius = CGFloat(brushRadius) }
        
        let wasToolActive = coord._wasToolActive
        if toolActive && !wasToolActive { coord._wasToolActive = true; coord.enterEraserMode() }
        else if !toolActive && wasToolActive { coord._wasToolActive = false }
        
        let currentUndo = unifiedUndoCount
        if currentUndo < coord.lastKnownUndoCount { coord.undoLastStored() }
        coord.lastKnownUndoCount = currentUndo
        
        if cropActive { coord.cropPlaneNode?.position.y = cropHeight }
        coord.applyDebugViewMode(debugViewMode)
    }
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var scnView: SCNView?; var originalURL: URL?; var originalScene: SCNScene?; var cropPlaneNode: SCNNode?; var panGesture: UIPanGestureRecognizer?; var toolGesture: UILongPressGestureRecognizer?; var eraserPreviewNode: SCNNode?; var brushCursorNode: SCNNode?
        var resultContainerNode: SCNNode?; var photogrammetryContainerNode: SCNNode?; var lidarContainerNode: SCNNode?; var currentDebugMode: DebugViewMode = .result
        var cameraOrbitNode: SCNNode?; var cameraDistance: Float = 1.0; var panOrbitStartAngles = SCNVector3Zero
        var yMin: Float = 0; var yMax: Float = 1; var modelWidth: Float = 1; var cropWasActive = false; var _wasToolActive = false; var isEnteringEraser = false; var lastKnownUndoCount = 0; var diffuseTexture: CGImage? = nil; var onCropSaved: ((URL) -> Void)?
        
        var cleanModelActiveBinding: Binding<Bool>?; var activeToolBinding: Binding<EditingTool>?; var cropHeightBinding: Binding<Float>?; var cropInfoBinding: Binding<String>?; var showingCroppedBinding: Binding<Bool>?; var eraserSensitivityBinding: Binding<Float>?; var brushRadiusBinding: Binding<Float>?; var unifiedUndoCountBinding: Binding<Int>?
        var calibrateScaleActiveBinding: Binding<Bool>?; var calibPointABinding: Binding<SCNVector3?>?; var calibPointBBinding: Binding<SCNVector3?>?; var onCalibPointsSet: (() -> Void)?; var modelScaleFactorBinding: Binding<Float>?; var modelBoundingBoxBinding: Binding<(w: Float, h: Float, d: Float)?>?; var calibTapGesture: UITapGestureRecognizer?; var calibMarkerA: SCNNode? = nil; var calibMarkerB: SCNNode? = nil
        
        var meshStates: [ObjectIdentifier: MeshEditState] = [:]; var undoStack: [(ObjectIdentifier, MeshEditState)] = []
        var dragStartPt: CGPoint = .zero; var dragBaseSensitivity: Float = 0.35; var currentDragNodeId: ObjectIdentifier? = nil; var currentDragElement: Int = 0; var currentDragSeed: Int = 0; var lastDragSelected: Set<Int> = []
        var accumulatedBrushSelection: Set<Int> = []; var brushLastHitPoint: SIMD3<Float>? = nil; var isBrushComputing: Bool = false; var brushWantsToFinalize: Bool = false; var isApplyingRemoval: Bool = false; var activeToolDuringDrag: EditingTool? = nil
        private var panStartCropHeight: Float = 0
        
        @objc func handleCalibTap(_ gesture: UITapGestureRecognizer) {
            guard let view = scnView else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
            let validHit = hits.first { guard let name = $0.node.name else { return true }; return name != "cropPlane" && name != "eraserPreview" && name != "calibA" && name != "calibB" }
            guard let hit = validHit else { return }
            let pos = hit.worldCoordinates
            
            if calibPointABinding?.wrappedValue == nil {
                calibMarkerA?.removeFromParentNode()
                let sphere = SCNSphere(radius: 0.008); sphere.firstMaterial?.diffuse.contents = UIColor.systemGreen
                let node = SCNNode(geometry: sphere); node.name = "calibA"; node.position = pos
                view.scene?.rootNode.addChildNode(node); calibMarkerA = node
                DispatchQueue.main.async { self.calibPointABinding?.wrappedValue = pos }
            } else if calibPointBBinding?.wrappedValue == nil {
                calibMarkerB?.removeFromParentNode()
                let sphere = SCNSphere(radius: 0.008); sphere.firstMaterial?.diffuse.contents = UIColor.systemRed
                let node = SCNNode(geometry: sphere); node.name = "calibB"; node.position = pos
                view.scene?.rootNode.addChildNode(node); calibMarkerB = node
                DispatchQueue.main.async { self.calibPointBBinding?.wrappedValue = pos; self.onCalibPointsSet?() }
            }
        }
        
        func applyCalibrationScale(realCm: Float) {
            guard let ptA = calibPointABinding?.wrappedValue, let ptB = calibPointBBinding?.wrappedValue, let view = scnView else { return }
            let dx = ptB.x - ptA.x; let dy = ptB.y - ptA.y; let dz = ptB.z - ptA.z; let modelDist = sqrt(dx*dx + dy*dy + dz*dz)
            guard modelDist > 0.0001 else { return }
            
            let factor = (realCm / 100.0) / modelDist; let current = view.scene?.rootNode.simdScale ?? SIMD3<Float>(1,1,1); let newScale = current * factor
            view.scene?.rootNode.simdScale = newScale
            
            let (minB, maxB) = (view.scene?.rootNode.boundingBox) ?? (SCNVector3Zero, SCNVector3Zero)
            let wCm = abs(maxB.x - minB.x) * newScale.x * 100; let hCm = abs(maxB.y - minB.y) * newScale.y * 100; let dCm = abs(maxB.z - minB.z) * newScale.z * 100
            
            calibMarkerA?.removeFromParentNode(); calibMarkerB?.removeFromParentNode(); calibMarkerA = nil; calibMarkerB = nil
            DispatchQueue.main.async {
                self.modelScaleFactorBinding?.wrappedValue = factor; self.modelBoundingBoxBinding?.wrappedValue = (w: wCm, h: hCm, d: dCm)
                self.calibPointABinding?.wrappedValue = nil; self.calibPointBBinding?.wrappedValue = nil; self.calibrateScaleActiveBinding?.wrappedValue = false
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = scnView else { return }
            if gesture.state == .began { panStartCropHeight = cropHeightBinding?.wrappedValue ?? yMin }
            else if gesture.state == .changed {
                let deltaY = Float(gesture.translation(in: view).y) / Float(view.bounds.height)
                let range = yMax - yMin; let clamped = max(yMin, min(yMax, panStartCropHeight - deltaY * range * 2.0))
                cropPlaneNode?.position.y = clamped
                DispatchQueue.main.async {
                    self.cropHeightBinding?.wrappedValue = clamped
                    self.cropInfoBinding?.wrappedValue = "Cut line: \(Int(((clamped - self.yMin) / range) * 100))% height"
                }
            }
        }
        
        func applyDebugViewMode(_ mode: DebugViewMode) {
            guard mode != currentDebugMode else { return }
            currentDebugMode = mode
            let resultNode = resultContainerNode
            let photoNode = photogrammetryContainerNode
            let lidarNode = lidarContainerNode
            switch mode {
            case .result:
                resultNode?.isHidden = false
                photoNode?.isHidden = true
                lidarNode?.isHidden = true
            case .photogrammetry:
                resultNode?.isHidden = true
                photoNode?.isHidden = false
                lidarNode?.isHidden = true
            case .lidarRoomScan:
                resultNode?.isHidden = true
                photoNode?.isHidden = true
                lidarNode?.isHidden = false
            }
        }
        
        func resetCrop() {
            guard let scene = originalScene, let view = scnView else { return }
            DispatchQueue.main.async { view.scene = scene; self.showingCroppedBinding?.wrappedValue = false; self.cropInfoBinding?.wrappedValue = "" }
        }
        
        func enterEraserMode() {
            guard let scene = scnView?.scene else { return }
            guard !isEnteringEraser else { return }
            isEnteringEraser = true; meshStates.removeAll(); undoStack.removeAll()

            scene.rootNode.enumerateChildNodes { node, _ in
                guard let geo = node.geometry, node.name != "cropPlane", node.name != "eraserPreview", node.name != "brushCursor" else { return }
                var parent = node.parent
                while let p = parent { if p.name == "lidarContainer" { return }; parent = p.parent }
                if let state = MeshEraser.prepareState(for: geo, texture: self.diffuseTexture) { self.meshStates[ObjectIdentifier(node)] = state }
            }
            DispatchQueue.main.async { self.unifiedUndoCountBinding?.wrappedValue = 0; self.lastKnownUndoCount = 0; self.cropInfoBinding?.wrappedValue = "Ready"; self.isEnteringEraser = false }
            
            if eraserPreviewNode == nil {
                let pNode = SCNNode(); pNode.name = "eraserPreview"; pNode.renderingOrder = 100; scene.rootNode.addChildNode(pNode); eraserPreviewNode = pNode
            }
        }

        @objc func handleToolDrag(_ gesture: UILongPressGestureRecognizer) {
            guard let view = scnView else { return }
            if gesture.state == .began { activeToolDuringDrag = activeToolBinding?.wrappedValue }
            if activeToolDuringDrag == nil { activeToolDuringDrag = activeToolBinding?.wrappedValue }
            guard let tool = activeToolDuringDrag else { return }
            
            if tool == .wand { handleWandDrag(pt: gesture.location(in: view), view: view, state: gesture.state) }
            else if tool == .brush { handleBrushDrag(pt: gesture.location(in: view), view: view, state: gesture.state) }
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { activeToolDuringDrag = nil }
        }
        
        private func handleBrushDrag(pt: CGPoint, view: SCNView, state: UIGestureRecognizer.State) {
            guard !isApplyingRemoval else { return }
            if state == .began { DispatchQueue.main.async { self.eraserPreviewNode?.geometry = nil }; brushCursorNode?.isHidden = false; accumulatedBrushSelection.removeAll(); brushLastHitPoint = nil }
            
            let hits = view.hitTest(pt, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
            let validHit = hits.first { guard let name = $0.node.name else { return true }; return name != "cropPlane" && name != "eraserPreview" && name != "brushCursor" }
            guard let hit = validHit else { if state == .ended || state == .cancelled { finalizeBrushStroke(view: view) }; return }
            
            let node = hit.node; let nodeId = ObjectIdentifier(node); guard let meshState = meshStates[nodeId] else { return }
            currentDragNodeId = nodeId; currentDragElement = meshState.scnElementMapping[hit.geometryIndex].originalElementIndex
            
            let hitPt = SIMD3<Float>(hit.localCoordinates.x, hit.localCoordinates.y, hit.localCoordinates.z)
            let radius = brushRadiusBinding?.wrappedValue ?? 0.05
            
            if isBrushComputing { return }
            if state == .changed, let lastHit = brushLastHitPoint {
                let movedDistSq = simd_length_squared(hitPt - lastHit)
                if movedDistSq < (0.002 * 0.002) { return }
                let maxJumpLimit = radius * 2.5
                if movedDistSq > (maxJumpLimit * maxJumpLimit) { return }
            }
            
            if state == .began || state == .changed {
                brushCursorNode?.position = hit.worldCoordinates; brushCursorNode?.isHidden = false
                let startPt = brushLastHitPoint ?? hitPt; let endPt = hitPt; let elemIdx = currentDragElement
                self.isBrushComputing = true
                
                DispatchQueue.global(qos: .userInteractive).async { [weak self, startPt, endPt, radius, elemIdx, meshState] in
                    guard let self = self else { return }
                    let newlySelected = MeshEraser.selectTrianglesInCapsule(start: startPt, end: endPt, radius: radius, elementIndex: elemIdx, state: meshState)
                    DispatchQueue.main.async {
                        if !newlySelected.isEmpty { self.accumulatedBrushSelection.formUnion(newlySelected) }
                        if let previewGeo = MeshEraser.previewGeometry(selected: self.accumulatedBrushSelection, elementIndex: elemIdx, state: meshState) { self.eraserPreviewNode?.geometry = previewGeo }
                        self.isBrushComputing = false
                        if self.brushWantsToFinalize { self.brushWantsToFinalize = false; self.finalizeBrushStroke(view: view) }
                    }
                }
                brushLastHitPoint = hitPt
            }
            if state == .ended || state == .cancelled { if isBrushComputing { brushWantsToFinalize = true } else { finalizeBrushStroke(view: view) } }
        }
        
        private func finalizeBrushStroke(view: SCNView) {
            brushCursorNode?.isHidden = true
            guard let nodeId = currentDragNodeId, let meshState = meshStates[nodeId], !accumulatedBrushSelection.isEmpty else {
                self.eraserPreviewNode?.geometry = nil; accumulatedBrushSelection.removeAll(); brushLastHitPoint = nil; return
            }
            undoStack.append((nodeId, meshState.copy()))
            let finalSelection = accumulatedBrushSelection; let geomIdx = currentDragElement
            self.isApplyingRemoval = true
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self, nodeId, finalSelection, geomIdx, meshState] in
                guard let newGeo = MeshEraser.applyRemoval(selected: finalSelection, elementIndex: geomIdx, state: meshState) else { DispatchQueue.main.async { self?.isApplyingRemoval = false }; return }
                DispatchQueue.main.async {
                    var targetNode: SCNNode? = nil
                    view.scene?.rootNode.enumerateChildNodes { node, stop in if ObjectIdentifier(node) == nodeId { targetNode = node; stop.pointee = true } }
                    targetNode?.geometry = newGeo; self?.eraserPreviewNode?.geometry = nil; self?.finalizeCurrentToolAction()
                    self?.accumulatedBrushSelection.removeAll(); self?.brushLastHitPoint = nil; self?.isApplyingRemoval = false
                }
            }
        }
        
        private func handleWandDrag(pt: CGPoint, view: SCNView, state: UIGestureRecognizer.State) {
            if state == .began {
                guard !isApplyingRemoval else { return }
                let hits = view.hitTest(pt, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
                let validHit = hits.first { guard let name = $0.node.name else { return true }; return name != "cropPlane" && name != "eraserPreview" }
                guard let hit = validHit else { return }
                let node = hit.node; let nodeId = ObjectIdentifier(node)
                if meshStates[nodeId] == nil { if let geo = node.geometry, let newState = MeshEraser.prepareState(for: geo, texture: diffuseTexture) { meshStates[nodeId] = newState } else { return } }
                guard let mState = meshStates[nodeId] else { return }
                let mapping = mState.scnElementMapping[hit.geometryIndex]
                dragStartPt = pt; dragBaseSensitivity = eraserSensitivityBinding?.wrappedValue ?? 0.35
                currentDragNodeId = nodeId; currentDragElement = mapping.originalElementIndex; currentDragSeed = mapping.baseTriangleIndex + hit.faceIndex
                updateWandPreview(sensitivity: dragBaseSensitivity, state: mState)
            } else if state == .changed {
                guard let nodeId = currentDragNodeId, let mState = meshStates[nodeId] else { return }
                var dynamicSens = dragBaseSensitivity + Float(dragStartPt.y - pt.y) / 250.0; dynamicSens = max(0.0, min(1.0, dynamicSens))
                DispatchQueue.main.async { self.eraserSensitivityBinding?.wrappedValue = dynamicSens }
                updateWandPreview(sensitivity: dynamicSens, state: mState)
            } else if state == .ended || state == .cancelled {
                DispatchQueue.main.async { self.eraserPreviewNode?.geometry = nil }
                guard let nodeId = currentDragNodeId, let mState = meshStates[nodeId], !lastDragSelected.isEmpty else {
                    if let oldId = currentDragNodeId, let oldState = meshStates[oldId] {
                        var tNode: SCNNode? = nil; scnView?.scene?.rootNode.enumerateChildNodes { n, s in if ObjectIdentifier(n) == oldId { tNode = n; s.pointee = true } }
                        tNode?.geometry = oldState.geometry
                    }
                    cleanupWandDragState(); return
                }
                var tNode: SCNNode? = nil; scnView?.scene?.rootNode.enumerateChildNodes { node, stop in if ObjectIdentifier(node) == nodeId { tNode = node; stop.pointee = true } }
                guard let node = tNode else { cleanupWandDragState(); return }
                undoStack.append((nodeId, mState.copy())); let finalSelection = lastDragSelected; let geomIdx = currentDragElement; self.isApplyingRemoval = true
                
                DispatchQueue.global(qos: .userInitiated).async { [weak self, finalSelection, geomIdx, mState] in
                    guard let newGeo = MeshEraser.applyRemoval(selected: finalSelection, elementIndex: geomIdx, state: mState) else { DispatchQueue.main.async { self?.isApplyingRemoval = false }; return }
                    DispatchQueue.main.async { node.geometry = newGeo; self?.cleanupWandDragState(); self?.finalizeCurrentToolAction(); self?.isApplyingRemoval = false }
                }
            }
        }
        
        private func updateWandPreview(sensitivity: Float, state: MeshEditState) {
            let selected = MeshEraser.selectTriangles(seedTriangle: currentDragSeed, elementIndex: currentDragElement, sensitivity: sensitivity, state: state)
            lastDragSelected = selected
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.eraserPreviewNode?.geometry = MeshEraser.previewGeometry(selected: selected, elementIndex: self.currentDragElement, state: state)
                self.cropInfoBinding?.wrappedValue = "Highlighting \(selected.count) triangles..."
            }
        }
        
        private func finalizeCurrentToolAction() {
            DispatchQueue.main.async { [weak self] in
                let newCount = (self?.unifiedUndoCountBinding?.wrappedValue ?? 0) + 1
                self?.unifiedUndoCountBinding?.wrappedValue = newCount; self?.lastKnownUndoCount = newCount
            }
        }
        
        private func cleanupWandDragState() { currentDragNodeId = nil; lastDragSelected = [] }

        func undoLastStored() {
            guard let (nodeId, savedState) = undoStack.popLast() else { return }
            scnView?.scene?.rootNode.enumerateChildNodes { node, stop in
                if ObjectIdentifier(node) == nodeId {
                    if let restored = MeshEraser.rebuildGeometry(state: savedState) { node.geometry = restored }
                    self.meshStates[nodeId] = savedState; stop.pointee = true
                }
            }
        }

        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let orbit = cameraOrbitNode, let view = scnView else { return }
            if gesture.state == .began { panOrbitStartAngles = orbit.eulerAngles }
            else if gesture.state == .changed {
                orbit.eulerAngles.y = panOrbitStartAngles.y - Float(gesture.translation(in: view).x) * 0.005
                orbit.eulerAngles.x = max(-Float.pi/2.2, min(Float.pi/2.2, panOrbitStartAngles.x - Float(gesture.translation(in: view).y) * 0.005))
            }
        }
        
        var pinchStartScale: Float = 1.0
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let orbit = cameraOrbitNode, let camNode = orbit.childNodes.first else { return }
            if gesture.state == .began { pinchStartScale = camNode.position.z }
            else if gesture.state == .changed { camNode.position.z = max(modelWidth * 0.1, min(modelWidth * 5.0, pinchStartScale * (1.0 / Float(gesture.scale)))) }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { g is UIPinchGestureRecognizer || o is UIPinchGestureRecognizer }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive t: UITouch) -> Bool {
            guard activeToolBinding?.wrappedValue != nil, cleanModelActiveBinding?.wrappedValue == true else { return g != panGesture && g != toolGesture }
            if g == panGesture { return activeToolBinding?.wrappedValue == .crop }
            if g == toolGesture { return activeToolBinding?.wrappedValue == .wand || activeToolBinding?.wrappedValue == .brush }
            return true
        }
    }
}

// MARK: - STABLE MODEL STRUCTURE

struct GridItemData: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let status: String
    let iconName: String
    let subOptions: [GridItemData]?
    let targetViewId: String?
    
    var hasSubOptions: Bool {
        return subOptions != nil && !(subOptions?.isEmpty ?? true)
    }
    
    static func == (lhs: GridItemData, rhs: GridItemData) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.status == rhs.status
    }
}
struct NavigationRoute: Identifiable, Hashable {
    let id: String
}
struct ARFailedView: View {
    let error: String
    @ObservedObject var manager: CaptureManager
    var onBackToReview: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            Text("AR Scan Error")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            
            if !manager.capturedImageURLs.isEmpty, let onBack = onBackToReview {
                Button {
                    onBack()
                } label: {
                    Text("Back to Photo Review")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            
            Button {
                manager.reset()
            } label: {
                Text(manager.capturedImageURLs.isEmpty ? "Reset Scanner" : "Reset & Start Over")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(manager.capturedImageURLs.isEmpty ? Color.blue : Color.white.opacity(0.15))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}
// MARK: - INLINE 3D PREVIEW + FLOATING CONTROLS (DECOMPOSED)
struct ModelPreviewView: View {
    static let closeButtonID = UUID()

    let url: URL
    @ObservedObject var processor: GalleryProcessor
    
    @Binding var cleanModelActive: Bool
    @Binding var activeTool: EditingTool
    @Binding var debugViewMode: DebugViewMode
    
    @Binding var cropHeight: Float
    @Binding var cropInfo: String
    @Binding var yRange: (min: Float, max: Float)
    @Binding var showingCropped: Bool
    
    @Binding var eraserSensitivity: Float
    @Binding var brushRadius: Float
    @Binding var unifiedUndoCount: Int
    
    @Binding var calibrateScaleActive: Bool
    @Binding var calibPointA: SCNVector3?
    @Binding var calibPointB: SCNVector3?
    @Binding var showCalibSheet: Bool
    @Binding var modelScaleFactor: Float
    @Binding var modelBoundingBox: (w: Float, h: Float, d: Float)?
    
    @Binding var showQuickLook: Bool
    @Binding var modelURL: URL?
    @Binding var pressedItemId: UUID?
    
    var launchRoomExplorerAction: () -> Void
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ModelEditorView(
                url: url,
                cleanModelActive: $cleanModelActive,
                activeTool: $activeTool,
                debugViewMode: $debugViewMode,
                cropHeight: $cropHeight,
                cropInfo: $cropInfo,
                yRange: $yRange,
                showingCropped: $showingCropped,
                eraserSensitivity: $eraserSensitivity,
                brushRadius: $brushRadius,
                unifiedUndoCount: $unifiedUndoCount,
                onCropSaved: { newURL in
                    processor.state = .completed(newURL)
                },
                calibrateScaleActive: $calibrateScaleActive,
                calibPointA: $calibPointA,
                calibPointB: $calibPointB,
                onCalibPointsSet: { showCalibSheet = true },
                modelScaleFactor: $modelScaleFactor,
                modelBoundingBox: $modelBoundingBox
            )
            .ignoresSafeArea(edges: .top)
            
            VStack(spacing: 8) {
                if cleanModelActive && !cropInfo.isEmpty {
                    Text(cropInfo)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6).background(Material.thin))
                        .environment(\.colorScheme, .dark)
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5))
                        .padding(.top, 12)
                }
                
                if !cleanModelActive {
                    Picker("Debug View Mode", selection: $debugViewMode) {
                        ForEach(DebugViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(6)
                    .background(Color.black.opacity(0.4).background(Material.thin))
                    .environment(\.colorScheme, .dark)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }
                
                Spacer()
                
                if cleanModelActive && activeTool == .crop {
                    Text("↕ Drag to adjust crop height")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6).background(Material.thin))
                        .environment(\.colorScheme, .dark)
                        .foregroundStyle(Color("LightSaddle"))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 0.5))
                }
                
                if let bb = modelBoundingBox, !calibrateScaleActive {
                    HStack(spacing: 12) {
                        Label(String(format: "W: %.0fcm", bb.w), systemImage: "arrow.left.and.right")
                        Label(String(format: "H: %.0fcm", bb.h), systemImage: "arrow.up.and.down")
                        Label(String(format: "D: %.0fcm", bb.d), systemImage: "arrow.left.and.right.square")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color("LightSaddle"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5).background(Material.thin))
                    .environment(\.colorScheme, .dark)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color("ClassicSaddle").opacity(0.3), lineWidth: 0.5))
                }
                
                if calibrateScaleActive {
                    let msg: String = {
                        if calibPointA == nil { return " Tap Point A on model" }
                        if calibPointB == nil { return " Tap Point B on model" }
                        return "✅ Enter real size in sheet"
                    }()
                    Text(msg)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color("LightSaddle"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6).background(Material.thick))
                        .environment(\.colorScheme, .dark)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 0.5))
                }
                
                VStack(spacing: 12) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                    
                    HStack {
                        Text("3D Model Asset")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color("LightSaddle"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 4)
                    
                    if cleanModelActive {
                        editorToolboxView
                    } else {
                        mainActionsGridView
                    }
                }
                .padding(14)
                .background(Color.black.opacity(0.4).background(Material.thick))
                .environment(\.colorScheme, .dark)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                .padding([.horizontal, .bottom], 14)
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
            }
        }
    }
    
    
    @ViewBuilder
    private var editorToolboxView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("Tool", selection: $activeTool) {
                    Text(" Crop").tag(EditingTool.crop)
                    Text(" Wand").tag(EditingTool.wand)
                    Text(" Brush").tag(EditingTool.brush)
                }
                .pickerStyle(.segmented)
                
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.gray)
                    .scaleEffect(pressedItemId == Self.closeButtonID ? 0.9 : 1.0)
                    ._onButtonGesture(
                        pressing: { pressedItemId = $0 ? Self.closeButtonID : nil },
                        perform: { cleanModelActive = false }
                    )
            }
            
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.black.opacity(unifiedUndoCount > 0 ? 0.5 : 0.2))
                .background(Material.thin.opacity(unifiedUndoCount > 0 ? 1 : 0.3))
                .foregroundStyle(unifiedUndoCount > 0 ? Color("LightSaddle") : Color("LightSaddle").opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color("ClassicSaddle").opacity(unifiedUndoCount > 0 ? 0.3 : 0.1), lineWidth: 0.5))
                .scaleEffect(pressedItemId == Self.closeButtonID ? 0.96 : 1.0)
                .disabled(unifiedUndoCount == 0)
                ._onButtonGesture(
                    pressing: { isPressing in
                        if unifiedUndoCount > 0 { pressedItemId = isPressing ? Self.closeButtonID : nil }
                    },
                    perform: { if unifiedUndoCount > 0 { unifiedUndoCount -= 1 } }
                )
                
                if activeTool == .crop {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.6).background(Material.thin))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
                    ._onButtonGesture(
                        pressing: { _ in },
                        perform: { cropHeight = yRange.min }
                    )
                } else {
                    Text(activeTool == .wand ? " Tap surface" : " Paint mesh")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                }
            }
            
            if activeTool == .wand {
                VStack(spacing: 4) {
                    HStack {
                        Text("Wand Sensitivity").font(.caption2).foregroundStyle(.gray)
                        Spacer()
                        Text("\(Int(eraserSensitivity * 100))%").font(.caption2).bold().foregroundStyle(Color("LightSaddle"))
                    }
                    Slider(value: $eraserSensitivity, in: 0...1).tint(Color("ClassicSaddle"))
                }
            } else if activeTool == .brush {
                VStack(spacing: 4) {
                    HStack {
                        Text("Brush Size").font(.caption2).foregroundStyle(.gray)
                        Spacer()
                        Text("\(Int(brushRadius * 100)) cm").font(.caption2).bold().foregroundStyle(Color("LightSaddle"))
                    }
                    Slider(value: $brushRadius, in: 0.01...0.20).tint(Color("ClassicSaddle"))
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.4).background(Material.thin))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color("ClassicSaddle").opacity(0.2), lineWidth: 0.5))
    }
    
    @ViewBuilder
    private var mainActionsGridView: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                HStack {
                    Image(systemName: "paintbrush.pointed.fill").font(.title3)
                    Text("Clean Mesh").font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.black.opacity(0.6).background(Material.thin))
                .foregroundStyle(Color("LightSaddle"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color("ClassicSaddle").opacity(0.4), lineWidth: 0.5))
                ._onButtonGesture(pressing: { _ in }, perform: { cleanModelActive = true })
                
                HStack {
                    Image(systemName: calibrateScaleActive ? "xmark.circle" : "ruler").font(.title3)
                    Text(calibrateScaleActive ? "Cancel" : "Calibrate").font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.black.opacity(0.6).background(Material.thin))
                .foregroundStyle(calibrateScaleActive ? .red : Color("LightSaddle"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(calibrateScaleActive ? Color.red.opacity(0.4) : Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                ._onButtonGesture(pressing: { _ in }, perform: {
                    if calibrateScaleActive {
                        calibrateScaleActive = false; calibPointA = nil; calibPointB = nil
                    } else { calibrateScaleActive = true }
                })
                
                HStack {
                    Image(systemName: "figure.walk").font(.title3)
                    Text("Explore Room").font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.black.opacity(0.6).background(Material.thin))
                .foregroundStyle(Color("LightSaddle"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                ._onButtonGesture(pressing: { _ in }, perform: { launchRoomExplorerAction() })
                
                HStack {
                    Image(systemName: "arkit").font(.title3)
                    Text("AR Preview").font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.black.opacity(0.6).background(Material.thin))
                .foregroundStyle(Color("LightSaddle"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                ._onButtonGesture(pressing: { _ in }, perform: { modelURL = url; showQuickLook = true })
            }
            
            HStack(spacing: 10) {
                ShareLink(item: url) {
                    Label("Share Model", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color("LightSaddle"))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6).background(Material.thin))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                }
                
                if showingCropped {
                    Button { showingCropped = false } label: {
                        Label("Reset Crop", systemImage: "arrow.uturn.backward.circle")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.4).background(Material.thin))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                
                Text("\(Image(systemName: "chevron.left")) Exit")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color("LightSaddle"))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6).background(Material.thin))
                    .foregroundStyle(Color("LightSaddle"))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color("ClassicSaddle").opacity(0.25), lineWidth: 0.5))
                    ._onButtonGesture(pressing: { _ in }, perform: {
                        showQuickLook = false; cleanModelActive = false; cropHeight = 0; processor.reset()
                    })
            }
            .padding(.top, 4)
        }
    }
}
// MARK: - SYSTEM CANVAS PREVIEWS

#Preview("Tools Main Grid Layout") {
    NavigationStack {
        ToolsGridView()
    }
}
