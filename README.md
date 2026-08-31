# RoboSight

RoboSight 是用於驗證 iOS 裝置作為 ROS 2 外部感測器的 App。
目前已完成 Zenoh 連線與相機影像串流。

## 目前功能

- iOS App 連線到 ROS 2 Zenoh router
  - 發送 `/robosight/status`
  - 記住最後使用的 Router Address
- IMU
  - 整合至 `/tf`
- 相機功能
  - 發送 `/robosight/camera/image_raw/compressed`
  - 發送 `/robosight/camera/camera_info`
  - 相機影像固定以直式 portrait 輸出
- robot
  - 載入 [robosim_library](https://github.com/Avery320/robosim_library) 機械手臂
  - ***目前只支援 `.stl` 模型，其他模型無法成功載入***
  - 可訂閱 `joint_states`
- Teleoperation
  - 以 `sensor_msgs/msg/Joy` 發送 `/joy`
  - 選擇 AMR 後，需在 Settings 明確啟動 Teleoperation 才開始發布
  - 20 Hz autorepeat，並在放開搖桿、切換模式、App 進入背景或斷線時歸零
  - AMR profile：`axes[0]` 左轉為正、`axes[3]` 前進為正、`buttons[0]` 為 enable

### RoboSight 
| Start Page | Camera | Robot |
|---|---|---|
|![](assets/robosight.PNG) |![](assets/camera.PNG) | ![](assets/robot.PNG) |

### ROS integration on [roboSim](https://github.com/Avery320/robot-demo)
![ROS integration on roboSim](assets/ros_integration.png)

## App 設定

### Xcode Simulator：

```text
Router Address: 127.0.0.1
Router Port: 7447
Domain ID: 0
```

### 實體裝置：

```text
Router Address: <Mac 或 ROS Docker host 的區網 IP>
Router Port: 7447
Domain ID: 0
```

注意：Xcode Preview 只適合檢查 UI，不能用來驗證 ROS 連線。請使用 Xcode Run 啟動 Simulator 或實體裝置。

## ROS 2 Setup

### Install Zenoh RMW：
```bash
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ros-jazzy-rmw-zenoh-cpp
```

### 啟動 Zenoh router：
```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROS_DOMAIN_ID=0
ros2 run rmw_zenoh_cpp rmw_zenohd
```

### Test：
```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROS_DOMAIN_ID=0

ros2 topic info /robosight/status --verbose
ros2 topic echo /robosight/status std_msgs/msg/String
ros2 topic hz /robosight/camera/image_raw/compressed
ros2 topic hz /robosight/camera/camera_info
ros2 topic info /joy --verbose
ros2 topic echo /joy
ros2 topic hz /joy
```

### Rviz2：
```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
export ROS_DOMAIN_ID=0
rviz2
```
