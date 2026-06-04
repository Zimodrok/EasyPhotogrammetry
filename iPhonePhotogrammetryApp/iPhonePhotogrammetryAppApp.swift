//
//  iPhonePhotogrammetryAppApp.swift
//  iPhonePhotogrammetryApp
//
//  Created by Cyril on 22.12.2025.
//

import SwiftUI

@main
struct VisionScan3DApp: App {
    @StateObject private var transferEngine = TransferEngine()
    @StateObject private var captureManager = CaptureManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(transferEngine)
        }
    }
}
