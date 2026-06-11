import SwiftUI

/// Robot 頁籤，顯示從 robosim_library 下載並由 RoboSight URDF 載入的機器人模型。
struct RobotView: View {
    @ObservedObject var robotViewModel: RobotViewModel
    let isActive: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let runtime = robotViewModel.runtime, isActive {
                    RobotRealityView(
                        runtime: runtime,
                        jointPositions: robotViewModel.jointPositions
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else if robotViewModel.runtime != nil {
                    ContentUnavailableView {
                        Label("Robot Paused", systemImage: "pause.circle")
                    } description: {
                        Text("Robot scene only runs while the Robot tab is active.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("Robot", systemImage: "cube.box")
                    } description: {
                        if let description = emptyStateDescription {
                            Text(description)
                        }
                    } actions: {
                        if robotViewModel.selectedRobot != nil {
                            Button("Load Robot") {
                                robotViewModel.loadSelectedRobot()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!robotViewModel.canLoadSelectedRobot)
                        }
                    }
                }
            }
            .navigationTitle("Robot")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await robotViewModel.refreshRobotListIfNeeded()
            }
        }
    }

    private var emptyStateDescription: String? {
        if let errorMessage = robotViewModel.robotLoadError {
            return errorMessage
        }

        if robotViewModel.selectedRobot == nil {
            return "Select a robot model from Settings."
        }

        if robotViewModel.selectionState.isLoading {
            return robotViewModel.selectionState.title
        }

        if let validationMessage = robotViewModel.selectionState.message,
           !robotViewModel.selectionState.isValid {
            return validationMessage
        }

        return nil
    }
}



#Preview {
    RobotView(robotViewModel: RobotViewModel(), isActive: true)
}
