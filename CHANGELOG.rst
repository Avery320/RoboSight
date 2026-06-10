CHANGELOG
=========

Unreleased
----------

建立 RoboSight iOS App 專案。｜2026.06.07
----------
- 以 `swift-ros2` 作為 ROS 2 通訊基礎：
    - 透過 Zenoh router 連線 ROS 2。
    - 加入 Router Address、Router Port、Domain ID 與 Full Address 顯示欄位。
    - 建立 `/robosight/status` publisher。發送 `std_msgs/msg/String` 狀態訊息，內容包含 topic 名稱與目前時間。
- 建立相機功能：
    - 使用 `sensor_msgs/msg/CompressedImag` 發送。

- UI：
    - 鎖定畫面為 `直式`。
