//import SwiftUI
//import RealityKit
//import ARKit
//
//// MARK: - Simple App State
//@MainActor
//final class AppState: ObservableObject {
//    let captureManager = CaptureManager()
//}
//
//// MARK: - Main View
//struct ContentView: View {
//    @StateObject private var appState = AppState()
//    
//    var body: some View {
//        ZStack {
//                // AR Camera View
//                ARCameraView()
//                    .ignoresSafeArea()
//            // UI Overlay
//            VStack {
//                // Top status
//                TopStatusBar(state: appState.captureManager.state)
//                    .padding()
//                
//                Spacer()
//                
//                // Bottom controls
//                BottomControls(appState: appState)
//                    .padding(.bottom, 40)
//            }
//        }
//    }
//}
//
//// MARK: - AR Camera View
////struct ARCameraView: UIViewRepresentable {
////    func makeUIView(context: Context) -> ARView {
////        let arView = ARView(frame: .zero)
////        let config = ARWorldTrackingConfiguration()
////        config.planeDetection = [.horizontal]
////        arView.session.run(config)
////        return arView
////    }
////    
////    func updateUIView(_ uiView: ARView, context: Context) {}
////}
//
//// MARK: - Top Status Bar
//struct TopStatusBar: View {
//    let state: CaptureState
//    
//    var body: some View {
//        HStack {
//            Circle()
//                .fill(statusColor)
//                .frame(width: 10, height: 10)
//            
//            Text(statusText)
//                .font(.headline)
//                .foregroundStyle(.white)
//            
//            Spacer()
//        }
//        .padding()
//        .background(.ultraThinMaterial)
//        .clipShape(RoundedRectangle(cornerRadius: 12))
//    }
//    
//    private var statusColor: Color {
//        switch state {
//        case .idle: return .gray
//        case .capturing: return .green
//        case .processing: return .orange
//        case .completed: return .blue
//        case .failed: return .red
//        }
//    }
//    
//    private var statusText: String {
//        switch state {
//        case .idle: return "Ready"
//        case .capturing: return "Taking Photos"
//        case .processing: return "Processing..."
//        case .completed: return "Complete!"
//        case .failed: return "Error"
//        }
//    }
//}
//
//// MARK: - Bottom Controls/
////struct BottomControls: View {
////    @ObservedObject var appState: AppState
////    
////    var body: some View {
////        Group {
////            switch appState.captureManager.state {
////            case .idle:
////                IdleView(manager: appState.captureManager)
////                
////            case .capturing:
////                CapturingView(manager: appState.captureManager)
////                
////            case .processing(let progress):
////                ProcessingView(progress: progress)
////                
////            case .completed(let url):
////                CompletedView(url: url, manager: appState.captureManager)
////                
////            case .failed(let error):
////                FailedView(error: error, manager: appState.captureManager)
////            }
////        }
////    }
////}
//
//// MARK: - Idle View
//struct IdleView: View {
//    @ObservedObject var manager: CaptureManager
//    
//    var body: some View {
//        VStack(spacing: 20) {
//            Text("Point camera at object")
//                .font(.title2)
//                .foregroundStyle(.white)
//            
//            Button {
//                manager.startCapture()
//            } label: {
//                HStack {
//                    Image(systemName: "camera.fill")
//                    Text("Start Scanning")
//                        .fontWeight(.semibold)
//                }
//                .frame(maxWidth: .infinity)
//                .padding()
//                .background(Color.blue)
//                .foregroundStyle(.white)
//                .clipShape(RoundedRectangle(cornerRadius: 16))
//            }
//        }
//        .padding(.horizontal)
//    }
//}
//
//// MARK: - Capturing View
//struct CapturingView: View {
//    @ObservedObject var manager: CaptureManager
//    
//    var body: some View {
//        VStack(spacing: 20) {
//            // Statistics
//            VStack(spacing: 12) {
//                Text("Photos: \(manager.statistics.imagesCaptured)")
//                    .font(.title)
//                    .fontWeight(.bold)
//                    .foregroundStyle(.white)
//                
//                Text("Minimum: 6 photos")
//                    .font(.subheadline)
//                    .foregroundStyle(.white.opacity(0.8))
//                
//                ProgressView(value: manager.statistics.coveragePercentage)
//                    .tint(.blue)
//            }
//            .padding()
//            .background(.ultraThinMaterial)
//            .clipShape(RoundedRectangle(cornerRadius: 16))
//            
//            // Buttons
//            HStack(spacing: 16) {
//                // Capture button
//                Button {
//                    manager.capturePhoto()
//                } label: {
//                    Image(systemName: "camera.fill")
//                        .font(.largeTitle)
//                        .foregroundStyle(.white)
//                        .frame(width: 80, height: 80)
//                        .background(Color.blue)
//                        .clipShape(Circle())
//                }
//                
//                // Stop button
//                Button {
//                    Task {
//                        try? await manager.stopCapture()
//                    }
//                } label: {
//                    VStack {
//                        Image(systemName: "checkmark.circle.fill")
//                            .font(.title)
//                        Text("Done")
//                            .font(.caption)
//                    }
//                    .foregroundStyle(.white)
//                    .frame(width: 80, height: 80)
//                    .background(Color.green)
//                    .clipShape(RoundedRectangle(cornerRadius: 16))
//                }
//                .disabled(manager.statistics.imagesCaptured < 6)
//                .opacity(manager.statistics.imagesCaptured < 6 ? 0.5 : 1.0)
//            }
//        }
//        .padding(.horizontal)
//    }
//}
//
//// MARK: - Processing View
//struct ProcessingView: View {
//    let progress: Double
//    
//    var body: some View {
//        VStack(spacing: 20) {
//            ProgressView(value: progress)
//                .scaleEffect(1.5)
//                .tint(.blue)
//            
//            Text("Processing: \(Int(progress * 100))%")
//                .font(.headline)
//                .foregroundStyle(.white)
//            
//            Text("This may take 5-10 minutes")
//                .font(.subheadline)
//                .foregroundStyle(.white.opacity(0.8))
//        }
//        .padding()
//        .background(.ultraThinMaterial)
//        .clipShape(RoundedRectangle(cornerRadius: 16))
//        .padding(.horizontal)
//    }
//}
//
//// MARK: - Completed View
//struct CompletedView: View {
//    let url: URL
//    @ObservedObject var manager: CaptureManager
//    
//    var body: some View {
//        VStack(spacing: 20) {
//            Image(systemName: "checkmark.circle.fill")
//                .font(.system(size: 60))
//                .foregroundStyle(.green)
//            
//            Text("3D Model Ready!")
//                .font(.title2)
//                .fontWeight(.bold)
//                .foregroundStyle(.white)
//            
//            Text(url.lastPathComponent)
//                .font(.caption)
//                .foregroundStyle(.white.opacity(0.8))
//            
//            Button {
//                manager.reset()
//            } label: {
//                Text("Scan Another Object")
//                    .fontWeight(.semibold)
//                    .frame(maxWidth: .infinity)
//                    .padding()
//                    .background(Color.blue)
//                    .foregroundStyle(.white)
//                    .clipShape(RoundedRectangle(cornerRadius: 16))
//            }
//        }
//        .padding()
//        .background(.ultraThinMaterial)
//        .clipShape(RoundedRectangle(cornerRadius: 16))
//        .padding(.horizontal)
//    }
//}
//
//// MARK: - Failed View
//struct FailedView: View {
//    let error: String
//    @ObservedObject var manager: CaptureManager
//    
//    var body: some View {
//        VStack(spacing: 20) {
//            Image(systemName: "exclamationmark.triangle.fill")
//                .font(.system(size: 60))
//                .foregroundStyle(.red)
//            
//            Text("Error")
//                .font(.title2)
//                .fontWeight(.bold)
//                .foregroundStyle(.white)
//            
//            Text(error)
//                .font(.subheadline)
//                .foregroundStyle(.white.opacity(0.8))
//                .multilineTextAlignment(.center)
//            
//            Button {
//                manager.reset()
//            } label: {
//                Text("Try Again")
//                    .fontWeight(.semibold)
//                    .frame(maxWidth: .infinity)
//                    .padding()
//                    .background(Color.blue)
//                    .foregroundStyle(.white)
//                    .clipShape(RoundedRectangle(cornerRadius: 16))
//            }
//        }
//        .padding()
//        .background(.ultraThinMaterial)
//        .clipShape(RoundedRectangle(cornerRadius: 16))
//        .padding(.horizontal)
//    }
//}
