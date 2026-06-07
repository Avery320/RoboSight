# RoboSight

RoboSight 是用於驗證 iOS 與 ROS 2 通訊的最小 App。  
目前第一階段目標是透過 `swift-ros2` 與 Zenoh 連線到 ROS 2，並發布連線狀態訊息。

## 目前功能

- iOS App 連線到 ROS 2 Zenoh router
- 建立 ROS 2 publisher：`/robosight/status`
- 發送 `std_msgs/msg/String` 狀態訊息，內容為 topic 名稱與目前時間
- 支援 iOS Simulator 與實體 iPhone / iPad 測試

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
```


