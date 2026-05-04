//
//  PresentationDocument.swift
//  osaurus
//
//  Typed read model for presentation formats. This is intentionally not
//  an OOXML AST; it captures the business-level shape that downstream
//  tools need while preserving source markers for traceability.
//

import Foundation

public struct PresentationDocument: StructuredRepresentation, Equatable, Sendable {
    public var slides: [PresentationSlide]
    public var theme: PresentationTheme?
    public var sourceProvenance: SourceProvenance

    public init(
        slides: [PresentationSlide],
        theme: PresentationTheme? = nil,
        sourceProvenance: SourceProvenance
    ) {
        self.slides = slides
        self.theme = theme
        self.sourceProvenance = sourceProvenance
    }
}

public struct PresentationSlide: Equatable, Sendable {
    public var number: Int
    public var layout: PresentationLayoutKind
    public var elements: [PresentationElement]
    public var speakerNotes: SpeakerNotes?
    public var sourceProvenance: SourceProvenance

    public init(
        number: Int,
        layout: PresentationLayoutKind,
        elements: [PresentationElement],
        speakerNotes: SpeakerNotes? = nil,
        sourceProvenance: SourceProvenance
    ) {
        self.number = number
        self.layout = layout
        self.elements = elements
        self.speakerNotes = speakerNotes
        self.sourceProvenance = sourceProvenance
    }
}

public enum PresentationLayoutKind: Equatable, Sendable {
    case blank
    case title
    case titleAndContent
    case sectionHeader
    case twoContent
    case comparison
    case pictureWithCaption
    case custom(String)
}

public enum PresentationElement: Equatable, Sendable {
    case title(PresentationText)
    case bodyText(PresentationBulletList)
    case shape(PresentationShape)
    case table(PresentationTable)
    case chartReference(PresentationChartReference)
    case image(PresentationImage)
}

public struct PresentationText: Equatable, Sendable {
    public var text: String
    public var sourceProvenance: SourceProvenance?

    public init(text: String, sourceProvenance: SourceProvenance? = nil) {
        self.text = text
        self.sourceProvenance = sourceProvenance
    }
}

public struct PresentationBulletList: Equatable, Sendable {
    public var items: [Item]
    public var sourceProvenance: SourceProvenance?

    public init(items: [Item], sourceProvenance: SourceProvenance? = nil) {
        self.items = items
        self.sourceProvenance = sourceProvenance
    }

    public init(_ texts: [String], sourceProvenance: SourceProvenance? = nil) {
        self.items = texts.map { Item(text: $0) }
        self.sourceProvenance = sourceProvenance
    }

    public struct Item: Equatable, Sendable {
        public var text: String
        public var level: Int

        public init(text: String, level: Int = 0) {
            self.text = text
            self.level = level
        }
    }
}

public struct PresentationShape: Equatable, Sendable {
    public var kind: String
    public var text: PresentationText?
    public var frame: PresentationRect?

    public init(kind: String, text: PresentationText? = nil, frame: PresentationRect? = nil) {
        self.kind = kind
        self.text = text
        self.frame = frame
    }
}

public struct PresentationTable: Equatable, Sendable {
    public var rows: [[String]]
    public var headerRowCount: Int
    public var caption: String?
    public var sourceProvenance: SourceProvenance?

    public init(
        rows: [[String]],
        headerRowCount: Int = 0,
        caption: String? = nil,
        sourceProvenance: SourceProvenance? = nil
    ) {
        self.rows = rows
        self.headerRowCount = headerRowCount
        self.caption = caption
        self.sourceProvenance = sourceProvenance
    }
}

public struct PresentationChartReference: Equatable, Sendable {
    public var title: String?
    public var relationshipId: String?
    public var sourceProvenance: SourceProvenance?

    public init(
        title: String? = nil,
        relationshipId: String? = nil,
        sourceProvenance: SourceProvenance? = nil
    ) {
        self.title = title
        self.relationshipId = relationshipId
        self.sourceProvenance = sourceProvenance
    }
}

public struct PresentationImage: Equatable, Sendable {
    public var relationshipId: String?
    public var path: String?
    public var mimeType: String?
    public var altText: String?
    public var frame: PresentationRect?
    public var sourceProvenance: SourceProvenance?

    public init(
        relationshipId: String? = nil,
        path: String? = nil,
        mimeType: String? = nil,
        altText: String? = nil,
        frame: PresentationRect? = nil,
        sourceProvenance: SourceProvenance? = nil
    ) {
        self.relationshipId = relationshipId
        self.path = path
        self.mimeType = mimeType
        self.altText = altText
        self.frame = frame
        self.sourceProvenance = sourceProvenance
    }
}

public struct PresentationRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SpeakerNotes: Equatable, Sendable {
    public var text: String
    public var sourceProvenance: SourceProvenance

    public init(text: String, sourceProvenance: SourceProvenance) {
        self.text = text
        self.sourceProvenance = sourceProvenance
    }
}

public struct PresentationTheme: Equatable, Sendable {
    public var name: String?
    public var colors: [String: String]
    public var fonts: [String: String]
    public var sourceProvenance: SourceProvenance?

    public init(
        name: String? = nil,
        colors: [String: String] = [:],
        fonts: [String: String] = [:],
        sourceProvenance: SourceProvenance? = nil
    ) {
        self.name = name
        self.colors = colors
        self.fonts = fonts
        self.sourceProvenance = sourceProvenance
    }
}

public struct SourceProvenance: Equatable, Sendable {
    public var origin: Origin
    public var sourceName: String?

    public init(origin: Origin, sourceName: String? = nil) {
        self.origin = origin
        self.sourceName = sourceName
    }

    public enum Origin: Equatable, Sendable {
        case file
        case pptxPart(String)
        case pptxSlide(Int)
        case pptxNotesSlide(Int)
    }
}
