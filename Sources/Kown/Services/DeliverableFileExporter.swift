import Foundation
import CoreGraphics
import CoreText

enum DeliverableExportError: Error, LocalizedError {
    case unsupported
    case pdfContextFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: return "该交付物格式暂不支持文件导出"
        case .pdfContextFailed: return "PDF 生成失败"
        }
    }
}

/// 把交付物导出为真实文件。DOCX / PPTX 使用无压缩 ZIP + 最小 OOXML 包,PDF 使用 CoreText 分页。
enum DeliverableFileExporter {
    static func data(for deliverable: Deliverable) throws -> Data {
        switch deliverable.kind {
        case .markdown, .pdfOutline, .pptOutline:
            return Data(deliverable.content.utf8)
        case .html, .webpage:
            return Data(DeliverableStudioService.publishableHTML(for: deliverable).utf8)
        case .docx:
            return try makeDOCX(deliverable)
        case .pptx:
            return try makePPTX(deliverable)
        case .pdf:
            return try makePDF(deliverable)
        }
    }

    static func write(_ deliverable: Deliverable, to url: URL) throws {
        try data(for: deliverable).write(to: url, options: .atomic)
    }
}

private extension DeliverableFileExporter {
    static func makeDOCX(_ deliverable: Deliverable) throws -> Data {
        let paragraphs = lines(deliverable.content).map(docxParagraph).joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(paragraphs)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body></w:document>
        """
        return ZipArchive.make(entries: [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
              <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
              <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
            </Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
              <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
            </Relationships>
            """),
            ("word/document.xml", document),
            ("docProps/core.xml", coreProperties(deliverable)),
            ("docProps/app.xml", appProperties(app: "Kown"))
        ])
    }

    static func docxParagraph(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<w:p/>" }
        let headingLevel: String?
        let text: String
        if trimmed.hasPrefix("### ") {
            headingLevel = "3"; text = String(trimmed.dropFirst(4))
        } else if trimmed.hasPrefix("## ") {
            headingLevel = "2"; text = String(trimmed.dropFirst(3))
        } else if trimmed.hasPrefix("# ") {
            headingLevel = "1"; text = String(trimmed.dropFirst(2))
        } else {
            headingLevel = nil; text = trimmed
        }
        let style = headingLevel.map { "<w:pPr><w:pStyle w:val=\"Heading\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(style)<w:r><w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r></w:p>"
    }

    static func makePPTX(_ deliverable: Deliverable) throws -> Data {
        let slides = slidePayloads(from: deliverable)
        var entries: [(String, String)] = [
            ("[Content_Types].xml", pptContentTypes(slideCount: slides.count)),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
              <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
            </Relationships>
            """),
            ("ppt/presentation.xml", pptPresentation(slideCount: slides.count)),
            ("ppt/_rels/presentation.xml.rels", pptPresentationRels(slideCount: slides.count)),
            ("docProps/core.xml", coreProperties(deliverable)),
            ("docProps/app.xml", appProperties(app: "Kown"))
        ]
        for (idx, slide) in slides.enumerated() {
            entries.append(("ppt/slides/slide\(idx + 1).xml", pptSlide(title: slide.title, body: slide.body)))
        }
        return ZipArchive.make(entries: entries)
    }

    static func slidePayloads(from deliverable: Deliverable) -> [(title: String, body: String)] {
        let chunks = lines(deliverable.content)
        var slides: [(String, String)] = [(deliverable.title, deliverable.summary)]
        for line in chunks {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if cleaned.hasPrefix("#") { continue }
            if cleaned.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                slides.append((String(cleaned.prefix(48)), cleaned))
            } else if cleaned.hasPrefix("- ") && slides.count < 12 {
                slides.append((String(cleaned.dropFirst(2).prefix(48)), cleaned))
            }
            if slides.count >= 12 { break }
        }
        return slides.isEmpty ? [(deliverable.title, deliverable.content)] : slides
    }

    static func makePDF(_ deliverable: Deliverable) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw DeliverableExportError.pdfContextFailed }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DeliverableExportError.pdfContextFailed
        }

        let text = "\(deliverable.title)\n\n\(deliverable.summary)\n\n\(plain(deliverable.content))"
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font
        ])
        attributed.addAttributes([kCTFontAttributeName as NSAttributedString.Key: titleFont],
                                 range: NSRange(location: 0, length: min(deliverable.title.count, attributed.length)))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var range = CFRange(location: 0, length: 0)
        repeat {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: mediaBox.height)
            ctx.scaleBy(x: 1, y: -1)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 54, y: 54, width: mediaBox.width - 108, height: mediaBox.height - 108))
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }
            range.location += visible.length
            ctx.endPDFPage()
        } while range.location < attributed.length
        ctx.closePDF()
        return data as Data
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func coreProperties(_ deliverable: Deliverable) -> String {
        let iso = ISO8601DateFormatter().string(from: deliverable.createdAt)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(xml(deliverable.title))</dc:title>
          <dc:creator>Kown</dc:creator>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(iso)</dcterms:created>
        </cp:coreProperties>
        """
    }

    static func appProperties(app: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>\(app)</Application></Properties>
        """
    }

    static func pptContentTypes(slideCount: Int) -> String {
        let slides = (1...slideCount).map {
            "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
          \(slides)
        </Types>
        """
    }

    static func pptPresentation(slideCount: Int) -> String {
        let ids = (1...slideCount).map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0)\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:sldIdLst>\(ids)</p:sldIdLst>
          <p:sldSz cx="12192000" cy="6858000" type="wide"/>
          <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
    }

    static func pptPresentationRels(slideCount: Int) -> String {
        let rels = (1...slideCount).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    static func pptSlide(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree>
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
            \(pptTextShape(id: 2, name: "Title", x: 700000, y: 420000, cx: 10800000, cy: 760000, text: title, size: 3200, bold: true))
            \(pptTextShape(id: 3, name: "Body", x: 820000, y: 1400000, cx: 10300000, cy: 4300000, text: body, size: 1900, bold: false))
          </p:spTree></p:cSld>
        </p:sld>
        """
    }

    static func pptTextShape(id: Int, name: String, x: Int, y: Int, cx: Int, cy: Int, text: String, size: Int, bold: Bool) -> String {
        let runs = lines(plain(text)).prefix(10).map {
            "<a:p><a:r><a:rPr lang=\"zh-CN\" sz=\"\(size)\"\(bold ? " b=\"1\"" : "")/><a:t>\(xml($0))</a:t></a:r></a:p>"
        }.joined()
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
          <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>
          <p:txBody><a:bodyPr wrap="square"/><a:lstStyle/>\(runs)</p:txBody>
        </p:sp>
        """
    }
}

private enum ZipArchive {
    static func make(entries: [(String, String)]) -> Data {
        make(entries: entries.map { ($0.0, Data($0.1.utf8)) })
    }

    static func make(entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in entries {
            let nameData = Data(name.utf8)
            let offset = UInt32(out.count)
            let crc = CRC32.checksum(data)
            out.u32(0x04034b50); out.u16(20); out.u16(0); out.u16(0); out.u16(0); out.u16(0)
            out.u32(crc); out.u32(UInt32(data.count)); out.u32(UInt32(data.count))
            out.u16(UInt16(nameData.count)); out.u16(0); out.append(nameData); out.append(data)

            central.u32(0x02014b50); central.u16(20); central.u16(20); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
            central.u32(crc); central.u32(UInt32(data.count)); central.u32(UInt32(data.count))
            central.u16(UInt16(nameData.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0); central.u32(0); central.u32(offset)
            central.append(nameData)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.u32(0x06054b50); out.u16(0); out.u16(0); out.u16(UInt16(entries.count)); out.u16(UInt16(entries.count))
        out.u32(UInt32(central.count)); out.u32(centralOffset); out.u16(0)
        return out
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func u32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
