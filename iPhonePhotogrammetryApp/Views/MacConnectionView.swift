import SwiftUI
import Network

struct MacConnectionView: View {
    @EnvironmentObject var engine: TransferEngine
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            // Dark glassmorphic background
            Color.black.ignoresSafeArea()
            
            // Subtle animated background pulse
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .scaleEffect(engine.state == .searching ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: engine.state)
            
            VStack(spacing: 30) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.gray.opacity(0.7))
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                
                Spacer()
                
                // State Icon
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                        .frame(width: 140, height: 140)
                    
                    if engine.state == .searching {
                        Circle()
                            .trim(from: 0, to: 0.8)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 140, height: 140)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: engine.state)
                    }
                    
                    Image(systemName: iconForState())
                        .font(.system(size: 60, weight: .light))
                        .foregroundStyle(colorForState())
                        .symbolEffect(.pulse, options: .repeating, isActive: engine.state == .searching)
                }
                .padding(.bottom, 20)
                
                // Status Text
                Text(titleForState())
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                
                Text(subtitleForState())
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                Spacer()
                
                // Action Button
                if case .connected = engine.state {
                    Button(action: { dismiss() }) {
                        Text("Ready to Send")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 50)
                } else {
                    Button(action: {
                        if engine.state == .searching {
                            engine.stop()
                        } else {
                            engine.connectToMac()
                        }
                    }) {
                        Text(engine.state == .searching ? "Cancel" : "Connect")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(engine.state == .searching ? .white : .black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(engine.state == .searching ? Color.white.opacity(0.2) : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 50)
                }
            }
        }
        .onAppear {
            if engine.state == .idle || engine.state == .failed("") {
                engine.connectToMac()
            }
        }
    }
    
    private func iconForState() -> String {
        switch engine.state {
        case .idle: return "macbook.and.iphone"
        case .searching: return "wave.3.right"
        case .connected: return "macbook.and.iphone"
        case .transferring: return "arrow.up.circle.fill"
        case .processingOnMac: return "cpu"
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "macbook.and.iphone"
        }
    }
    
    private func colorForState() -> Color {
        switch engine.state {
        case .connected, .success: return .green
        case .failed: return .red
        case .processingOnMac: return .cyan
        default: return .white
        }
    }
    
    private func titleForState() -> String {
        switch engine.state {
        case .idle: return "Connect to Mac"
        case .searching: return "Searching..."
        case .connected(let peer): return "Connected"
        case .transferring: return "Transferring"
        case .processingOnMac: return "Processing on Mac"
        case .success: return "Transferred"
        case .failed: return "Connection Failed"
        default: return "Mac Connection"
        }
    }
    
    private func subtitleForState() -> String {
        switch engine.state {
        case .idle: return "Ensure Mac Vision Builder is open on your Mac."
        case .searching: return "Looking for Mac Vision Builder on the local network."
        case .connected(let peer): return "Ready to send scans to \(peer)."
        case .transferring(_, let detail): return detail
        case .processingOnMac: return "Mac is processing photogrammetry and merging geometry."
        case .success: return "Transfer complete."
        case .failed(let err): return err
        default: return ""
        }
    }
}

struct MacTransferOverlayView: View {
    let engineState: TransferEngine.State
    let isZipping: Bool
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.purple.opacity(0.3), lineWidth: 2)
                        .frame(width: 120, height: 120)
                    
                    if isZipping || engineState == .searching || engineState == .transferring(progress: 0, detail: "") {
                        Circle()
                            .trim(from: 0, to: 0.8)
                            .stroke(Color.purple, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isZipping)
                    }
                    
                    if case .transferring(let p, _) = engineState {
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(Color.purple, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut, value: p)
                    }
                    
                    Image(systemName: iconForState())
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.purple)
                        .symbolEffect(.pulse, options: .repeating, isActive: isZipping || engineState == .searching)
                }
                
                VStack(spacing: 8) {
                    Text(titleForState())
                        .font(.headline)
                        .foregroundStyle(.white)
                    
                    Text(subtitleForState())
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .padding(30)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .purple.opacity(0.2), radius: 30, x: 0, y: 10)
            .padding(.horizontal, 30)
        }
    }
    
    private func iconForState() -> String {
        if isZipping { return "doc.zipper" }
        switch engineState {
        case .searching: return "wave.3.right"
        case .connected: return "macbook.and.iphone"
        case .transferring: return "arrow.up.circle.fill"
        case .processingOnMac: return "cpu"
        default: return "macbook.and.iphone"
        }
    }
    
    private func titleForState() -> String {
        if isZipping { return "Preparing Data..." }
        switch engineState {
        case .searching: return "Searching for Mac..."
        case .connected: return "Connected"
        case .transferring: return "Beaming to Mac"
        case .processingOnMac: return "Processing on Mac..."
        default: return "Connecting..."
        }
    }
    
    private func subtitleForState() -> String {
        if isZipping { return "Compressing high-resolution LiDAR scans." }
        switch engineState {
        case .searching: return "Ensure Mac Vision Builder is open."
        case .connected(let peer): return "Ready to send to \(peer)."
        case .transferring(_, let detail): return detail
        case .processingOnMac: return "Mac is baking geometry and photogrammetry models."
        default: return ""
        }
    }
}
