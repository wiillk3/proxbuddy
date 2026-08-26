import CoreBluetooth

enum PM5BLE {
    /// Official PM5 ESP32-C2 BWM SPP Service UUID (16-bit 0xAE86)
    nonisolated(unsafe) static let sppServiceUUID = CBUUID(string: "AE86")
    
    /// Official PM5 ESP32-C2 BWM SPP Data Characteristic UUID (16-bit 0xAE88)
    /// Handles both Uplink (write) and Downlink (notify)
    nonisolated(unsafe) static let sppDataCharUUID = CBUUID(string: "AE88")
    
    /// Standard BLE Battery Service UUID (16-bit 0x180F)
    nonisolated(unsafe) static let batteryServiceUUID = CBUUID(string: "180F")
    
    /// Standard BLE Battery Level Characteristic UUID (16-bit 0x2A19)
    nonisolated(unsafe) static let batteryLevelCharUUID = CBUUID(string: "2A19")
    
    // Legacy Nordic UART Service (NUS) fallback definitions
    nonisolated(unsafe) static let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) static let nusTxCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    nonisolated(unsafe) static let nusRxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    
    static let targetMTU = 512
}

// Keep enum NUS as typealias for backwards compatibility if referenced elsewhere
typealias NUS = PM5BLE
