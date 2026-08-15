import Foundation
import CoreServices
import ImageIO

struct PhotoMetadata: Equatable, Sendable {
    var captureDate: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var cameraMake: String?
    var cameraModel: String?
    var colorSpace: String?
    var colorProfile: String?
    var focalLength: Double?
    var hasAlpha: Bool?
    var redEye: Bool?
    var meteringMode: String?
    var fNumber: Double?
    var exposureProgram: String?
    var exposureTime: Double?

    var rows: [(label: String, value: String)] {
        var result: [(String, String)] = []
        if let captureDate {
            result.append(("Aufnahmedatum", Self.dateTime(captureDate)))
        }
        if let pixelWidth, let pixelHeight {
            result.append(("Abmessungen", "\(pixelWidth) × \(pixelHeight)"))
        }
        append(cameraMake, label: "Gerätemarke", to: &result)
        append(cameraModel, label: "Gerätemodell", to: &result)
        append(colorSpace, label: "Farbraum", to: &result)
        append(colorProfile, label: "Farbprofil", to: &result)
        if let focalLength {
            result.append(("Brennweite", "\(Self.decimal(focalLength)) mm"))
        }
        if let hasAlpha {
            result.append(("Alpha-Kanal", Self.yesNo(hasAlpha)))
        }
        if let redEye {
            result.append(("Rote Augen", Self.yesNo(redEye)))
        }
        append(meteringMode, label: "Messmethode", to: &result)
        if let fNumber {
            result.append(("Blendenzahl", "f/\(Self.decimal(fNumber))"))
        }
        append(exposureProgram, label: "Belichtungsprogramm", to: &result)
        if let exposureTime {
            result.append(("Belichtungszeit", Self.exposureTimeLabel(exposureTime)))
        }
        return result
    }

    var isEmpty: Bool { rows.isEmpty }

    mutating func fillMissing(from fallback: PhotoMetadata) {
        captureDate = captureDate ?? fallback.captureDate
        pixelWidth = pixelWidth ?? fallback.pixelWidth
        pixelHeight = pixelHeight ?? fallback.pixelHeight
        cameraMake = cameraMake ?? fallback.cameraMake
        cameraModel = cameraModel ?? fallback.cameraModel
        colorSpace = colorSpace ?? fallback.colorSpace
        colorProfile = colorProfile ?? fallback.colorProfile
        focalLength = focalLength ?? fallback.focalLength
        hasAlpha = hasAlpha ?? fallback.hasAlpha
        redEye = redEye ?? fallback.redEye
        meteringMode = meteringMode ?? fallback.meteringMode
        fNumber = fNumber ?? fallback.fNumber
        exposureProgram = exposureProgram ?? fallback.exposureProgram
        exposureTime = exposureTime ?? fallback.exposureTime
    }

    private func append(_ value: String?, label: String, to rows: inout [(String, String)]) {
        guard let value, !value.isEmpty else { return }
        rows.append((label, value))
    }

    static func exposureTimeLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return decimal(seconds) + " s" }
        if seconds < 1 {
            let denominator = max(1, Int((1 / seconds).rounded()))
            let reconstructed = 1 / Double(denominator)
            if abs(reconstructed - seconds) / seconds < 0.02 {
                return "1/\(denominator)"
            }
        }
        return decimal(seconds) + " s"
    }

    private static func yesNo(_ value: Bool) -> String { value ? "Ja" : "Nein" }

    private static func dateTime(_ value: Date) -> String {
        value.formatted(
            .dateTime
                .locale(Locale(identifier: "de_DE"))
                .day()
                .month(.twoDigits)
                .year()
                .hour()
                .minute()
        )
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "de_DE")).precision(.fractionLength(0...2)))
    }
}

enum ImageMetadataReader {
    static func displayAspectRatio(pixelWidth: Int, pixelHeight: Int, orientation: Int?) -> Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        let swapsAxes = orientation.map { (5...8).contains($0) } ?? false
        if swapsAxes {
            return Double(pixelHeight) / Double(pixelWidth)
        }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    static func captureDate(at url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        return captureDate(in: properties)
    }

    private static func captureDate(in properties: [CFString: Any]) -> Date? {
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = parseEXIFDate(value) {
            return date
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = parseEXIFDate(value) {
            return date
        }
        return nil
    }

    static func orientation(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let orientation = integer(properties[kCGImagePropertyOrientation]),
        (1...8).contains(orientation)
        else { return 1 }
        return orientation
    }

    static func metadata(for asset: PhotoAsset) -> PhotoMetadata {
        var urls = [asset.primaryURL]
        if asset.previewURL.standardizedFileURL != asset.primaryURL.standardizedFileURL {
            urls.append(asset.previewURL)
        }

        var result = PhotoMetadata()
        for url in urls {
            result.fillMissing(from: metadata(at: url))
        }
        return result
    }

    static func metadata(at url: URL) -> PhotoMetadata {
        let spotlight = spotlightMetadata(at: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return spotlight }

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var imageIO = PhotoMetadata(
            captureDate: captureDate(in: properties),
            pixelWidth: integer(properties[kCGImagePropertyPixelWidth]),
            pixelHeight: integer(properties[kCGImagePropertyPixelHeight]),
            cameraMake: string(tiff?[kCGImagePropertyTIFFMake]),
            cameraModel: string(tiff?[kCGImagePropertyTIFFModel]),
            colorSpace: string(properties[kCGImagePropertyColorModel]),
            colorProfile: string(properties[kCGImagePropertyProfileName]),
            focalLength: double(exif?[kCGImagePropertyExifFocalLength]),
            hasAlpha: boolean(properties[kCGImagePropertyHasAlpha]),
            redEye: nil,
            meteringMode: meteringMode(exif?[kCGImagePropertyExifMeteringMode]),
            fNumber: double(exif?[kCGImagePropertyExifFNumber]),
            exposureProgram: exposureProgram(exif?[kCGImagePropertyExifExposureProgram]),
            exposureTime: double(exif?[kCGImagePropertyExifExposureTime])
        )
        imageIO.fillMissing(from: spotlight)
        return imageIO
    }

    private static func spotlightMetadata(at url: URL) -> PhotoMetadata {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return PhotoMetadata()
        }
        return PhotoMetadata(
            pixelWidth: integer(MDItemCopyAttribute(item, kMDItemPixelWidth)),
            pixelHeight: integer(MDItemCopyAttribute(item, kMDItemPixelHeight)),
            cameraMake: string(MDItemCopyAttribute(item, kMDItemAcquisitionMake)),
            cameraModel: string(MDItemCopyAttribute(item, kMDItemAcquisitionModel)),
            colorSpace: string(MDItemCopyAttribute(item, kMDItemColorSpace)),
            colorProfile: string(MDItemCopyAttribute(item, kMDItemProfileName)),
            focalLength: double(MDItemCopyAttribute(item, kMDItemFocalLength)),
            hasAlpha: boolean(MDItemCopyAttribute(item, kMDItemHasAlphaChannel)),
            redEye: boolean(MDItemCopyAttribute(item, kMDItemRedEyeOnOff)),
            meteringMode: localizedMeteringMode(string(MDItemCopyAttribute(item, kMDItemMeteringMode))),
            fNumber: double(MDItemCopyAttribute(item, kMDItemFNumber)),
            exposureProgram: localizedExposureProgram(string(MDItemCopyAttribute(item, kMDItemExposureProgram))),
            exposureTime: double(MDItemCopyAttribute(item, kMDItemExposureTimeSeconds))
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func meteringMode(_ value: Any?) -> String? {
        guard let number = integer(value) else { return nil }
        return [
            0: "Unbekannt",
            1: "Durchschnitt",
            2: "Mittenbetonter Durchschnitt",
            3: "Spot",
            4: "Mehrfach-Spot",
            5: "Muster",
            6: "Teilbereich",
            255: "Andere"
        ][number]
    }

    private static func exposureProgram(_ value: Any?) -> String? {
        guard let number = integer(value) else { return nil }
        return [
            0: "Nicht definiert",
            1: "Manuell",
            2: "Normalprogramm",
            3: "Blendenpriorität",
            4: "Zeitpriorität",
            5: "Kreativprogramm",
            6: "Actionprogramm",
            7: "Porträtmodus",
            8: "Landschaftsmodus",
            9: "Langzeitbelichtung"
        ][number]
    }

    private static func localizedMeteringMode(_ value: String?) -> String? {
        guard let value else { return nil }
        return [
            "average": "Durchschnitt",
            "center weighted average": "Mittenbetonter Durchschnitt",
            "centerweightedaverage": "Mittenbetonter Durchschnitt",
            "multi-spot": "Mehrfach-Spot",
            "pattern": "Muster",
            "partial": "Teilbereich",
            "other": "Andere"
        ][value.lowercased()] ?? value
    }

    private static func localizedExposureProgram(_ value: String?) -> String? {
        guard let value else { return nil }
        return [
            "manual": "Manuell",
            "normal program": "Normalprogramm",
            "aperture priority": "Blendenpriorität",
            "shutter priority": "Zeitpriorität",
            "creative program": "Kreativprogramm",
            "action program": "Actionprogramm",
            "portrait mode": "Porträtmodus",
            "landscape mode": "Landschaftsmodus",
            "bulb": "Langzeitbelichtung"
        ][value.lowercased()] ?? value
    }

    private static func parseEXIFDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
