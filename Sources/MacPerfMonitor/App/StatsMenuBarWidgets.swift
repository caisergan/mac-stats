import AppKit
import MacPerfMonitorCore

// The menu bar widget drawing, ported from Stats (github.com/exelban/stats),
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT licensed, from `Kit/Widgets/*.swift`
// and the chart views in `Kit/plugins/Charts.swift`.
//
// Stats draws each widget as its own `NSView` subclass sized by AppKit, reading
// its options from `Store.shared` and a per-module `config.plist`. This app has
// one status item whose image is a single composited bitmap, so every widget is
// a routine here that reports its width and paints into a shared context at a
// given x. The geometry, fonts, colours and rounding are carried over unchanged;
// what is dropped is the per-widget settings UI, so each shape uses the option
// values that the matching Stats module config ships as its default. Deviations
// are marked `// DEVIATION:` where they exist.
//
// The compact shape is the exception: it is this app's own, not a Stats port,
// and has its own section below.

/// One slice of a composite gauge: how much of the whole it covers (0...1) and
/// the colour to paint it. Stats' `ColorValue`.
struct MenuBarWidgetSegment {
    var value: Double
    var color: NSColor?

    init(_ value: Double, color: NSColor? = nil) {
        self.value = value
        self.color = color
    }
}

/// How a chart maps a value onto its height. Stats' `Scale`.
enum MenuBarChartScale {
    case none
    case linear
    case square
    case cube
    case logarithmic
    case fixed
}

/// Memory pressure, in the three levels the colouring uses. Stats' `RAMPressure`.
extension PressureLevel {
    var menuBarPressureColor: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

@MainActor
enum StatsMenuBarWidgets {
    /// A laid-out widget: how wide it is, and how to paint it at an x origin.
    struct Cell {
        var width: CGFloat
        var draw: (CGFloat) -> Void
    }

    // MARK: - Constants (Stats: `Constants.Widget`)

    /// Stats sizes every widget against the menu bar height with a 2pt vertical
    /// margin and a 2pt gap between elements, and a nominal 32pt cell width.
    enum Metrics {
        static let itemHeight: CGFloat = 22
        static let marginX: CGFloat = 0
        static let marginY: CGFloat = 2
        static let spacing: CGFloat = 2
        static let width: CGFloat = 32
        /// The height a widget draws into, inside the vertical margins.
        static let frameHeight: CGFloat = itemHeight - (marginY * 2)
    }

    /// How many trailing samples the history shapes draw. Stats' chart default.
    static let historyPoints = 60

    // MARK: - Entry point

    static func cell(
        for readout: CombinedMenuBarReadout, style: MenuBarWidgetStyle, isDark: Bool
    ) -> Cell {
        switch style {
        case .compact: return compact(readout, isDark)
        case .mini: return mini(readout, isDark)
        case .lineChart: return lineChart(readout, isDark)
        case .barChart: return barChart(readout, isDark)
        case .pieChart: return pieChart(readout, isDark)
        case .networkChart: return networkChart(readout, isDark)
        case .speed: return speed(readout, isDark)
        case .battery: return battery(readout, isDark)
        case .batteryDetails: return batteryDetails(readout, isDark)
        case .memory: return memory(readout, isDark)
        case .stack: return stack(readout, isDark)
        case .tachometer: return tachometer(readout, isDark)
        case .state: return state(readout, isDark)
        case .text: return text(readout, isDark)
        case .label: return label(readout, isDark)
        }
    }

    // MARK: - Compact (this app's own shape, not a Stats port)

    /// The compact shape's type and spacing at one text size.
    ///
    /// Everything is derived from the figure size the user picked (13pt by
    /// default, the menu bar's own text size), so the symbols, gaps and battery
    /// outline scale with it and a larger setting reads as the same design,
    /// bigger. Monospaced digits keep a cell's width still as figures change.
    private struct CompactMetrics {
        /// The size against which every other measure here was tuned.
        static let referenceSize: CGFloat = 13

        let scale: CGFloat
        let valueFont: NSFont
        /// The two stacked rows of network and disk, kept as large as two
        /// rows can be and still fit the bar's height.
        let rowFont: NSFont
        let markerFont: NSFont
        /// A little under the text size: a symbol at the full size reads
        /// heavier than the figure it introduces.
        let symbolPointSize: CGFloat
        /// Between a symbol and its figure.
        let glyphGap: CGFloat
        /// Between two symbol-and-figure pairs in one cell (the sensors).
        let pairGap: CGFloat

        init(textSize: CGFloat) {
            scale = textSize / Self.referenceSize
            valueFont = .monospacedDigitSystemFont(ofSize: textSize, weight: .regular)
            let rowSize = min(max(9.5 * scale, 8), 10.5)
            rowFont = .monospacedDigitSystemFont(ofSize: rowSize, weight: .semibold)
            markerFont = .systemFont(ofSize: rowSize, weight: .bold)
            symbolPointSize = 11.5 * scale
            glyphGap = 3 * scale
            pairGap = 6 * scale
        }
    }

    /// Tinted symbols by name, size and colour: a cell is repainted every time
    /// a figure moves, and the symbols themselves rarely change.
    private static var compactSymbolCache: [String: NSImage] = [:]

    /// The bar's vertical centre line in a cell's own coordinates, which
    /// `translated` has already lifted by the vertical margin.
    private static var compactMidY: CGFloat { Metrics.itemHeight / 2 - Metrics.marginY }

    private static func compact(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let metrics = CompactMetrics(textSize: readout.compactTextSize)
        switch readout.metric {
        case .network, .disk:
            return compactDirections(readout, isDark, metrics)
        case .energy where readout.isBatteryPresent:
            return compactBattery(readout, isDark, metrics)
        case .energy:
            // A Mac with no battery reports its power draw here instead.
            return compactGlyphValue(
                symbolName: "bolt.fill", value: readout.value, templates: ["00W"],
                color: compactColor(readout.verdict, readout, isDark), metrics: metrics)
        case .sensors:
            return compactSensors(readout, isDark, metrics)
        case .pressure, .ram, .cpu, .gpu, .temperature:
            return compactGlyphValue(
                symbolName: readout.metric.symbolName, value: readout.value,
                templates: readout.valueTemplate.map { [$0] } ?? [],
                color: compactColor(readout.verdict, readout, isDark), metrics: metrics)
        }
    }

    /// A verdict as a colour: the bar's own colour while calm, orange when
    /// elevated, red under strain. With the read-out's colour switch off it
    /// stays the bar's own colour, except that an active alarm still shows
    /// red: that is the alarm speaking, and it has its own switch.
    private static func compactColor(
        _ verdict: MenuBarVerdict, _ readout: CombinedMenuBarReadout, _ isDark: Bool
    ) -> NSColor {
        if readout.isAlarm { return .systemRed }
        guard readout.isColored else { return textColor(isDark) }
        switch verdict {
        case .calm: return textColor(isDark)
        case .elevated: return .systemOrange
        case .strained: return .systemRed
        }
    }

    /// A symbol and a figure on one line, both centred on the bar. The figure
    /// reserves the widest of `templates`, so the cell holds still while the
    /// number moves, and drops its unit rather than widen the cell when it
    /// outgrows them: 100% prints as 100 beside a symbol that already names it.
    private static func compactGlyphValue(
        symbolName: String, value: String, templates: [String], color: NSColor,
        metrics: CompactMetrics
    ) -> Cell {
        let font = metrics.valueFont
        let glyph = compactSymbol(symbolName, color: color, pointSize: metrics.symbolPointSize)
        let reserved = templates.map { widthOfString($0, font: font) }.max() ?? 0
        var text = value
        if reserved > 0, widthOfString(text, font: font) > reserved.rounded(.up) {
            text = trimUnit(text)
        }
        let textWidth = max(reserved, widthOfString(text, font: font)).rounded(.up)
        let glyphWidth =
            glyph.map { $0.size.width + (textWidth > 0 ? metrics.glyphGap : 0) } ?? 0
        let width = (glyphWidth + textWidth).rounded(.up)

        return Cell(width: width) { originX in
            translated(originX) {
                if let glyph { drawCompactSymbol(glyph, x: 0) }
                drawCompactText(text, font: font, color: color, x: glyphWidth, width: textWidth)
            }
        }
    }

    /// Network and disk: both directions in two short rows, each behind its
    /// marker, ↑ over ↓ for the network (upload on top, as `directionRows`
    /// has always ordered it) and R over W for the disk. Only the marker
    /// carries colour, blue in and red out, and only while that direction is
    /// moving; the figures stay in the bar's own colour so they read easily.
    ///
    /// The markers sit at the cell's leading edge, so the read-out starts
    /// where its neighbour's gap ends, and the figures are right aligned just
    /// after them so their units line up. The width reserved for a busier
    /// rate is left as empty space after the figures, where it reads as a
    /// little extra room before the next item rather than a hole between the
    /// previous item and the arrows.
    private static func compactDirections(
        _ readout: CombinedMenuBarReadout, _ isDark: Bool, _ metrics: CompactMetrics
    ) -> Cell {
        let rows = readout.directionRows
        let font = metrics.rowFont
        let markerFont = metrics.markerFont
        let symbols = readout.speedSymbols
        let markers = rows.map { row in
            readout.metric == .disk
                ? (row.isInbound ? symbols.input : symbols.output)
                : (row.isInbound ? "\u{2193}" : "\u{2191}")
        }
        let markerWidth =
            (markers.map { widthOfString($0, font: markerFont) }.max() ?? 0).rounded(.up)
        // Reserved for the widest common figure, so the cell does not twitch
        // as a rate moves between KB/s and MB/s. Ten MB/s and over is rare
        // enough to widen the cell while it lasts rather than reserve for it.
        let figureWidth =
            (["000 KB/s", "0.0 MB/s"] + rows.map(\.text))
            .map { widthOfString($0, font: font) }.max()?.rounded(.up) ?? 0
        let gap = 2 * metrics.scale
        let width = (markerWidth + gap + figureWidth).rounded(.up)
        let figureColor = textColor(isDark)
        let markerColors = rows.map { row -> NSColor in
            guard readout.isColored, readout.isDirectionActive(input: row.isInbound) else {
                return figureColor
            }
            return row.isInbound ? .systemBlue : .systemRed
        }

        return Cell(width: width) { originX in
            translated(originX) {
                let lineGap: CGFloat = 2.5
                let top = pixelAligned(compactMidY + lineGap / 2)
                let bottom = pixelAligned(compactMidY - lineGap / 2 - font.capHeight)
                let shownWidth =
                    (rows.map { widthOfString($0.text, font: font) }.max() ?? 0).rounded(.up)
                for (index, baseline) in zip(rows.indices, [top, bottom]) {
                    drawCompactText(
                        markers[index], font: markerFont, color: markerColors[index], x: 0,
                        width: markerWidth, baseline: baseline)
                    drawCompactText(
                        rows[index].text, font: font, color: figureColor, x: markerWidth + gap,
                        width: shownWidth, baseline: baseline, alignment: .right)
                }
            }
        }
    }

    /// The battery: its outline, then the charge with the time estimate
    /// stacked under it, as the Classic battery details shape stacks them.
    /// The time is time to full while charging (the bolt in the outline says
    /// which) and time left on battery. macOS gives no estimate while the
    /// charge is held at a limit, or for a while after the power source
    /// changes; then the charge stands alone on one line at the full figure
    /// size instead of sitting over "n/a".
    ///
    /// The outline's fill is coloured by charge, or mint in Low Power Mode
    /// (see `compactBatteryFill`).
    private static func compactBattery(
        _ readout: CombinedMenuBarReadout, _ isDark: Bool, _ metrics: CompactMetrics
    ) -> Cell {
        let color = compactColor(readout.verdict, readout, isDark)
        let fill = compactBatteryFill(
            charge: readout.batteryCharge ?? 1, isLowPowerMode: readout.isLowPowerMode,
            isColored: readout.isColored, isDark: isDark)
        let textX = (batteryOutlineWidth * metrics.scale + metrics.glyphGap).rounded(.up)
        let time = readout.batteryTimeText
        // Two rows have the network rows' size, one row the full figure size.
        let font = time == nil ? metrics.valueFont : metrics.rowFont
        var percent = readout.value
        let textWidth: CGFloat
        if let time {
            // Reserved for "100%" and a two-digit hour, so the column holds
            // still as the charge and the estimate move.
            textWidth =
                ([percent, time, "100%", "00:00"].map { widthOfString($0, font: font) }
                .max() ?? 0).rounded(.up)
        } else {
            let reserved = readout.valueTemplate.map { widthOfString($0, font: font) } ?? 0
            if reserved > 0, widthOfString(percent, font: font) > reserved.rounded(.up) {
                percent = trimUnit(percent)
            }
            textWidth = max(reserved, widthOfString(percent, font: font)).rounded(.up)
        }
        let width = textX + textWidth
        let timeColor = textColor(isDark).withAlphaComponent(0.7)

        return Cell(width: width.rounded(.up)) { originX in
            translated(originX) {
                // The outline is drawn at Stats' fixed size, so it is scaled
                // about the bar's centre line to keep pace with the text.
                if let context = NSGraphicsContext.current?.cgContext {
                    context.saveGState()
                    context.translateBy(x: 0, y: compactMidY)
                    context.scaleBy(x: metrics.scale, y: metrics.scale)
                    context.translateBy(x: 0, y: -compactMidY)
                    drawBatteryOutline(readout, isDark, x: 0, fill: fill)
                    context.restoreGState()
                }
                guard let time else {
                    drawCompactText(percent, font: font, color: color, x: textX, width: textWidth)
                    return
                }
                let lineGap: CGFloat = 2.5
                drawCompactText(
                    percent, font: font, color: color, x: textX, width: textWidth,
                    baseline: pixelAligned(compactMidY + lineGap / 2))
                drawCompactText(
                    time, font: font, color: timeColor, x: textX, width: textWidth,
                    baseline: pixelAligned(compactMidY - lineGap / 2 - font.capHeight))
            }
        }
    }

    /// The Compact battery's fill: green above 40%, yellow from 20% to 40%,
    /// red below 20%, and a mint green in Low Power Mode whatever the charge.
    /// With the colour switch off the fill is the bar's
    /// own colour, except that below 20% stays red: a flat battery is a
    /// warning, not decoration, as in the Classic battery shapes.
    nonisolated static func compactBatteryFill(
        charge: Double, isLowPowerMode: Bool, isColored: Bool, isDark: Bool
    ) -> NSColor {
        guard isColored else {
            return batteryColor(charge, isDark: isDark, isLowPowerMode: false, colored: false)
        }
        if isLowPowerMode { return .systemMint }
        if charge > 0.4 { return .systemGreen }
        if charge >= 0.2 { return .systemYellow }
        return .systemRed
    }

    /// The chosen sensors side by side, each figure behind the symbol of its
    /// kind, so "21W" sits beside a bolt and "68°" beside a thermometer and
    /// neither has to be remembered. Temperatures take the verdict colours.
    private static func compactSensors(
        _ readout: CombinedMenuBarReadout, _ isDark: Bool, _ metrics: CompactMetrics
    ) -> Cell {
        let cells = readout.sensorCells
        guard !cells.isEmpty else {
            // Nothing chosen: the symbol alone keeps the item visible and
            // clickable, which is the way back to the panel that chooses.
            return compactGlyphValue(
                symbolName: readout.metric.symbolName, value: "", templates: [],
                color: textColor(isDark), metrics: metrics)
        }
        let parts = cells.map { cell in
            compactGlyphValue(
                symbolName: cell.symbolName, value: cell.text, templates: cell.templates,
                color: compactColor(cell.verdict, readout, isDark), metrics: metrics)
        }
        let pairGap = metrics.pairGap.rounded()
        let width = parts.reduce(0) { $0 + $1.width } + pairGap * CGFloat(parts.count - 1)

        // Each part translates to its own origin, so this cell does not.
        return Cell(width: width) { originX in
            var x = originX
            for part in parts {
                part.draw(x)
                x += part.width + pairGap
            }
        }
    }

    /// An SF Symbol at `pointSize`, tinted. Symbols are templates, so the tint
    /// is painted over the glyph inside its own small bitmap rather than over
    /// the shared cell context, where it would recolour its neighbours.
    private static func compactSymbol(
        _ name: String, color: NSColor, pointSize: CGFloat
    ) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(color)"
        if let cached = compactSymbolCache[key] { return cached }
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let symbol = base.withSymbolConfiguration(
                .init(pointSize: pointSize, weight: .regular))
        else { return nil }
        let image = MenuBarReadoutImage.render(
            width: symbol.size.width, height: symbol.size.height
        ) { size in
            let rect = NSRect(origin: .zero, size: size)
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
        }
        compactSymbolCache[key] = image
        return image
    }

    /// A symbol centred on the bar's centre line.
    private static func drawCompactSymbol(_ image: NSImage, x: CGFloat) {
        let size = image.size
        image.draw(
            in: NSRect(
                x: x, y: pixelAligned(compactMidY - size.height / 2), width: size.width,
                height: size.height))
    }

    /// One line of text with its cap height centred on the bar, which is how
    /// the system's own menu bar items sit. `baseline` overrides the centring
    /// for the stacked rows.
    private static func drawCompactText(
        _ text: String, font: NSFont, color: NSColor, x: CGFloat, width: CGFloat,
        baseline: CGFloat? = nil, alignment: NSTextAlignment = .left
    ) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        // Without `.usesLineFragmentOrigin` the rect's origin is the baseline.
        let y = baseline ?? pixelAligned(compactMidY - font.capHeight / 2)
        NSAttributedString(string: text, attributes: attributes).draw(
            with: CGRect(x: x, y: y, width: width, height: font.pointSize + 2))
    }

    /// Round to the device pixel grid, so text and symbols land crisp rather
    /// than smeared across two rows of pixels.
    private static func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    // MARK: - Mini (Kit/Widgets/Mini.swift)

    /// A three-letter caption in 7pt over the value in 12pt, left aligned. The
    /// caption is on by default, which is also what makes the cell narrower: the
    /// value drops from 14pt to 12pt to leave room for it.
    private static func mini(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let labelState = true
        let valueSize: CGFloat = labelState ? 12 : 14
        let caption = readout.captionText
        var value = readout.value
        let color = miniColor(readout, isDark)
        // DEVIATION: Stats fixes this cell at 31 points wide, which is about
        // what "100%" needs, so a two-digit figure sits in a cell with nine
        // points of empty space after it. The cell is sized to its own content
        // instead, floored at `miniFloorWidth` so the common two and three
        // character figures all share one width. Digits are monospaced, so the
        // width is a function of how many characters there are rather than
        // which ones: without that the cell, and the whole bar with it, would
        // shift a fraction of a point every time a digit changed.
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .regular)
        let captionFont = NSFont.systemFont(ofSize: 7, weight: .light)
        // Reserve the width of the widest figure this read-out can show, so the
        // cell holds still while the number moves. Without a reservation the
        // cell tracks the current string, and "5%" and "26%" are four points
        // apart: every crossing of ten would shuffle the bar.
        let reserved =
            readout.valueTemplate.map { widthOfString($0, font: valueFont) } ?? miniFloorWidth
        let content = max(
            reserved, labelState ? widthOfString(caption, font: captionFont) : 0)
        // Rounding the reservation up already covers the fraction; the extra
        // point on top of it was pure trailing air.
        let width = content.rounded(.up) + (2 * Metrics.marginX)
        // A figure wider than its reservation loses its unit rather than its
        // cell's width: "100%" becomes "100", which is unambiguous under a
        // caption that already names the read-out. Stats does the same when a
        // value outgrows its widget.
        if widthOfString(value, font: valueFont) > content { value = trimUnit(value) }

        return Cell(width: width) { originX in
            translated(originX) {
                var origin = CGPoint(x: Metrics.marginX, y: (Metrics.itemHeight - valueSize) / 2)
                let style = NSMutableParagraphStyle()
                style.alignment = labelState ? .left : .center

                if labelState {
                    let captionStyle = NSMutableParagraphStyle()
                    captionStyle.alignment = .left
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: captionFont,
                        .foregroundColor: textColor(isDark),
                        .paragraphStyle: captionStyle,
                    ]
                    let rect = CGRect(
                        x: origin.x, y: 12, width: width - (Metrics.marginX * 2), height: 7)
                    NSAttributedString(string: caption, attributes: attributes).draw(with: rect)
                    origin.y = 1
                }

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: valueFont,
                    .foregroundColor: color,
                    .paragraphStyle: style,
                ]
                let rect = CGRect(
                    x: origin.x, y: origin.y, width: width - (Metrics.marginX * 2),
                    height: valueSize + 1)
                NSAttributedString(string: value, attributes: attributes).draw(with: rect)
            }
        }
    }

    /// The fallback reservation for a read-out with no bounded figure to
    /// reserve for (the throughput ones).
    private static let miniFloorWidth: CGFloat = 22

    /// Drop a trailing unit so an oversized figure keeps its cell: "100%"
    /// becomes "100", "100\u{00B0}" becomes "100". Digits, a decimal point and
    /// a leading minus survive; everything after them goes.
    nonisolated private static func trimUnit(_ value: String) -> String {
        let trimmed = value.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return trimmed.isEmpty ? value : String(trimmed)
    }

    /// Stats colours Mini by the module's configured colour mode. The percentage
    /// modules ship `utilization`, memory pressure ships `pressure`, and the
    /// battery ships `monochrome` (with the scale reversed, so a low battery is
    /// the alarming end). An active alarm overrides all of it with red.
    private static func miniColor(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> NSColor {
        if readout.isAlarm { return .systemRed }
        guard readout.isColored else { return textColor(isDark) }
        switch readout.metric {
        case .pressure:
            return readout.pressureLevel.menuBarPressureColor
        case .ram, .cpu, .gpu, .temperature:
            return usageColor(readout.fraction)
        case .energy:
            return readout.isBatteryPresent
                ? usageColor(readout.fraction, reversed: true) : textColor(isDark)
        case .network, .disk, .sensors:
            return textColor(isDark)
        }
    }

    // MARK: - Line chart (Kit/Widgets/LineChart.swift + LineChartView)

    /// A filled sparkline over the recent history, inside a 1px frame. Stats
    /// ships the line chart with a frame and no box for every module that offers
    /// it, and colours the fill with the system accent.
    private static func lineChart(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let labelState = true
        let letterWidth: CGFloat = 6
        let chartWidth = Metrics.width
        let width =
            chartWidth + (Metrics.marginX * 2)
            + (labelState ? letterWidth + Metrics.spacing : 0)
        let points = trailing(readout.trail, count: historyPoints)
        let caption = readout.captionText
        let color = chartColor(readout, isDark)

        return Cell(width: width) { originX in
            translated(originX) {
                let lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
                let offset = lineWidth / 2
                var x: CGFloat = 0

                if labelState {
                    drawVerticalLabel(caption, x: x, letterWidth: letterWidth, isDark: isDark)
                    x = letterWidth + Metrics.spacing
                }

                let box = NSBezierPath(
                    roundedRect: NSRect(
                        x: x + offset, y: offset,
                        width: chartWidth - offset * 2,
                        height: Metrics.frameHeight - (offset * 2)),
                    xRadius: 2, yRadius: 2)

                drawLineChart(
                    points: points, in: box.bounds, color: color, scale: .none, lineWidth: lineWidth
                )

                textColor(isDark).set()
                box.lineWidth = lineWidth
                box.stroke()
            }
        }
    }

    /// LineChartView's paint: a stroked polyline over the points, then the area
    /// under it filled with a vertical gradient of the same colour.
    private static func drawLineChart(
        points: [Double], in rect: NSRect, color: NSColor, scale: MenuBarChartScale,
        lineWidth: CGFloat
    ) {
        guard points.count > 1, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)

        let maxValue = points.max() ?? 0
        let gradientColor = color.withAlphaComponent(0.5)
        let gradient = NSGradient(colors: [
            gradientColor.withAlphaComponent(0.5), gradientColor.withAlphaComponent(1.0),
        ])

        let xRatio = rect.width / CGFloat(points.count - 1)
        let linePoints: [CGPoint] = points.enumerated().map { index, value in
            let y = scaleValue(
                scale: scale, value: value, maxValue: maxValue, zeroValue: 0.01,
                maxHeight: rect.height, limit: 1)
            return CGPoint(x: rect.minX + CGFloat(index) * xRatio, y: rect.minY + y)
        }

        let line = NSBezierPath()
        line.move(to: linePoints[0])
        for point in linePoints.dropFirst() { line.line(to: point) }
        color.set()
        line.lineWidth = lineWidth
        line.stroke()

        guard let area = line.copy() as? NSBezierPath else { return }
        area.line(to: CGPoint(x: linePoints[linePoints.count - 1].x, y: rect.minY))
        area.line(to: CGPoint(x: linePoints[0].x, y: rect.minY))
        area.close()
        if let gradient {
            gradient.draw(in: area, angle: 90)
        } else {
            gradientColor.set()
            area.fill()
        }
    }

    // MARK: - Bar chart (Kit/Widgets/BarChart.swift)

    /// One vertical bar per value, inside a 1px frame. Stats gives this the CPU's
    /// per-core figures, and a single bar for the modules that have one number;
    /// the cell width comes from its step table, keyed on how many bars there are.
    private static func barChart(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let labelState = true
        let letterWidth: CGFloat = 6
        let bars = readout.bars
        let caption = readout.captionText
        let color = chartColor(readout, isDark)
        let lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        let offset = lineWidth / 2

        var width: CGFloat = Metrics.marginX * 2
        switch bars.count {
        case 0, 1: width += 10 + (offset * 2)
        case 2: width += 22
        case 3...4: width += 30
        case 5...8: width += 40
        case 9...12: width += 50
        case 13...16: width += 76
        case 17...32: width += 84
        default: width += 118
        }
        if labelState { width += letterWidth + Metrics.spacing }
        let totalWidth = width

        return Cell(width: totalWidth) { originX in
            translated(originX) {
                var x: CGFloat = 0
                if labelState {
                    drawVerticalLabel(caption, x: x, letterWidth: letterWidth, isDark: isDark)
                    x = letterWidth + Metrics.spacing
                }

                let box = NSBezierPath(
                    roundedRect: NSRect(
                        x: x + offset, y: offset,
                        width: totalWidth - x - (offset * 2) - (Metrics.marginX * 2),
                        height: Metrics.frameHeight - (offset * 2)),
                    xRadius: 2, yRadius: 2)

                guard !bars.isEmpty else { return }
                let partitionMargin: CGFloat = 0.5
                let partitionWidth =
                    (box.bounds.width / CGFloat(bars.count))
                    - (bars.count > 1 ? partitionMargin : 0)
                let maxPartitionHeight = box.bounds.height

                x += offset
                for bar in bars {
                    var y = offset
                    for segment in bar {
                        let height = maxPartitionHeight * CGFloat(min(max(segment.value, 0), 1))
                        let partition = NSBezierPath(
                            rect: NSRect(x: x, y: y, width: partitionWidth, height: height))
                        (segment.color ?? color).set()
                        partition.fill()
                        y += height
                    }
                    x += partitionWidth + partitionMargin
                }

                textColor(isDark).set()
                box.lineWidth = lineWidth
                box.stroke()
            }
        }
    }

    // MARK: - Pie chart (Kit/Widgets/PieChart.swift + PieChartView)

    /// A filled ring, drawn as one arc per segment starting at the top and going
    /// anticlockwise, with the unused remainder in translucent grey.
    private static func pieChart(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let size = Metrics.frameHeight + (Metrics.marginX * 2)
        var segments = readout.gaugeSegments(isDark: isDark)

        return Cell(width: size) { originX in
            translated(originX) {
                let frame = NSRect(x: 0, y: 0, width: size, height: Metrics.frameHeight)
                let arcWidth = min(frame.width, frame.height) / 2
                let fullCircle = 2 * CGFloat.pi

                let total = segments.reduce(0) { $0 + $1.value }
                if total < 1 {
                    segments.append(
                        MenuBarWidgetSegment(
                            1 - total, color: NSColor.lightGray.withAlphaComponent(0.5)))
                }

                let center = CGPoint(x: frame.midX, y: frame.midY)
                let radius = (min(frame.width, frame.height) - arcWidth) / 2
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.setShouldAntialias(true)
                context.setLineWidth(arcWidth)
                context.setLineCap(.butt)

                var previousAngle = CGFloat.pi / 2
                for segment in segments.reversed() {
                    let currentAngle = previousAngle + (CGFloat(segment.value) * fullCircle)
                    if let color = segment.color { context.setStrokeColor(color.cgColor) }
                    context.addArc(
                        center: center, radius: radius, startAngle: previousAngle,
                        endAngle: currentAngle, clockwise: false)
                    context.strokePath()
                    previousAngle = currentAngle
                }
            }
        }
    }

    // MARK: - Tachometer (Kit/Widgets/Tachometer.swift + TachometerGraphView)

    /// The pie chart's half-ring cousin: the same arcs over pi radians, mirrored
    /// horizontally so it fills left to right like a dial.
    private static func tachometer(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let size = Metrics.frameHeight + (Metrics.marginX * 2)
        var segments = readout.gaugeSegments(isDark: isDark)

        return Cell(width: size) { originX in
            translated(originX) {
                let frame = NSRect(x: 0, y: 0, width: size, height: Metrics.frameHeight)
                let arcWidth = min(frame.width, frame.height) / 2

                let total = segments.reduce(0) { $0 + $1.value }
                if total < 1 {
                    segments.append(
                        MenuBarWidgetSegment(
                            1 - total, color: NSColor.lightGray.withAlphaComponent(0.5)))
                }

                let center = CGPoint(x: frame.midX, y: frame.midY)
                let radius = (min(frame.width, frame.height) - arcWidth) / 2
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.setShouldAntialias(true)
                context.setLineWidth(arcWidth)
                context.setLineCap(.butt)

                context.saveGState()
                context.translateBy(x: frame.width, y: -4)
                context.scaleBy(x: -1, y: 1)

                var previousAngle: CGFloat = 0
                for segment in segments {
                    let currentAngle = previousAngle + (CGFloat(segment.value) * CGFloat.pi)
                    if let color = segment.color { context.setStrokeColor(color.cgColor) }
                    context.addArc(
                        center: center, radius: radius, startAngle: previousAngle,
                        endAngle: currentAngle, clockwise: false)
                    context.strokePath()
                    previousAngle = currentAngle
                }
                context.restoreGState()
            }
        }
    }

    // MARK: - Network chart (Kit/Widgets/NetworkChart.swift)

    /// A mirrored sparkline: the first direction above the mid-line, the second
    /// below, each scaled against its own maximum so a quiet upload is still
    /// visible next to a busy download.
    private static func networkChart(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let labelState = true
        let letterWidth: CGFloat = 6
        let chartWidth = Metrics.width
        let width =
            chartWidth + (Metrics.marginX * 2)
            + (labelState ? letterWidth + Metrics.spacing : 0)
        let top = trailing(readout.trail, count: historyPoints)
        let bottom = trailing(readout.secondaryTrail, count: historyPoints)
        let caption = readout.captionText
        // Stats' network chart colours are fixed per direction (secondBlue over
        // secondRed); only the speed shape fades an idle direction out.
        let topColor = NSColor.systemBlue
        let bottomColor = NSColor.systemRed

        return Cell(width: width) { originX in
            translated(originX) {
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                let lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
                let offset = lineWidth / 2
                var x: CGFloat = 0

                if labelState {
                    drawVerticalLabel(caption, x: x, letterWidth: letterWidth, isDark: isDark)
                    x = letterWidth + Metrics.spacing
                }

                let box = NSBezierPath(
                    roundedRect: NSRect(
                        x: x + offset, y: offset,
                        width: chartWidth - offset * 2,
                        height: Metrics.frameHeight - (offset * 2)),
                    xRadius: 2, yRadius: 2)

                let chartFrame = NSRect(
                    x: x + offset + lineWidth, y: offset,
                    width: box.bounds.width - (offset * 2 + lineWidth),
                    height: box.bounds.height - offset)
                let count = min(top.count, bottom.count)
                guard count > 1 else {
                    textColor(isDark).set()
                    box.lineWidth = lineWidth
                    box.stroke()
                    return
                }

                let topMax = max(top.max() ?? 0, 1)
                let bottomMax = max(bottom.max() ?? 0, 1)
                let center = chartFrame.height / 2 + chartFrame.origin.y
                let xRatio = (chartFrame.width + (lineWidth * 3)) / CGFloat(count)
                let columnX = { (point: Int) -> CGFloat in
                    (CGFloat(point) * xRatio) + (chartFrame.origin.x - lineWidth)
                }
                let topY = { (point: Int) -> CGFloat in
                    scaleValue(
                        scale: .linear, value: top[point], maxValue: topMax, zeroValue: 256,
                        maxHeight: chartFrame.height / 2, limit: 1) + center
                }
                let bottomY = { (point: Int) -> CGFloat in
                    center
                        - scaleValue(
                            scale: .linear, value: bottom[point], maxValue: bottomMax,
                            zeroValue: 256, maxHeight: chartFrame.height / 2, limit: 1)
                }

                let topLine = NSBezierPath()
                topLine.move(to: CGPoint(x: columnX(0), y: topY(0)))
                let bottomLine = NSBezierPath()
                bottomLine.move(to: CGPoint(x: columnX(0), y: bottomY(0)))
                for index in 1..<count {
                    topLine.line(to: CGPoint(x: columnX(index), y: topY(index)))
                    bottomLine.line(to: CGPoint(x: columnX(index), y: bottomY(index)))
                }

                topColor.setStroke()
                topLine.lineWidth = lineWidth
                topLine.stroke()
                bottomColor.setStroke()
                bottomLine.lineWidth = lineWidth
                bottomLine.stroke()

                let fillRect = NSRect(
                    x: chartFrame.origin.x - lineWidth, y: chartFrame.origin.y,
                    width: chartFrame.width + (lineWidth * 3), height: chartFrame.height)

                for (line, color) in [(topLine, topColor), (bottomLine, bottomColor)] {
                    guard let area = line.copy() as? NSBezierPath else { continue }
                    context.saveGState()
                    area.line(to: CGPoint(x: columnX(count - 1), y: center))
                    area.line(to: CGPoint(x: columnX(0), y: center))
                    area.close()
                    area.addClip()
                    color.withAlphaComponent(0.5).setFill()
                    NSBezierPath(rect: fillRect).fill()
                    context.restoreGState()
                }

                textColor(isDark).set()
                box.lineWidth = lineWidth
                box.stroke()
            }
        }
    }

    // MARK: - Speed (Kit/Widgets/Speed.swift)

    /// Two stacked rates in 9pt, right aligned, with a direction marker on the
    /// left. Stats' Network module ships coloured dots as that marker and the
    /// Disk module ships the letters R and W, so each keeps its own here.
    ///
    /// Which rate is on top is `directionRows`' to say (upload over download for
    /// the network, read over write for the disk), and the marker takes its
    /// colour from the row it sits beside rather than from its position, so the
    /// two can never disagree about which line is which.
    private static func speed(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let icon: SpeedIcon = readout.metric == .disk ? .chars : .dots
        let rowWidth: CGFloat = 48
        let iconWidth: CGFloat = 7
        let width = iconWidth + rowWidth
        let rows = readout.directionRows
        let iconColors = rows.map { readout.speedIconColor(input: $0.isInbound, isDark: isDark) }
        let symbols = readout.speedSymbols

        return Cell(width: width) { originX in
            translated(originX) {
                let rowHeight = Metrics.frameHeight / 2
                let style = NSMutableParagraphStyle()
                style.alignment = .right
                // Top row first, in step with `rows`.
                let rowYs: [CGFloat] = [rowHeight + 1, 1]

                let valueColor = textColor(isDark)
                for (row, y) in zip(rows, rowYs) {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9, weight: .light),
                        .foregroundColor: valueColor,
                        .paragraphStyle: style,
                    ]
                    let rect = CGRect(
                        x: Metrics.marginX + iconWidth, y: y,
                        width: rowWidth - (Metrics.marginX * 2), height: rowHeight)
                    NSAttributedString(string: row.text, attributes: attributes).draw(with: rect)
                }

                switch icon {
                case .dots:
                    let size: CGFloat = 6
                    let dotY = (rowHeight - size) / 2
                    let dotYs: [CGFloat] = [10.5, dotY - 0.2]
                    for (color, y) in zip(iconColors, dotYs) {
                        let circle = NSBezierPath(
                            ovalIn: CGRect(
                                x: Metrics.marginX, y: y, width: size, height: size))
                        color.set()
                        circle.fill()
                    }
                case .chars:
                    for ((row, color), y) in zip(zip(rows, iconColors), rowYs) {
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                            .foregroundColor: color,
                            .paragraphStyle: NSMutableParagraphStyle(),
                        ]
                        let rect = CGRect(
                            x: Metrics.marginX, y: y, width: 8, height: rowHeight)
                        let symbol = row.isInbound ? symbols.input : symbols.output
                        NSAttributedString(string: symbol, attributes: attributes).draw(with: rect)
                    }
                }
            }
        }
    }

    private enum SpeedIcon {
        case dots
        case chars
    }

    // MARK: - Battery (Kit/Widgets/Battery.swift)

    /// The battery outline with its terminal nub, filled to the charge level, and
    /// the AC bolt or plug punched out of the middle when a charger is attached.
    /// Stats' default here is monochrome: the fill only turns red below 20%.
    private static func battery(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        Cell(width: batteryOutlineWidth) { originX in
            translated(originX) { drawBatteryOutline(readout, isDark, x: 0) }
        }
    }

    private static let batterySize = CGSize(width: 22, height: 12)
    private static let batteryBorderWidth: CGFloat = 1
    /// Outline + the terminal nub, as Stats accumulates it.
    private static var batteryOutlineWidth: CGFloat {
        batterySize.width + batteryBorderWidth * 2 + 2
    }

    /// The outline at `x` within the current cell, so it can be drawn on its
    /// own or after the figures that describe it.
    private static func drawBatteryOutline(
        _ readout: CombinedMenuBarReadout, _ isDark: Bool, x originOffset: CGFloat,
        fill: NSColor? = nil
    ) {
        let batterySize = Self.batterySize
        let borderWidth = Self.batteryBorderWidth
        let charge = readout.batteryCharge
        let isCharging = readout.isBatteryCharging
        let isOnAC = readout.isOnAC
        let isLowPowerMode = readout.isLowPowerMode

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let offset: CGFloat = 0.5
        let batteryRadius: CGFloat = 2
        let frame = NSBezierPath(
            roundedRect: NSRect(
                x: originOffset + borderWidth + offset,
                y: ((Metrics.frameHeight - batterySize.height) / 2) + offset,
                width: batterySize.width - borderWidth,
                height: batterySize.height - borderWidth),
            xRadius: batteryRadius, yRadius: batteryRadius)

        textColor(isDark).withAlphaComponent(0.5).set()
        frame.lineWidth = borderWidth
        frame.stroke()

        // Positive terminal: a 2x4 nub with the outer corners rounded.
        let nubRect = NSRect(
            x: frame.bounds.maxX + 1, y: frame.bounds.midY - 2, width: 2, height: 4)
        let radius: CGFloat = 1
        let nub = NSBezierPath()
        nub.move(to: CGPoint(x: nubRect.minX, y: nubRect.minY))
        nub.line(to: CGPoint(x: nubRect.maxX - radius, y: nubRect.minY))
        nub.appendArc(
            withCenter: CGPoint(x: nubRect.maxX - radius, y: nubRect.minY + radius),
            radius: radius, startAngle: -90, endAngle: 0)
        nub.line(to: CGPoint(x: nubRect.maxX, y: nubRect.maxY - radius))
        nub.appendArc(
            withCenter: CGPoint(x: nubRect.maxX - radius, y: nubRect.maxY - radius),
            radius: radius, startAngle: 0, endAngle: 90)
        nub.line(to: CGPoint(x: nubRect.minX, y: nubRect.maxY))
        nub.close()
        nub.fill()

        if let charge {
            let maxWidth = batterySize.width - offset * 2 - borderWidth * 2 - 1
            let innerOffset = -offset + borderWidth + 1
            let inner = NSBezierPath(
                roundedRect: NSRect(
                    x: frame.bounds.origin.x + innerOffset,
                    y: frame.bounds.origin.y + innerOffset,
                    width: max(1, maxWidth * CGFloat(charge)),
                    height: batterySize.height - offset * 2 - borderWidth * 2 - 1),
                xRadius: 1, yRadius: 1)
            (fill
                ?? batteryColor(
                    charge, isDark: isDark, isLowPowerMode: isLowPowerMode,
                    colored: readout.isColored)).set()
            inner.fill()
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: textColor(isDark),
                .paragraphStyle: NSMutableParagraphStyle(),
            ]
            let rect = CGRect(
                x: frame.bounds.midX - 3, y: frame.bounds.midY - 4, width: 8, height: 12)
            NSAttributedString(string: "?", attributes: attributes).draw(with: rect)
        }

        if isOnAC {
            drawACIcon(
                context: context,
                center: CGPoint(x: frame.bounds.midX, y: frame.bounds.midY),
                height: 12, charging: isCharging, isDark: isDark)
        }
    }

    /// Stats' AC marker: a lightning bolt while charging, a plug otherwise, both
    /// filled and then stroked in destination-out so the shape reads as a hole
    /// punched through whatever it sits on.
    private static func drawACIcon(
        context: CGContext, center: CGPoint, height: CGFloat, charging: Bool, isDark: Bool
    ) {
        var points: [CGPoint] = []

        if charging {
            let iconSize = CGSize(width: 9, height: height + 6)
            let minPoint = CGPoint(
                x: center.x - (iconSize.width / 2), y: center.y - (iconSize.height / 2))
            let maxPoint = CGPoint(
                x: center.x + (iconSize.width / 2), y: center.y + (iconSize.height / 2))
            points = [
                CGPoint(x: center.x - 3, y: minPoint.y),
                CGPoint(x: maxPoint.x, y: center.y + 1.5),
                CGPoint(x: center.x + 1, y: center.y + 1.5),
                CGPoint(x: center.x + 3, y: maxPoint.y),
                CGPoint(x: minPoint.x, y: center.y - 1.5),
                CGPoint(x: center.x - 1, y: center.y - 1.5),
            ]
        } else {
            let iconSize = CGSize(width: 9, height: height + 2)
            let minY = center.y - (iconSize.height / 2)
            let maxY = center.y + (iconSize.height / 2)
            points = [
                CGPoint(x: center.x - 1.5, y: minY + 0.5),
                CGPoint(x: center.x + 1.5, y: minY + 0.5),
                CGPoint(x: center.x + 1.5, y: center.y - 2.5),
                CGPoint(x: center.x + 4, y: center.y + 0.5),
                CGPoint(x: center.x + 4, y: center.y + 4.25),
                CGPoint(x: center.x + 2.75, y: center.y + 4.25),
                CGPoint(x: center.x + 2.75, y: maxY - 0.25),
                CGPoint(x: center.x + 0.25, y: maxY - 0.25),
                CGPoint(x: center.x + 0.25, y: center.y + 4.25),
                CGPoint(x: center.x - 0.25, y: center.y + 4.25),
                CGPoint(x: center.x - 0.25, y: maxY - 0.25),
                CGPoint(x: center.x - 2.75, y: maxY - 0.25),
                CGPoint(x: center.x - 2.75, y: center.y + 4.25),
                CGPoint(x: center.x - 4, y: center.y + 4.25),
                CGPoint(x: center.x - 4, y: center.y + 0.5),
                CGPoint(x: center.x - 1.5, y: center.y - 2.5),
                CGPoint(x: center.x - 1.5, y: minY + 0.5),
            ]
        }

        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.line(to: points[0])

        textColor(isDark).set()
        path.fill()

        context.saveGState()
        context.setBlendMode(.destinationOut)
        textColor(isDark).set()
        path.lineWidth = 1
        path.stroke()
        context.restoreGState()
    }

    // MARK: - Battery details (Kit/Widgets/Battery.swift, `additional`)

    /// The charge and the time estimate beside the battery outline, which is
    /// Stats' Battery widget with its `additional` setting on
    /// "percentageAndTime": two 9pt rows to the left of the outline, its own
    /// spacing between them, and the outline drawn exactly as it is on its own.
    ///
    /// FIXED: this drew the figures and no outline, contradicting its own
    /// description, so choosing it traded the battery picture for the numbers
    /// instead of having both.
    ///
    /// The time is the estimate to empty, or to full while charging. macOS
    /// gives no estimate for the first minutes after a change of power source
    /// and sometimes not at all, and Stats prints "n/a" for that rather than
    /// dropping the row, so the widget keeps one width.
    private static func batteryDetails(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let percentage = readout.value
        let time = readout.batteryTimeText ?? t("n/a")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        // Reserved, not measured: "80%" over "11:09" must not resize into
        // "100%" over "n/a" and shuffle the bar every time an estimate
        // arrives or goes.
        let rowsWidth = max(
            widthOfString("100%", font: font), widthOfString("00:00", font: font)
        ).rounded(.up)
        let width = rowsWidth + Metrics.spacing + batteryOutlineWidth

        return Cell(width: width) { originX in
            translated(originX) {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: textColor(isDark), .paragraphStyle: style,
                ]
                let rowHeight = Metrics.frameHeight / 2
                NSAttributedString(string: percentage, attributes: attributes).draw(
                    with: CGRect(
                        x: Metrics.marginX, y: rowHeight + 1, width: rowsWidth, height: rowHeight))
                NSAttributedString(string: time, attributes: attributes).draw(
                    with: CGRect(x: Metrics.marginX, y: 1, width: rowsWidth, height: rowHeight))

                drawBatteryOutline(readout, isDark, x: rowsWidth + Metrics.spacing)
            }
        }
    }

    // MARK: - Memory (Kit/Widgets/Memory.swift)

    /// Free over used, each row prefixed with `F:` / `U:` and right aligned.
    private static func memory(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let rows = readout.memoryRows ?? (free: "0", used: "0")
        let letterWidth: CGFloat = 8
        let base: CGFloat = 50
        let symbolsX = letterWidth + Metrics.spacing * 2
        let width = base + symbolsX + (Metrics.marginX * 2)

        return Cell(width: width) { originX in
            translated(originX) {
                let rowHeight = Metrics.frameHeight / 2
                let freeY = rowHeight + 1
                let usedY: CGFloat = 1
                let style = NSMutableParagraphStyle()
                style.alignment = .right

                var attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .light),
                    .foregroundColor: textColor(isDark),
                    .paragraphStyle: style,
                ]
                for (symbol, y) in [("F:", freeY), ("U:", usedY)] {
                    let rect = CGRect(
                        x: Metrics.marginX, y: y, width: letterWidth, height: rowHeight)
                    NSAttributedString(string: symbol, attributes: attributes).draw(with: rect)
                }

                let color: NSColor =
                    if readout.isAlarm {
                        .systemRed
                    } else if !readout.isColored {
                        textColor(isDark)
                    } else if readout.metric == .pressure {
                        readout.pressureLevel.menuBarPressureColor
                    } else {
                        usageColor(readout.fraction)
                    }
                attributes[.foregroundColor] = color
                for (value, y) in [(rows.free, freeY), (rows.used, usedY)] {
                    let rect = CGRect(
                        x: symbolsX, y: y, width: base + (Metrics.marginX * 2), height: rowHeight)
                    NSAttributedString(string: value, attributes: attributes).draw(with: rect)
                }
            }
        }
    }

    // MARK: - Stack (Kit/Widgets/Stack.swift)

    /// Free-form values packed into the cell, the way Stats' Stack widget
    /// packs them: pairs stacked into 10pt columns, and a lone trailing value
    /// drawn on its own as one 13pt row. Each column is sized to its own
    /// content, with Stats' spacing opening, closing and between columns.
    private static func stack(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let rows = readout.stackRows
        guard !rows.isEmpty else { return Cell(width: 0) { _ in } }
        // DEVIATION: Stats sizes these 13pt and 10pt, which made the stack the
        // largest thing on the bar: a lone sensor read bigger than the CPU
        // figure beside it. These are the memory widget's sizes, so a stack
        // cell now matches the other read-outs instead of shouting over them.
        //
        // Monospaced digits for the same reason the mini shape uses them: a
        // sensor figure changes constantly, and with proportional digits the
        // cell would resize by a point whenever a 1 became a 2, moving
        // everything to its left on the bar.
        let oneRowFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let twoRowFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .light)

        // Each row is measured by its reservation, not by what it currently
        // reads, so a sensor alternating between "5.0W" and "40W" keeps one
        // width. Rows with no reservation fall back to their own text.
        let templates = (0..<rows.count).map { index -> [String] in
            index < readout.stackTemplates.count ? readout.stackTemplates[index] : [rows[index]]
        }

        var columns: [[(row: String, templates: [String])]] = []
        var index = 0
        while index < rows.count {
            if index + 1 < rows.count {
                columns.append([
                    (rows[index], templates[index]), (rows[index + 1], templates[index + 1]),
                ])
                index += 2
            } else {
                columns.append([(rows[index], templates[index])])
                index += 1
            }
        }

        func reservation(_ entry: (row: String, templates: [String]), _ font: NSFont) -> CGFloat {
            entry.templates.map { widthOfString($0, font: font) }.max() ?? 0
        }

        let widths = columns.map { column -> CGFloat in
            if column.count == 1 {
                return reservation(column[0], oneRowFont).rounded(.up)
            }
            return max(
                stackFloorWidth,
                max(reservation(column[0], twoRowFont), reservation(column[1], twoRowFont))
            ).rounded(.up)
        }
        // DEVIATION: Stats opens and closes the cell with a spacing of its own,
        // which put four points of empty bar around the figures on top of the
        // spacing the compositor already puts between read-outs. The columns
        // keep their spacing from each other; the cell's own edges do not need
        // it.
        let width = widths.reduce(0, +) + Metrics.spacing * CGFloat(columns.count - 1)

        return Cell(width: width) { originX in
            translated(originX) {
                // DEVIATION: Stats left-aligns these (it has an alignment
                // setting; left is its default). A column is as wide as its
                // wider row, so left alignment leaves the shorter row short of
                // the cell's right edge and the cell looks padded on the right
                // even though it is sized to its content. Right alignment puts
                // both rows against the same edge, which is also how a column
                // of figures wants to read.
                let style = NSMutableParagraphStyle()
                style.alignment = .right
                var x: CGFloat = 0

                for (column, columnWidth) in zip(columns, widths) {
                    // A figure wider than its column drops its unit rather
                    // than widening the cell, as the mini shape does at 100%.
                    func fitted(_ row: String, _ font: NSFont) -> String {
                        widthOfString(row, font: font) > columnWidth ? trimUnit(row) : row
                    }

                    if column.count == 1 {
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: oneRowFont, .foregroundColor: textColor(isDark),
                            .paragraphStyle: style,
                        ]
                        let rect = CGRect(
                            x: x, y: (Metrics.itemHeight - 12) / 2, width: columnWidth,
                            height: 12)
                        NSAttributedString(
                            string: fitted(column[0].row, oneRowFont), attributes: attributes
                        ).draw(with: rect)
                    } else {
                        let rowHeight = Metrics.frameHeight / 2
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: twoRowFont, .foregroundColor: textColor(isDark),
                            .paragraphStyle: style,
                        ]
                        NSAttributedString(
                            string: fitted(column[0].row, twoRowFont), attributes: attributes
                        ).draw(
                            with: CGRect(
                                x: x, y: rowHeight + 1, width: columnWidth, height: rowHeight))
                        NSAttributedString(
                            string: fitted(column[1].row, twoRowFont), attributes: attributes
                        ).draw(with: CGRect(x: x, y: 1, width: columnWidth, height: rowHeight))
                    }
                    x += columnWidth + Metrics.spacing
                }
            }
        }
    }

    /// The narrowest a two-row stack column gets, for the same reason the mini
    /// shape has a floor: a lone short figure should not make the cell so
    /// narrow that gaining a character shifts the bar.
    private static let stackFloorWidth: CGFloat = 16

    // MARK: - State dot (Kit/Widgets/Dot.swift)

    /// One 8pt dot, coloured by the metric's own scale.
    private static func state(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let width = 8 + (2 * Metrics.marginX)
        let color = readout.stateColor

        return Cell(width: width) { originX in
            translated(originX) {
                let circle = NSBezierPath(
                    ovalIn: CGRect(
                        x: Metrics.marginX, y: (Metrics.frameHeight - 8) / 2, width: 8, height: 8))
                color.set()
                circle.fill()
            }
        }
    }

    // MARK: - Text (Kit/Widgets/Text.swift)

    /// The value alone, centred at 12pt, in a cell rounded up to the next ten
    /// points so it stops twitching as digits come and go.
    private static func text(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let value = readout.textValue
        guard !value.isEmpty else { return Cell(width: 0) { _ in } }

        let valueSize: CGFloat = 12
        let font = NSFont.systemFont(ofSize: valueSize, weight: .regular)
        let width = (widthOfString(value, font: font) + Metrics.marginX * 2).roundedUpToNearestTen()

        return Cell(width: width) { originX in
            translated(originX) {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: textColor(isDark), .paragraphStyle: style,
                ]
                let rect = CGRect(
                    x: Metrics.marginX, y: (Metrics.itemHeight - valueSize - 1) / 2,
                    width: width - (Metrics.marginX * 2), height: valueSize)
                NSAttributedString(string: value, attributes: attributes).draw(with: rect)
            }
        }
    }

    // MARK: - Label (Kit/Widgets/Label.swift)

    /// The three-letter caption alone, one letter per row, read top to bottom.
    private static func label(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> Cell {
        let width = 6 + (2 * Metrics.marginX)
        let caption = readout.captionText

        return Cell(width: width) { originX in
            translated(originX) {
                drawVerticalLabel(caption, x: Metrics.marginX, letterWidth: 6, isDark: isDark)
            }
        }
    }

    /// Stats' `WidgetLabelView`: the first three characters, uppercased, stacked
    /// bottom-up so they read downwards, each in a third of the widget height.
    private static func drawVerticalLabel(
        _ title: String, x: CGFloat, letterWidth: CGFloat, isDark: Bool
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .regular),
            .foregroundColor: textColor(isDark),
            .paragraphStyle: style,
        ]
        let letterHeight = Metrics.frameHeight / 3
        var y: CGFloat = 0
        for character in String(title.prefix(3)).uppercased().reversed() {
            let rect = CGRect(x: x, y: y, width: letterWidth, height: letterHeight)
            NSAttributedString(string: String(character), attributes: attributes).draw(with: rect)
            y += letterHeight
        }
    }

    // MARK: - Shared drawing helpers

    /// Run `body` with the origin moved to this cell's bottom-left corner, inside
    /// the widget's vertical margin. Lets every ported routine keep Stats' own
    /// coordinates, where y = 0 is the bottom of the widget frame.
    private static func translated(_ x: CGFloat, _ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: x, y: Metrics.marginY)
        body()
        context.restoreGState()
    }

    /// The menu bar's own foreground colour. Stats reads `NSColor.textColor`,
    /// which resolves against the app's appearance; these images are rendered
    /// off-screen for the bar, so the bar's appearance has to be passed in.
    nonisolated static func textColor(_ isDark: Bool) -> NSColor {
        isDark ? .white : NSColor(white: 0.1, alpha: 1.0)
    }

    /// Stats' `Double.usageColor`: blue below the first zone, orange up to the
    /// second, red above. Reversed for the battery, where low is the bad end.
    nonisolated static func usageColor(
        _ value: Double, zones: (orange: Double, red: Double) = (0.6, 0.8), reversed: Bool = false
    ) -> NSColor {
        if reversed {
            switch value {
            case ...zones.orange: return .red
            case ...zones.red: return .orange
            default: return .systemBlue
            }
        }
        switch value {
        case ...zones.orange: return .systemBlue
        case ...zones.red: return .orange
        default: return .red
        }
    }

    /// Stats' `Double.batteryColor`, both of its modes.
    ///
    /// Stats takes a `color` flag from the battery widget's own Colorize
    /// setting: with it off the fill stays the bar's own colour, with it on the
    /// charge runs green, then orange, then red as it falls. This app's
    /// per-read-out colour switch supplies that flag, so Energy behaves like
    /// every other read-out rather than being permanently monochrome. Only the
    /// monochrome half was ported originally, which is why the battery never
    /// coloured whatever the switch said.
    ///
    /// Two of Stats' rules survive the switch being off, both because they are
    /// warnings rather than decoration, and this app already keeps an active
    /// alarm red for the same reason:
    ///
    /// * Below 20% is red. That is the charge at which macOS itself starts
    ///   warning, and a flat battery is worth a colour even on a bar the user
    ///   asked to keep plain.
    /// * Low Power Mode is yellow, whatever the charge, as it is in Stats.
    ///
    /// A full battery is the bar's own colour even when coloured: 100% needs no
    /// verdict, and Stats does the same.
    nonisolated static func batteryColor(
        _ charge: Double, isDark: Bool, isLowPowerMode: Bool, colored: Bool
    ) -> NSColor {
        if isLowPowerMode { return .systemYellow }
        switch charge {
        case 0.2...0.4:
            return colored ? .systemOrange : textColor(isDark)
        case 0.4...1:
            if charge >= 1 { return textColor(isDark) }
            return colored ? .systemGreen : textColor(isDark)
        default:
            return .systemRed
        }
    }

    /// The colour a chart fills with. Stats configures the line and bar charts
    /// with `systemAccent` for every module that offers them.
    private static func chartColor(_ readout: CombinedMenuBarReadout, _ isDark: Bool) -> NSColor {
        if readout.isAlarm { return .systemRed }
        return readout.isColored ? .controlAccentColor : textColor(isDark)
    }

    /// Stats' `scaleValue`: map a value onto a chart height under one of the
    /// scaling curves, normalising against the series maximum when unscaled.
    nonisolated static func scaleValue(
        scale: MenuBarChartScale = .linear, value: Double, maxValue: Double, zeroValue: Double,
        maxHeight: CGFloat, limit: Double
    ) -> CGFloat {
        var value = value
        if scale == .none && value > 1 && maxValue != 0 {
            value /= maxValue
        }
        var localMaxValue = maxValue
        var y = value * maxHeight

        switch scale {
        case .square:
            if value > 0 { value = sqrt(value) }
            if localMaxValue > 0 { localMaxValue = sqrt(maxValue) }
        case .cube:
            if value > 0 { value = cbrt(value) }
            if localMaxValue > 0 { localMaxValue = cbrt(maxValue) }
        case .logarithmic:
            if value > 0 { value = log(value / zeroValue) }
            if localMaxValue > 0 { localMaxValue = log(maxValue / zeroValue) }
        case .fixed:
            if value > limit { value = limit }
            localMaxValue = limit
        case .none, .linear:
            break
        }

        if value < 0 { value = 0 }
        if localMaxValue <= 0 { localMaxValue = 1 }
        if scale != .none {
            y = (maxHeight * value) / localMaxValue
        }
        return y
    }

    nonisolated static func widthOfString(_ string: String, font: NSFont) -> CGFloat {
        string.size(withAttributes: [.font: font]).width
    }

    /// The last `count` values of a series, oldest first.
    private static func trailing(_ values: [Double], count: Int) -> [Double] {
        values.count <= count ? values : Array(values.suffix(count))
    }
}

extension CGFloat {
    /// Stats' `CGFloat.roundedUpToNearestTen`.
    fileprivate func roundedUpToNearestTen() -> CGFloat {
        ceil(self / 10) * 10
    }
}
