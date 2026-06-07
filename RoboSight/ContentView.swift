import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: ConnectionViewModel

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: ConnectionViewModel())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Router Address") {
                        TextField("Router Address", text: $viewModel.routerHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    LabeledContent("Router Port") {
                        TextField("Router Port", text: $viewModel.routerPort)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }

                    LabeledContent("Domain ID") {
                        TextField("Domain ID", text: $viewModel.domainId)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }

                    LabeledContent("Full Address") {
                        Text(viewModel.fullRouterAddress)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Full Address is the Zenoh locator used by swift-ros2. Simulator can use 127.0.0.1; physical devices should use the Mac or ROS Docker host LAN IP.")
                }

                Section {
                    LabeledContent("Topic") {
                        Text(viewModel.statusTopic)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    LabeledContent("Status") {
                        Text(viewModel.state.title)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.state.isBusy {
                        ProgressView("\(viewModel.state.title)...")
                    }

                    if let detail = viewModel.state.detail {
                        Text(detail)
                            .foregroundStyle(.red)
                    }

                    if let message = viewModel.lastStatusMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("ROS 2")
                }

                Section {
                    Button("Connect") {
                        Task {
                            await viewModel.connect()
                        }
                    }
                    .disabled(!viewModel.canConnect)

                    Button("Disconnect", role: .destructive) {
                        Task {
                            await viewModel.disconnect()
                        }
                    }
                    .disabled(!viewModel.canDisconnect)
                }
            }
            .navigationTitle("RoboSight")
        }
    }
}

#Preview {
    ContentView()
}
