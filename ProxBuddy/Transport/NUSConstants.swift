import CoreBluetooth

enum NUS {
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// PM5 → phone (subscribe for notifications)
    nonisolated(unsafe) static let txCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    /// phone → PM5 (write without response)
    nonisolated(unsafe) static let rxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let targetMTU = 512
}
