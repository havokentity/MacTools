import Foundation
import Darwin

private typealias IOHIDEventSystemClient = OpaquePointer
private typealias IOHIDServiceClient = OpaquePointer
private typealias IOHIDEvent = OpaquePointer

private typealias IOHIDEventSystemClientCreate = @convention(c) (CFAllocator?) -> IOHIDEventSystemClient?
private typealias IOHIDEventSystemClientCopyServices = @convention(c) (IOHIDEventSystemClient?) -> Unmanaged<CFArray>?
private typealias IOHIDServiceClientCopyEvent = @convention(c) (IOHIDServiceClient?, Int64, Int32, Int64) -> IOHIDEvent?
private typealias IOHIDEventGetFloatValue = @convention(c) (IOHIDEvent?, Int64) -> Double
private typealias IOHIDServiceClientCopyProperty = @convention(c) (IOHIDServiceClient?, CFString) -> Unmanaged<CFTypeRef>?

final class ThermalSensorReader {
    private static let temperatureEventType: Int64 = 15
    private static let temperatureEventField: Int64 = temperatureEventType << 16

    private let createClient: IOHIDEventSystemClientCreate?
    private let copyServices: IOHIDEventSystemClientCopyServices?
    private let copyEvent: IOHIDServiceClientCopyEvent?
    private let getFloatValue: IOHIDEventGetFloatValue?
    private let copyProperty: IOHIDServiceClientCopyProperty?
    private let client: IOHIDEventSystemClient?

    /// The die-temperature services, found once and reused for every read after that.
    ///
    /// `IOHIDEventSystemClientCopyServices` enumerates every HID service on the machine and the
    /// `Product` lookup is one IPC round trip per service — well over a hundred of them on an
    /// Apple silicon Mac — which is far too much to repeat once a second, on the main thread, for
    /// a set of built-in sensors that does not change while the machine is up. `nil` until an
    /// enumeration has succeeded; one that finds no sensors at all (Intel, a VM) is cached as
    /// empty so those machines stop paying for the walk too.
    private var temperatureServices: [IOHIDServiceClient]?
    /// The array the services above were copied out of, held so that they stay alive: the
    /// pointers are borrowed from it, and letting it go would release them.
    private var temperatureServicesOwner: CFArray?

    init() {
        let handle = dlopen(nil, RTLD_NOW)
        let createClient: IOHIDEventSystemClientCreate? = Self.symbol("IOHIDEventSystemClientCreate", from: handle)
        self.createClient = createClient
        copyServices = Self.symbol("IOHIDEventSystemClientCopyServices", from: handle)
        copyEvent = Self.symbol("IOHIDServiceClientCopyEvent", from: handle)
        getFloatValue = Self.symbol("IOHIDEventGetFloatValue", from: handle)
        copyProperty = Self.symbol("IOHIDServiceClientCopyProperty", from: handle)
        client = createClient?(kCFAllocatorDefault)
    }

    deinit {
        if let client {
            Self.release(client)
        }
    }

    func cpuTemperatureCelsius() -> Double? {
        guard let copyEvent,
              let getFloatValue,
              let services = temperatureServicesIfAvailable() else {
            return nil
        }

        var temperatures: [Double] = []
        var eventCount = 0

        for service in services {
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0) else {
                continue
            }
            defer {
                Self.release(event)
            }

            eventCount += 1

            let celsius = getFloatValue(event, Self.temperatureEventField)
            guard celsius > 0, celsius < 130 else {
                continue
            }

            temperatures.append(celsius)
        }

        // Every cached service declining to vend an event means the proxies have gone stale — the
        // event system was torn down and rebuilt underneath them — so the cache is dropped and the
        // next read enumerates afresh rather than reporting no temperature for good.
        if eventCount == 0, !services.isEmpty {
            temperatureServices = nil
            temperatureServicesOwner = nil
        }

        guard !temperatures.isEmpty else {
            return nil
        }

        return temperatures.reduce(0, +) / Double(temperatures.count)
    }

    /// The cached die-temperature services, enumerating them on the first call that can.
    private func temperatureServicesIfAvailable() -> [IOHIDServiceClient]? {
        if let temperatureServices {
            return temperatureServices
        }

        guard let copyServices,
              let copyProperty,
              let client,
              let services = copyServices(client)?.takeRetainedValue() else {
            return nil
        }

        var matched: [IOHIDServiceClient] = []

        for index in 0..<CFArrayGetCount(services) {
            guard let rawService = CFArrayGetValueAtIndex(services, index) else {
                continue
            }

            let service = OpaquePointer(rawService)
            let product = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            guard product?.localizedCaseInsensitiveContains("tdie") == true else {
                continue
            }

            matched.append(service)
        }

        temperatureServices = matched
        temperatureServicesOwner = services

        return matched
    }

    private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer?) -> T? {
        guard let pointer = dlsym(handle, name) else {
            return nil
        }

        return unsafeBitCast(pointer, to: T.self)
    }

    private static func release(_ pointer: OpaquePointer) {
        Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(pointer)).release()
    }
}
