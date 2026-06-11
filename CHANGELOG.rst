CHANGELOG
=========

Unreleased
----------

0.1.0
----------
- 以 `swift-ros2` 作為 ROS 2 通訊基礎：
    - 透過 Zenoh router 連線 ROS 2。
    - 加入 Router Address、Router Port、Domain ID 與 Full Address 顯示欄位。
    - 建立 `/robosight/status` publisher。發送 `std_msgs/msg/String` 狀態訊息，內容包含 topic 名稱與目前時間。
- 建立相機功能：
    - 使用 `sensor_msgs/msg/CompressedImag` 發送。
- 建立 urdf 載入：
    - 新增 "Robot" Tab 用於顯示機器人模型。
    - 訂閱 `/joint_states`。
    - https://github.com/Avery320/robosim_library.git 為 urdf 來源。
    - 目前只支援 .stl 模型，其他模型先顯示載入錯誤，不載入。
- UI：
    - 鎖定畫面為 `直式`。
