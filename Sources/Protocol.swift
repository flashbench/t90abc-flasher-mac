// Протокол обновления ALIENTEK T90 по USB-HID (как в официальной утилите ATK_T90.exe).
//
// Кадр:   [адрес][команда][номер][длина][данные…][контрольная сумма]
// Адрес:  0xAF — от компьютера, 0xDF — ответ паяльника.
// Сумма:  (256 - сумма всех байтов кадра % 256) & 0xFF.
// Файл .atk: блоки «заголовок 13 байт + данные»; данные уже зашифрованы,
// паяльник расшифровывает их сам.

import AppKit
import IOKit.hid

enum Proto {
    static let vid = 0x19F5
    static let pid = 0x3245
    static let devType: UInt16 = 0x0208
    static let addrHost: UInt8 = 0xAF
    static let addrDev: UInt8 = 0xDF
    static let reportSize = 64

    static let getDevInfo: UInt8 = 0x10
    static let setFwInfo: UInt8 = 0x11
    static let startSend: UInt8 = 0x12
    static let sendData: UInt8 = 0x13
    static let sendEnd: UInt8 = 0x14
    static let finish: UInt8 = 0x15  // с байтом 0xA0 — завершить и запустить прошивку

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return UInt8((256 - sum % 256) & 0xFF)
    }

    static func frame(_ cmd: UInt8, _ seq: UInt8, _ data: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [addrHost, cmd, seq, UInt8(data.count)] + data
        body.append(checksum(body))
        return body
    }

    /// Данные ответа или nil, если это не ответ паяльника.
    static func parse(_ buf: [UInt8]) -> [UInt8]? {
        var b = buf
        if b.count > 1 && b[0] != addrDev && b[1] == addrDev { b.removeFirst() }
        guard b.count >= 6, b[0] == addrDev else { return nil }
        let n = Int(b[3])
        guard b.count >= n + 6 else { return nil }
        return Array(b[4..<(4 + n)])
    }
}

/// Ошибка с ключом перевода (см. Strings.swift).
struct FlashError: Error {
    let key: String
    var args: [CVarArg] = []
}

struct DevInfo {
    var devType: UInt16
    var hwVer: UInt8
    var appVer: UInt8
    var runFlag: UInt8
    var sn: String
    var date: String
    var inBootloader: Bool { runFlag >= 0xB0 }

    init?(_ d: [UInt8]) {
        guard d.count >= 21 else { return nil }
        devType = UInt16(d[0]) | UInt16(d[1]) << 8
        hwVer = d[2]; appVer = d[3]; runFlag = d[5]
        sn = d[6..<18].map { String(format: "%02X", $0) }.joined()
        date = String(format: "20%02d-%02d-%02d", d[18], d[19], d[20])
    }
}

struct FwBlock {
    var header: [UInt8]   // 13 байт: dev_type, hw, app, тип файла, размер пакета, размер, год, месяц, день
    var data: [UInt8]
    var devType: UInt16 { UInt16(header[0]) | UInt16(header[1]) << 8 }
    var fileType: UInt8 { header[4] }
    var chunk: Int { Int(header[5]) }
    var isLogo: Bool { fileType == 0xA1 }
    var date: String { String(format: "20%02d-%02d-%02d", header[10], header[11], header[12]) }
}

func parseATK(_ raw: [UInt8]) throws -> [FwBlock] {
    var blocks: [FwBlock] = []
    var pos = 0
    while pos < raw.count {
        guard pos + 13 <= raw.count else { throw FlashError(key: "err.badFile") }
        let hdr = Array(raw[pos..<pos + 13])
        let size = Int(hdr[6]) | Int(hdr[7]) << 8 | Int(hdr[8]) << 16 | Int(hdr[9]) << 24
        pos += 13
        guard hdr[5] > 0, hdr[5] <= 58, pos + size <= raw.count else { throw FlashError(key: "err.badFile") }
        blocks.append(FwBlock(header: hdr, data: Array(raw[pos..<pos + size])))
        pos += size
    }
    if blocks.isEmpty { throw FlashError(key: "err.badFile") }
    return blocks
}

/// Известные версии по дате сборки (из списка изменений ALIENTEK).
/// Так же версия показывается в меню паяльника (V:1.1.6).
let knownVersions: [String: String] = [
    "2026-08-17": "1.1.6", "2026-05-12": "1.1.5", "2026-03-04": "1.1.4",
    "2026-01-08": "1.1.3", "2025-12-05": "1.1.1", "2025-11-28": "1.1.0",
    "2025-11-19": "1.0.9", "2025-10-17": "1.0.8", "2025-09-04": "1.0.7",
    "2025-08-21": "1.0.6", "2025-08-08": "1.0.5", "2025-07-18": "1.0.3",
    "2025-07-14": "1.0.0",
]

func prettyDate(_ iso: String) -> String {
    let p = iso.split(separator: "-")
    return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : iso
}

// MARK: - Логотип

enum Logo {
    static let w = 160, h = 40

    /// Вписывает картинку в 160x40 на чёрном фоне. Возвращает превью и пиксели RGB565 (little-endian).
    static func render(_ image: NSImage) -> (NSImage, [UInt8])? {
        guard let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let sw = CGFloat(src.width), sh = CGFloat(src.height)
        let scale = min(CGFloat(w) / sw, CGFloat(h) / sh, 1)
        let dw = sw * scale, dh = sh * scale
        ctx.draw(src, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
        guard let out = ctx.makeImage(), let px = ctx.data else { return nil }
        let p = px.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(w * h * 2)
        for i in 0..<(w * h) {
            let r = UInt16(p[i * 4]), g = UInt16(p[i * 4 + 1]), b = UInt16(p[i * 4 + 2])
            let v = (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
            bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8))
        }
        return (NSImage(cgImage: out, size: NSSize(width: w, height: h)), bytes)
    }

    static func block(pixels: [UInt8]) -> FwBlock {
        var payload = Array("ATKLOGO".utf8) + [0]
        payload += [UInt8(w & 0xFF), UInt8(w >> 8), UInt8(h & 0xFF), UInt8(h >> 8)]
        payload += pixels
        let size = payload.count
        let hdr: [UInt8] = [UInt8(Proto.devType & 0xFF), UInt8(Proto.devType >> 8), 0, 0, 0xA1, 40,
                            UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF),
                            UInt8((size >> 16) & 0xFF), UInt8(size >> 24), 0, 0, 0]
        // Шифр ATK с нулевым ключом = инверсия каждого байта (так же зашифрованы файлы .atk).
        return FwBlock(header: hdr, data: payload.map { ~$0 })
    }
}

// MARK: - USB-HID

final class HIDLink {
    private let manager: IOHIDManager
    private(set) var device: IOHIDDevice?
    private let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private let cond = NSCondition()
    private var reports: [[UInt8]] = []
    var onChange: ((Bool) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: Proto.vid, kIOHIDProductIDKey: Proto.pid]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ dev: IOHIDDevice) {
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 256, { ctx, _, _, _, _, report, len in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue()
                .received(Array(UnsafeBufferPointer(start: report, count: len)))
        }, ctx)
        onChange?(true)
    }

    private func detach(_ dev: IOHIDDevice) {
        if device == dev { device = nil; onChange?(false) }
    }

    private func received(_ r: [UInt8]) {
        cond.lock(); reports.append(r); cond.signal(); cond.unlock()
    }

    private func write(_ frame: [UInt8]) throws {
        guard let dev = device else { throw FlashError(key: "err.disconnected") }
        var rep = frame + [UInt8](repeating: 0, count: Proto.reportSize - frame.count)
        let res = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, &rep, rep.count)
        if res != kIOReturnSuccess { throw FlashError(key: "err.usb", args: [Int(res)]) }
    }

    func send(_ cmd: UInt8, seq: UInt8 = 0, data: [UInt8] = []) throws {
        cond.lock(); reports.removeAll(); cond.unlock()
        try write(Proto.frame(cmd, seq, data))
    }

    /// Отправляет команду и ждёт ответ. nil — таймаут.
    func request(_ cmd: UInt8, seq: UInt8 = 0, data: [UInt8] = [], timeout: TimeInterval = 1) throws -> [UInt8]? {
        try send(cmd, seq: seq, data: data)
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while true {
            while !reports.isEmpty {
                if let d = Proto.parse(reports.removeFirst()) { return d }
            }
            if !cond.wait(until: deadline) { return nil }
        }
    }

    func statusOK(_ cmd: UInt8, seq: UInt8 = 0, data: [UInt8] = [], timeout: TimeInterval = 1) throws -> Bool {
        guard let r = try request(cmd, seq: seq, data: data, timeout: timeout) else { return false }
        return r.first == 0
    }

    func devInfo() throws -> DevInfo? {
        guard let r = try request(Proto.getDevInfo) else { return nil }
        return DevInfo(r)
    }

    /// Полная запись блоков. progress(0…1), stage(ключ перевода), log(строка).
    func flash(_ blocks: [FwBlock], progress: (Double) -> Void, stage: (String) -> Void, log: (String) -> Void) throws {
        guard let info = try devInfo() else { throw FlashError(key: "err.noResponse") }
        log(String(format: "Device 0x%04X, firmware %@, mode 0x%02X", info.devType, info.date, info.runFlag))
        guard info.inBootloader else { throw FlashError(key: "err.notBoot") }
        guard blocks[0].devType == info.devType else { throw FlashError(key: "err.wrongDevice") }

        let total = blocks.reduce(0) { $0 + $1.data.count }
        var done = 0
        for b in blocks {
            stage(b.isLogo ? "progress.writingLogo" : "progress.writingFw")
            log(String(format: "Block 0x%02X, %d bytes", b.fileType, b.data.count))
            guard try statusOK(Proto.setFwInfo, data: b.header) else { throw FlashError(key: "err.rejected") }
            guard try statusOK(Proto.startSend, timeout: 5) else { throw FlashError(key: "err.noStart") }
            var seq: UInt8 = 0
            var off = 0
            while off < b.data.count {
                let chunk = Array(b.data[off..<min(off + b.chunk, b.data.count)])
                var ok = false
                for _ in 0..<4 where !ok {
                    ok = try statusOK(Proto.sendData, seq: seq, data: chunk)
                }
                if !ok { throw FlashError(key: "err.packet", args: [Int(seq)]) }
                seq &+= 1; off += chunk.count; done += chunk.count
                if seq % 8 == 0 || off == b.data.count { progress(Double(done) / Double(total)) }
            }
            try send(Proto.sendEnd)
            log("Block written")
        }
        Thread.sleep(forTimeInterval: 0.1)
        let ok = (try? statusOK(Proto.finish, data: [0xA0], timeout: 3)) ?? false
        log(ok ? "Finish: OK" : "Finish: no reply (the iron is restarting)")
    }
}
