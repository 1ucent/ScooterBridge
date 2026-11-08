//
//  ScooterBridgeApp.swift
//  ScooterBridge
//
//  Turns an iPhone into a Bluetooth LE gateway on the local network.
//
//  The phone has a real Bluetooth radio; a laptop usually does not (or cannot
//  reach BLE from inside a container). This app runs a tiny HTTP server and
//  relays requests to CoreBluetooth, so anything that can speak HTTP can drive
//  a BLE peripheral through the phone.
//

import SwiftUI

@main
struct ScooterBridgeApp: App {

    @StateObject private var bridge = BLEBridge.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
                .preferredColorScheme(.dark)
                .onAppear { bridge.start() }
        }
    }
}

struct ContentView: View {

    @EnvironmentObject private var bridge: BLEBridge

    var body: some View {
        NavigationStack {
            List {

                Section("Server") {
                    row("Status", bridge.isRunning ? "running" : "stopped")
                    row("Port", "\(bridge.port)")
                    row("This phone's IP", bridge.localIPAddress ?? "unknown")
                    row("Bluetooth", bridge.bluetoothStateText)
                }

                Section("Peripheral") {
                    row("Connected", bridge.connectedName ?? "none")
                    row("UUID", bridge.connectedUUID ?? "-")
                    row("Notifications received", "\(bridge.rxCount)")
                }

                Section("Try it from your computer") {
                    Text("""
                    curl http://\(bridge.localIPAddress ?? "<phone-ip>"):\(bridge.port)/status
                    """)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                }

                Section {
                    Button(bridge.isRunning ? "Restart server" : "Start server") {
                        bridge.stop()
                        bridge.start()
                    }
                }
            }
            .navigationTitle("ScooterBridge")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
