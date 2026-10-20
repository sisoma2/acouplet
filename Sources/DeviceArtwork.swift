import AppKit
import SwiftUI

enum EarbudSide {
    case left, right
}

struct OpenChargingCaseArtwork: View {
    let model: SonyDeviceModel
    let suffix: String

    private var placement: (height: CGFloat, offset: CGFloat) {
        if model == .wfXM5, suffix.isEmpty { return (128, 0) }
        let bounds: (height: CGFloat, center: CGFloat)
        switch (model, suffix) {
        case (.wfXM5, "SmokyPink"): bounds = (559, 638.5)
        case (.wfXM5, _): bounds = (557, 638.5)
        case (.wfXM6, "Silver"): bounds = (554, 605)
        default: bounds = (557, 526.5)
        }
        return (128 * 1000 / bounds.height, 128 * (500 - bounds.center) / bounds.height)
    }

    var body: some View {
        Group {
            #if ACOUPLET_NO_SONY_ARTWORK
            caseSymbol
            #else
            if model == .wfXM5 || model == .wfXM6 {
                Image(model.rawValue + "OpenCaseProduct" + suffix)
                    .resizable()
                    .scaledToFit()
                    .frame(height: placement.height)
                    .offset(y: placement.offset)
                    .frame(width: 220, height: 128)
                    .clipped()
            } else {
                caseSymbol
            }
            #endif
        }
        .accessibilityLabel("\(model.name) earbuds charging in their case")
        .accessibilityIdentifier("device.artwork.openCase")
    }

    private var caseSymbol: some View {
        Image(nsImage: DeviceIcon.caseImage(model: model))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 128)
    }
}

struct EarbudArtwork: View {
    let model: SonyDeviceModel
    let side: EarbudSide
    let usesProductArtwork: Bool
    let artworkSuffix: String

    var body: some View {
        GeometryReader { geometry in
            if model == .wfXM5, usesProductArtwork {
                Image("WFXM5Front" + artworkSuffix)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width * 2, height: geometry.size.height)
                    .frame(width: geometry.size.width, alignment: side == .left ? .trailing : .leading)
                    .clipped()
            } else if usesProductArtwork {
                Image(model.rawValue + (side == .left ? "ProductLeft" : "ProductRight") + artworkSuffix)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else if let symbol = side == .left ? model.leftSymbol : model.rightSymbol,
                      let image = NSImage(named: symbol) {
                let size = NSSize(width: image.size.width / 2, height: image.size.height)
                let cropped = NSImage(size: size, flipped: false) { rect in
                    image.draw(in: rect, from: NSRect(origin: NSPoint(x: side == .left ? 0 : size.width, y: 0), size: size),
                               operation: .sourceOver, fraction: 1)
                    return true
                }
                Image(nsImage: cropped)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Image(nsImage: DeviceIcon.fallbackEarbudImage(side: side))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .aspectRatio(137.0 / 103.0, contentMode: .fit)
        .accessibilityLabel(String(localized: "\(side == .left ? String(localized: "Left") : String(localized: "Right")) \(model.name) earbud"))
    }
}

struct DeviceIcon: View {
    let model: SonyDeviceModel
    let leftConnected: Bool?
    let rightConnected: Bool?

    var body: some View {
        if let leftSymbol = model.leftSymbol, let rightSymbol = model.rightSymbol {
            ZStack {
                Image(leftSymbol)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .opacity(leftConnected == false ? 0.35 : 1)
                Image(rightSymbol)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .opacity(rightConnected == false ? 0.35 : 1)
            }
        } else if model.isEarbuds {
            HStack(spacing: 1) {
                Image(nsImage: Self.fallbackEarbudImage(side: .left))
                    .resizable()
                    .scaledToFit()
                    .opacity(leftConnected == false ? 0.35 : 1)
                Image(nsImage: Self.fallbackEarbudImage(side: .right))
                    .resizable()
                    .scaledToFit()
                    .opacity(rightConnected == false ? 0.35 : 1)
            }
        } else if let symbol = model.symbol {
            Image(symbol)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: model.systemSymbol)
                .resizable()
                .scaledToFit()
        }
    }

    static func fallbackEarbudImage(side: EarbudSide) -> NSImage {
        let side = side == .left ? "left" : "right"
        return NSImage(systemSymbolName: "earbuds.stemless." + side, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "earbud." + side, accessibilityDescription: nil)!
    }

    static func caseImage(model: SonyDeviceModel) -> NSImage {
        model.caseSymbol.flatMap(NSImage.init(named:)).map { $0.copy() as! NSImage }
            ?? NSImage(systemSymbolName: "earbuds.case", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "case", accessibilityDescription: nil)!
    }

    static func connectionValue(left: Bool?, right: Bool?) -> String {
        String(localized: "Left: \(left.map { $0 ? String(localized: "Connected") : String(localized: "Disconnected") } ?? String(localized: "Unknown")), Right: \(right.map { $0 ? String(localized: "Connected") : String(localized: "Disconnected") } ?? String(localized: "Unknown"))")
    }

    static func batteryColor(for reading: BatteryReading?) -> NSColor? {
        guard let reading else { return nil }
        return reading.level <= 20 ? .systemRed : nil
    }

    static func menuBarImage(model: SonyDeviceModel, leftConnected: Bool?, rightConnected: Bool?, batteries: SonyBatteries = .init(), chargingCase: Bool = false, foregroundColor: NSColor = .labelColor) -> NSImage {
        if chargingCase {
            let symbol = caseImage(model: model)
            let color = batteries.caseBattery?.isCharging == true ? nil : batteryColor(for: batteries.caseBattery)
            let image = color.map { tinted(symbol, color: $0) } ?? symbol
            image.isTemplate = color == nil
            return image
        }
        let size = model.leftSymbol.flatMap(NSImage.init(named:))?.size ?? NSSize(width: 22, height: 18)
        let leftColor = leftConnected == false ? nil : batteryColor(for: batteries.left)
        let rightColor = rightConnected == false ? nil : batteryColor(for: batteries.right)
        let singleColor = batteryColor(for: batteries.single)
        let hasWarning = model.isEarbuds ? leftColor != nil || rightColor != nil : singleColor != nil
        let image = NSImage(size: size, flipped: false) { rect in
            if let left = model.leftSymbol, let right = model.rightSymbol {
                for (name, connected, color) in [(left, leftConnected, leftColor), (right, rightConnected, rightColor)] {
                    let symbol = NSImage(named: name)!
                    let part = hasWarning ? tinted(symbol, color: color ?? foregroundColor) : symbol
                    part.draw(in: rect, from: .zero, operation: .sourceOver, fraction: connected == false ? 0.35 : 1)
                }
            } else if model.isEarbuds {
                for (side, connected, color) in [(EarbudSide.left, leftConnected, leftColor), (.right, rightConnected, rightColor)] {
                    let symbol = fallbackEarbudImage(side: side)
                    let part = hasWarning ? tinted(symbol, color: color ?? foregroundColor) : symbol
                    let partRect = NSRect(x: side == .left ? rect.minX : rect.midX + 0.5, y: rect.minY,
                                          width: rect.width / 2 - 0.5, height: rect.height)
                    let scale = min(partRect.width / symbol.size.width, partRect.height / symbol.size.height)
                    let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                    let bounds = NSRect(x: partRect.midX - size.width / 2, y: partRect.midY - size.height / 2, width: size.width, height: size.height)
                    part.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: connected == false ? 0.35 : 1)
                }
            } else {
                let symbol = model.symbol.flatMap(NSImage.init(named:))
                    ?? NSImage(systemSymbolName: model.systemSymbol, accessibilityDescription: model.name)!
                (singleColor.map { tinted(symbol, color: $0) } ?? symbol).draw(in: rect)
            }
            return true
        }
        image.isTemplate = !hasWarning
        return image
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
